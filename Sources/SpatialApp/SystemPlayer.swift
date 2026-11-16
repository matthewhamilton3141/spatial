import AVFoundation
import CoreMedia
import Synchronization

/// Single-producer, single-consumer ring of interleaved stereo frames. The
/// audio thread writes, the player's queue reads; neither ever waits.
final class Ring {
    let capacity: Int
    private let data: UnsafeMutablePointer<Float>
    private let written = Atomic<Int>(0)   // total frames ever written
    private let consumed = Atomic<Int>(0)  // total frames ever read

    init(frames: Int = 1 << 16) {
        capacity = frames
        data = .allocate(capacity: frames * 2)
        data.initialize(repeating: 0, count: frames * 2)
    }

    deinit { data.deallocate() }

    var available: Int { written.load(ordering: .acquiring) - consumed.load(ordering: .relaxed) }

    /// Blocks dropped because the reader fell a whole ring behind.
    private(set) var overflows = 0

    /// Audio thread. Drops the block if the reader has fallen a whole ring behind.
    func write(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int) {
        let w = written.load(ordering: .relaxed)
        guard w + frames - consumed.load(ordering: .acquiring) <= capacity else { overflows += 1; return }
        for i in 0..<frames {
            let slot = ((w + i) % capacity) * 2
            data[slot] = left[i]
            data[slot + 1] = right[i]
        }
        written.store(w + frames, ordering: .releasing)
    }

    /// Reader. Copies up to `frames` interleaved frames into `out`.
    func read(into out: UnsafeMutablePointer<Float>, frames: Int) -> Int {
        let r = consumed.load(ordering: .relaxed)
        let n = min(frames, written.load(ordering: .acquiring) - r)
        for i in 0..<n {
            let slot = ((r + i) % capacity) * 2
            out[i * 2] = data[slot]
            out[i * 2 + 1] = data[slot + 1]
        }
        consumed.store(r + n, ordering: .releasing)
        return n
    }

    /// Reader. Throws away what's waiting (to win back latency).
    func skipAll() {
        consumed.store(written.load(ordering: .acquiring), ordering: .releasing)
    }
}

/// Plays Spotify's untouched stereo through AVSampleBufferAudioRenderer with
/// stereo spatialization allowed. That makes this app one macOS treats as
/// spatial-capable, so the AirPods menu in Control Center offers
/// Off / Fixed / Head Tracked and macOS does the rendering itself.
final class SystemPlayer {
    let ring = Ring()
    private let renderer = AVSampleBufferAudioRenderer()
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private let queue = DispatchQueue(label: "spatial.system-player", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var format: CMAudioFormatDescription?
    private var sampleRate: Double = 48_000
    private var next = CMTime.zero
    private var started = false
    private let chunk = 1024
    private let staging: UnsafeMutablePointer<Float>

    /// How far ahead of the playhead we aim to keep audio queued. Small
    /// enough not to notice, big enough to ride out a late timer.
    var lead = 0.04
    /// Extra headroom learned from underruns (starts at zero).
    private var cushion = 0.0
    /// Glitch counters for `--log`.
    private var underruns = 0, runaways = 0, failures = 0
    private var lastReport = Date()
    /// The output device's own latency. Audio queued less than this far
    /// ahead of the playhead arrives too late and the renderer silently drops
    /// it (measured on AirPods: 171 ms reported, silence at 170 ms, fine at 200).
    private var outputLatency = 0.0
    /// How far ahead to keep audio: output latency plus a margin. Excess
    /// left over from the output waking up is trimmed down to this.
    /// UserDefaults `targetLead` (seconds) overrides it; `trimLatency` = NO
    /// turns trimming off. Both are re-read once a second.
    private var targetLead = 0.0
    private var trimming = true
    /// Margin above the output latency.
    /// Headroom over the output latency. Bluetooth makes the playhead
    /// jitter by about ±50 ms; at 60 ms of margin that jitter kept tripping
    /// the underrun and trim corrections, each an audible skip (heard as the
    /// song slowing down and speeding up). 150 ms rides it out.
    static let margin = 0.15
    private var windowMin = Double.infinity
    private var windowStart = Date()
    /// When the timeline last (re)started. Trimming only happens shortly
    /// after, to remove the output's wake-up delay; never in steady play.
    private var startedAt = Date()
    private var toSkip = 0
    private var trims = 0
    private var resyncs = 0
    private var recentUnderruns: [Date] = []

    private let logging = args.contains("--log")

    init() {
        staging = .allocate(capacity: chunk * 2)
        renderer.allowedAudioSpatializationFormats = .monoStereoAndMultichannel
        synchronizer.addRenderer(renderer)
        // Start the clock right away instead of waiting for the output to
        // wake up; otherwise that wait (~200 ms on AirPods) becomes
        // permanent extra delay.
        synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
    }

    deinit {
        stop()
        staging.deallocate()
    }

    /// Seconds queued ahead of the playhead (for the smoke test / log).
    var queuedAhead: Double {
        queue.sync { started ? (next - synchronizer.currentTime()).seconds : 0 }
    }

    /// Underrun jumps and runaway skips so far (for the smoke test).
    var glitches: Int { queue.sync { underruns + runaways } }

    var failed: Error? { renderer.status == .failed ? renderer.error : nil }

    func start(sampleRate: Double, outputLatency: Double = 0, deviceUID: String? = nil) throws {
        stop()
        // (Pinning audioOutputDeviceUniqueID to the output was tried against
        // the "speeding up / slowing down" report: no change, so it's left
        // on the system default. Setting it to nil throws.)
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        // Tagging it stereo is what lets macOS spatialize it as stereo.
        var layout = AudioChannelLayout(mChannelLayoutTag: kAudioChannelLayoutTag_Stereo,
                                        mChannelBitmap: [], mNumberChannelDescriptions: 0,
                                        mChannelDescriptions: AudioChannelDescription())
        var description: CMAudioFormatDescription?
        try check(CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &asbd,
            layoutSize: MemoryLayout<AudioChannelLayout>.size, layout: &layout,
            magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &description), "describe audio")
        format = description
        self.sampleRate = sampleRate

        queue.sync {
            ring.skipAll()
            next = .zero
            started = false
            cushion = 0
            self.outputLatency = outputLatency
            readSettings()
        }
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(5), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.pump() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
        queue.sync {
            synchronizer.setRate(0, time: .zero)
            renderer.flush()
            started = false
        }
    }

    /// Moves whatever the tap delivered into the renderer, keeping the queue
    /// `lead` seconds ahead of the playhead.
    private func pump() {
        guard let format else { return }
        if Date().timeIntervalSince(lastReport) >= 1 {
            lastReport = Date()
            readSettings()
            if logging {
                let ahead = started ? (next - synchronizer.currentTime()).seconds : 0
                FileHandle.standardError.write(String(format: "player ahead %.0f ms target %.0f ms trims %d underruns %d resyncs %d runaways %d overflows %d failures %d\n",
                    ahead * 1000, targetLead * 1000, trims, underruns, resyncs, runaways, ring.overflows, failures).data(using: .utf8)!)
            }
        }
        if renderer.status == .failed {   // e.g. the output went away: start over
            failures += 1
            renderer.flush()
            started = false
        }
        let rate = sampleRate
        if !started {
            guard Double(ring.available) >= lead * rate else { return }
            synchronizer.setRate(0, time: .zero)
            renderer.flush()
            // First buffer lands `targetLead` after the clock starts, so it
            // isn't already late.
            next = CMTime(seconds: targetLead, preferredTimescale: CMTimeScale(rate))
        } else {
            let now = synchronizer.currentTime()
            let ahead = (next - now).seconds
            if ahead < outputLatency + 0.005 {
                // Too close to be played: these buffers would be dropped.
                // Jump forward to the target (a short gap) and keep a bit
                // more in hand from now on.
                next = now + CMTime(seconds: targetLead + cushion, preferredTimescale: CMTimeScale(rate))
                cushion = min(cushion + 0.02, 0.3)
                underruns += 1
                // A burst of underruns means the clock and the incoming audio
                // disagree (seen once: ~7% apart for six minutes, the clock
                // jumping 300 ms every 5 s, heard as the song slowing and
                // lurching). Patching each one never converges; start the
                // timeline over instead.
                recentUnderruns = recentUnderruns.filter { Date().timeIntervalSince($0) < 5 } + [Date()]
                if recentUnderruns.count >= 5 {
                    recentUnderruns.removeAll()
                    resyncs += 1
                    cushion = 0
                    renderer.flush()
                    started = false
                    return
                }
            } else if trimming, Date().timeIntervalSince(startedAt) < 10 {
                // Trim the excess left by the output waking up: once the
                // smallest lead over a full second is above target, drop that
                // much incoming audio (a tiny skip in the music, no gap).
                windowMin = min(windowMin, ahead)
                if Date().timeIntervalSince(windowStart) >= 1 {
                    // Only one trim at a time: dropping N ms takes N ms of
                    // incoming audio, and stacking trims would overshoot.
                    if toSkip == 0, windowMin > targetLead + cushion + 0.03 {
                        toSkip = Int((windowMin - targetLead - cushion) * rate)
                        trims += 1
                    }
                    windowMin = .infinity
                    windowStart = Date()
                }
            }
            if ahead > 1.5 {
                runaways += 1
                // Runaway drift only. What sits queued at steady state is
                // what the renderer needs to cover output latency (about
                // 110-300 ms on AirPods, measured); trimming it makes every
                // buffer late and the renderer drops them: silence.
                ring.skipAll()
                return
            }
        }

        if toSkip > 0 {
            while toSkip > 0 && ring.available > 0 {
                toSkip -= ring.read(into: staging, frames: min(chunk, toSkip))
            }
            if toSkip <= 0 {   // judge the result with a fresh window
                toSkip = 0
                windowMin = .infinity
                windowStart = Date()
            }
        }

        while ring.available > 0 && renderer.isReadyForMoreMediaData {
            let n = ring.read(into: staging, frames: chunk)
            guard n > 0, let buffer = makeBuffer(frames: n, format: format) else { break }
            renderer.enqueue(buffer)
            next = next + CMTime(value: CMTimeValue(n), timescale: CMTimeScale(rate))
        }

        if !started {
            startedAt = Date()
            synchronizer.setRate(1, time: .zero)
            started = true
        }
    }

    private func readSettings() {
        let d = UserDefaults.standard
        let override = d.double(forKey: "targetLead")
        targetLead = override > 0 ? override : outputLatency + Self.margin
        trimming = d.object(forKey: "trimLatency") as? Bool ?? true
    }

    private func makeBuffer(frames: Int, format: CMAudioFormatDescription) -> CMSampleBuffer? {
        let bytes = frames * 2 * MemoryLayout<Float>.size
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
            customBlockSource: nil, offsetToData: 0, dataLength: bytes,
            flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
              let block,
              CMBlockBufferReplaceDataBytes(with: staging, blockBuffer: block,
                                            offsetIntoDestination: 0, dataLength: bytes) == noErr else { return nil }
        var sample: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: format,
            sampleCount: frames, presentationTimeStamp: next,
            packetDescriptions: nil, sampleBufferOut: &sample) == noErr else { return nil }
        return sample
    }
}
