import CoreAudio
import Foundation

/// Preallocated sample buffers for the audio thread, and the moves between
/// Core Audio's buffer layouts and plain left/right arrays.
final class Scratch {
    let inLeft = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames)
    let inRight = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames)
    let outLeft = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames)
    let outRight = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames)
    /// Loudest input sample since the main thread last looked. A torn read is
    /// harmless; it only feeds the "is anything coming in" status.
    let peak = UnsafeMutablePointer<Float>.allocate(capacity: 1)

    init() { peak.initialize(to: 0) }

    deinit {
        for p in [inLeft, inRight, outLeft, outRight, peak] { p.deallocate() }
    }

    /// Copies `frames` frames starting at `offset` from the tap into inLeft/inRight.
    func read(_ list: UnsafePointer<AudioBufferList>, offset: Int, frames: Int) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        var loudest = peak.pointee
        defer { peak.pointee = loudest }
        guard buffers.count > 0, let first = buffers[0].mData?.assumingMemoryBound(to: Float.self) else {
            inLeft.update(repeating: 0, count: frames)
            inRight.update(repeating: 0, count: frames)
            return
        }
        let channels = Int(buffers[0].mNumberChannels)
        let available = Int(buffers[0].mDataByteSize) / (MemoryLayout<Float>.size * max(1, channels))
        let n = max(0, min(frames, available - offset))
        if channels >= 2 {
            for i in 0..<n {
                inLeft[i] = first[(offset + i) * channels]
                inRight[i] = first[(offset + i) * channels + 1]
            }
        } else if buffers.count >= 2, let second = buffers[1].mData?.assumingMemoryBound(to: Float.self) {
            inLeft.update(from: first + offset, count: n)
            inRight.update(from: second + offset, count: n)
        } else {
            inLeft.update(from: first + offset, count: n)
            inRight.update(from: first + offset, count: n)
        }
        for i in 0..<n { loudest = max(loudest, abs(inLeft[i]), abs(inRight[i])) }
        if n < frames {
            (inLeft + n).update(repeating: 0, count: frames - n)
            (inRight + n).update(repeating: 0, count: frames - n)
        }
    }

    /// Writes outLeft/outRight into the device's buffers at `offset`.
    func write(_ list: UnsafeMutablePointer<AudioBufferList>, offset: Int, frames: Int) {
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        guard buffers.count > 0 else { return }
        if buffers.count == 1 {
            guard let out = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return }
            let channels = Int(buffers[0].mNumberChannels)
            if channels == 1 {
                for i in 0..<frames { out[offset + i] = 0.5 * (outLeft[i] + outRight[i]) }
            } else {
                for i in 0..<frames {
                    let base = (offset + i) * channels
                    out[base] = outLeft[i]
                    out[base + 1] = outRight[i]
                    for c in 2..<max(2, channels) { out[base + c] = 0 }
                }
            }
            return
        }
        // One buffer per channel (or per stream): first two get the music.
        for (index, buffer) in buffers.enumerated() {
            guard let out = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let channels = max(1, Int(buffer.mNumberChannels))
            for i in 0..<frames {
                let base = (offset + i) * channels
                for c in 0..<channels {
                    let lane = index == 0 && channels >= 2 ? c : index
                    out[base + c] = lane == 0 ? outLeft[i] : lane == 1 ? outRight[i] : 0
                }
            }
        }
    }
}

/// Takes Spotify's sound away from the speakers (a muted process tap) and
/// plays it back through a spatial engine to the current output device.
///
/// Follows Spotify starting, quitting, and spawning audio helpers, and the
/// output device changing (AirPods in, AirPods out).
final class Router {
    enum State: Equatable {
        case off
        case waiting                      // the target app isn't playing through Core Audio
        case running(device: String, rate: Double, kind: OutputKind)
        case failed(String)
    }

    /// Bundle ID prefix of the app to spatialize. Spotify's audio helpers
    /// share the prefix. Change with `defaults write local.spatial target <id>`.
    let target = UserDefaults.standard.string(forKey: "target") ?? "com.spotify.client"

    private(set) var state = State.off { didSet { if state != oldValue { onChange?() } } }
    private(set) var engine: SpatialEngine
    var onChange: (() -> Void)?

    private let scratch = Scratch()
    /// Holds the capture the audio thread records into. Captures are kept
    /// alive in `pastCaptures` so swapping one never frees it under the
    /// audio thread's feet.
    final class CaptureSlot { var current: Capture? }
    private let captureSlot = CaptureSlot()
    private var pastCaptures: [Capture] = []
    let player = SystemPlayer()
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var tapped: [AudioObjectID] = []
    private var outputDevice = AudioObjectID(kAudioObjectUnknown)
    private var listeners: [(AudioObjectPropertySelector, AudioObjectPropertyListenerBlock)] = []
    /// Watches the current output's sample rate: if it changes under us
    /// (another app, or a spatial-mode switch reconfiguring the AirPods),
    /// the tap and the player disagree on time until we rebuild.
    private var rateListener: (AudioObjectID, AudioObjectPropertyListenerBlock)?
    private var pending: DispatchWorkItem?
    private var enabled = false

    var headTracking = HeadTracking.off { didSet { engine.setHeadTracking(headTracking) } }
    var room = false { didSet { engine.setRoom(room) } }

    init(engine kind: EngineKind) {
        engine = makeEngine(kind)
    }

    deinit {
        unwatch()
        teardown()
    }

    func setEnabled(_ on: Bool) {
        enabled = on
        if on { watch() } else { unwatch() }
        refresh(force: true)
    }

    func setEngine(_ kind: EngineKind) {
        guard kind != engine.kind else { return }
        teardown()
        engine = makeEngine(kind)
        refresh(force: true)
    }

    /// Loudest sample since the last call (0...1).
    func takePeak() -> Float {
        let p = scratch.peak.pointee
        scratch.peak.pointee = 0
        return p
    }

    var targetIsPlaying: Bool {
        CA.processes().contains { $0.bundleID.hasPrefix(target) && $0.isPlaying }
    }

    // MARK: Deciding when to (re)build

    private func refresh(force: Bool = false) {
        guard enabled else {
            teardown()
            state = .off
            return
        }
        let targets = CA.processes().filter { $0.bundleID.hasPrefix(target) }.map(\.object).sorted()
        guard !targets.isEmpty, let output = CA.defaultOutput() else {
            teardown()
            state = .waiting
            return
        }
        if !force, targets == tapped, output == outputDevice, procID != nil { return }
        teardown()
        do {
            try build(targets: targets, output: output)
        } catch {
            teardown()
            state = .failed("\(error)")
        }
    }

    /// Core Audio fires several notifications per change; settle first.
    private func refreshSoon(force: Bool = false) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh(force: force) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func watch() {
        guard listeners.isEmpty else { return }
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyProcessObjectList] {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.refreshSoon() }
            var address = CA.address(selector)
            AudioObjectAddPropertyListenerBlock(CA.system, &address, .main, block)
            listeners.append((selector, block))
        }
    }

    private func unwatch() {
        for (selector, block) in listeners {
            var address = CA.address(selector)
            AudioObjectRemovePropertyListenerBlock(CA.system, &address, .main, block)
        }
        listeners.removeAll()
        pending?.cancel()
    }

    // MARK: Tap -> engine -> output

    private func build(targets: [AudioObjectID], output: AudioObjectID) throws {
        guard let outputUID = CA.uid(output) else { throw AudioError("output device has no id") }

        // 1. Spotify's mix, silenced at the speakers while we read it.
        let tap = CATapDescription(stereoMixdownOfProcesses: targets)
        tap.uuid = UUID()
        tap.name = "Spatial"
        tap.isPrivate = true
        tap.muteBehavior = .mutedWhenTapped
        try check(AudioHardwareCreateProcessTap(tap, &tapID), "create tap")

        // 2. One private device: the tap as input, the real output as output,
        //    on the output's clock.
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Spatial",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            // No drift compensation: Spotify plays to this same output, so
            // the tap already runs on its clock, and compensation means a
            // continuous resampler on the music.
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: false,
                kAudioSubTapUIDKey: tap.uuid.uuidString,
            ]],
        ]
        try check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &deviceID), "create device")

        // 3. Render at the device's rate; the tap is resampled to it.
        var rate = CA.sampleRate(deviceID)
        if rate <= 0 { rate = CA.sampleRate(output) }
        guard rate > 0 else { throw AudioError("output has no sample rate") }
        if let f = CA.get(tapID, kAudioTapPropertyFormat, as: AudioStreamBasicDescription.self) {
            FileHandle.standardError.write("spotify tap \(Int(f.mSampleRate)) Hz \(f.mChannelsPerFrame) ch, device \(Int(rate)) Hz\n".data(using: .utf8)!)
        }
        let kind = CA.kind(of: output)
        try engine.prepare(sampleRate: rate, output: kind)
        engine.setHeadTracking(headTracking)
        engine.setRoom(room)
        let ring: Ring? = engine.kind.rendersItself ? nil : player.ring
        if ring != nil { try player.start(sampleRate: rate, outputLatency: CA.latency(of: output), deviceUID: outputUID) }

        // 4. The audio thread: read the tap, then either spatialize it here
        //    and write it out, or pass it to the system player and leave
        //    this device silent.
        let scratch = self.scratch
        let engine = self.engine
        var capture: Capture?
        if let i = args.firstIndex(of: "--capture"), i + 1 < args.count {
            let secs = args.firstIndex(of: "--capture-seconds").flatMap { Double(args[$0 + 1]) } ?? 8
            capture = Capture(dir: args[i + 1], seconds: secs, rate: rate)
        }
        captureSlot.current = capture
        let captureSlot = self.captureSlot
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, nil) { _, input, _, output, _ in
            let outs = UnsafeMutableAudioBufferListPointer(output)
            let channels = outs.count > 0 ? max(1, Int(outs[0].mNumberChannels)) : 1
            let frames = outs.count > 0
                ? Int(outs[0].mDataByteSize) / (MemoryLayout<Float>.size * channels)
                : Self.inputFrames(input)
            var offset = 0
            while offset < frames {
                let n = min(maxFrames, frames - offset)
                scratch.read(input, offset: offset, frames: n)
                captureSlot.current?.record(left: scratch.inLeft, right: scratch.inRight, count: n)
                if let ring {
                    ring.write(left: scratch.inLeft, right: scratch.inRight, frames: n)
                } else {
                    engine.render(left: scratch.inLeft, right: scratch.inRight,
                                  outLeft: scratch.outLeft, outRight: scratch.outRight, frames: n)
                    scratch.write(output, offset: offset, frames: n)
                }
                offset += n
            }
            if ring != nil {
                for buffer in outs { if let d = buffer.mData { memset(d, 0, Int(buffer.mDataByteSize)) } }
            }
        }, "create renderer")
        try check(AudioDeviceStart(deviceID, procID), "start renderer")

        if let capture {   // let the output settle first
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { capture.start(rate: rate) }
        }

        let rateBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            if args.contains("--log") {
                FileHandle.standardError.write("output sample rate changed to \(Int(CA.sampleRate(output))) Hz: rebuilding\n".data(using: .utf8)!)
            }
            self?.refreshSoon(force: true)
        }
        var rateAddress = CA.address(kAudioDevicePropertyNominalSampleRate)
        AudioObjectAddPropertyListenerBlock(output, &rateAddress, .main, rateBlock)
        rateListener = (output, rateBlock)

        tapped = targets
        outputDevice = output
        state = .running(device: CA.name(output), rate: rate, kind: kind)
    }

    /// Starts a side-by-side capture (Spotify in, this app out) while
    /// running, without rebuilding anything. Used by the `captureTo` default.
    func startCapture(dir: String, seconds: Double) -> Bool {
        guard case let .running(_, rate, _) = state else { return false }
        let capture = Capture(dir: dir, seconds: seconds, rate: rate)
        if let old = captureSlot.current { pastCaptures.append(old) }
        captureSlot.current = capture
        capture.start(rate: rate)
        return true
    }

    private static func inputFrames(_ list: UnsafePointer<AudioBufferList>) -> Int {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard buffers.count > 0 else { return 0 }
        return Int(buffers[0].mDataByteSize) / (MemoryLayout<Float>.size * max(1, Int(buffers[0].mNumberChannels)))
    }

    private func teardown() {
        if let (device, block) = rateListener {
            var address = CA.address(kAudioDevicePropertyNominalSampleRate)
            AudioObjectRemovePropertyListenerBlock(device, &address, .main, block)
            rateListener = nil
        }
        player.stop()
        if deviceID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(deviceID, procID)
                AudioDeviceDestroyIOProcID(deviceID, procID)
            }
            AudioHardwareDestroyAggregateDevice(deviceID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        deviceID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        tapped = []
        outputDevice = AudioObjectID(kAudioObjectUnknown)
    }
}
