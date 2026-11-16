import CoreAudio
import Foundation

/// Headless check of both engines with synthetic signals: no tap, no
/// devices opened, no permission prompts.
func runSmokeTest() -> Bool {
    var ok = true
    func check(_ name: String, _ pass: Bool, _ detail: String = "") {
        print("\(pass ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : "  (\(detail))")")
        if !pass { ok = false }
    }
    func db(_ x: Float) -> String { String(format: "%.1f dB", 20 * log10(max(x, 1e-9))) }

    var rng = SystemRandomNumberGenerator()
    let block = 512

    /// Runs `seconds` of the generator through the engine and returns the
    /// RMS of each output channel over the part after `skip` seconds.
    func run(_ engine: SpatialEngine, rate: Double, seconds: Double, skip: Double = 0.25,
             _ signal: (Int) -> (Float, Float)) -> (l: Float, r: Float, finite: Bool) {
        let inL = UnsafeMutablePointer<Float>.allocate(capacity: block)
        let inR = UnsafeMutablePointer<Float>.allocate(capacity: block)
        let outL = UnsafeMutablePointer<Float>.allocate(capacity: block)
        let outR = UnsafeMutablePointer<Float>.allocate(capacity: block)
        defer { [inL, inR, outL, outR].forEach { $0.deallocate() } }
        let total = Int(seconds * rate), start = Int(skip * rate)
        var sumL: Double = 0, sumR: Double = 0, count = 0, finite = true
        var t = 0
        while t < total {
            let n = min(block, total - t)
            for i in 0..<n { (inL[i], inR[i]) = signal(t + i) }
            engine.render(left: inL, right: inR, outLeft: outL, outRight: outR, frames: n)
            for i in 0..<n where t + i >= start {
                if !outL[i].isFinite || !outR[i].isFinite { finite = false }
                sumL += Double(outL[i] * outL[i]); sumR += Double(outR[i] * outR[i]); count += 1
            }
            t += n
        }
        let c = Double(max(count, 1))
        return (Float((sumL / c).squareRoot()), Float((sumR / c).squareRoot()), finite)
    }

    let noise: (Int) -> Float = { _ in Float.random(in: -0.25...0.25, using: &rng) }
    let inputRMS = Float(0.25 / 3.0.squareRoot())

    for kind in EngineKind.allCases where kind.rendersItself {
        for rate in [48_000.0, 44_100.0] {
            let tag = "\(kind.rawValue) @ \(Int(rate))"
            let engine = makeEngine(kind)
            do {
                try engine.prepare(sampleRate: rate, output: .headphones)
            } catch {
                check("\(tag): engine starts", false, "\(error)")
                continue
            }
            check("\(tag): engine starts", true,
                  kind == .mixer ? "personal profile: \(engine.usingPersonalProfile.map { $0 ? "yes" : "no" } ?? "unknown")" : "")
            engine.setHeadTracking(.off)
            engine.setRoom(false)

            let left = run(engine, rate: rate, seconds: 1) { _ in (noise(0), 0) }
            check("\(tag): left-only input stays on the left", left.finite && left.l > left.r * 1.25,
                  "L \(db(left.l)), R \(db(left.r))")
            check("\(tag): and bleeds into the right ear (it is being spatialized)", left.r > left.l * 0.05,
                  "R/L \(db(left.r / max(left.l, 1e-9)))")

            let right = run(engine, rate: rate, seconds: 1) { _ in (0, noise(0)) }
            check("\(tag): right-only input stays on the right", right.r > right.l * 1.25,
                  "L \(db(right.l)), R \(db(right.r))")

            let center = run(engine, rate: rate, seconds: 1) { _ in let v = noise(0); return (v, v) }
            let balance = 20 * log10(max(center.l, 1e-9) / max(center.r, 1e-9))
            check("\(tag): centred input stays centred", abs(balance) < 1.5, String(format: "%.2f dB", balance))
            check("\(tag): level is sane", center.l > inputRMS * 0.1 && center.l < inputRMS * 4,
                  "gain \(db(center.l / inputRMS))")

            // Head tracking through our own pose: turn 90° and the centred
            // sound should move to one ear.
            engine.setHeadTracking(.motion)
            engine.setHeadPose(HeadPose(yaw: 90, pitch: 0, roll: 0))
            let turned = run(engine, rate: rate, seconds: 1) { _ in let v = noise(0); return (v, v) }
            let shift = 20 * log10(max(turned.l, 1e-9) / max(turned.r, 1e-9))
            check("\(tag): head pose moves the sound", abs(shift) > 3,
                  String(format: "yaw +90° -> %.1f dB toward the %@ ear", abs(shift), shift > 0 ? "left" : "right"))
            engine.setHeadPose(HeadPose())
            engine.setHeadTracking(.off)

            // Room: a short burst, then listen to the tail.
            func tail(_ room: Bool) -> Float {
                engine.setRoom(room)
                _ = run(engine, rate: rate, seconds: 0.5, skip: 0.5) { _ in (0, 0) }   // flush
                let burst = Int(0.05 * rate)
                let r = run(engine, rate: rate, seconds: 0.65, skip: 0.15) { i in
                    i < burst ? (noise(0), noise(0)) : (0, 0)
                }
                return max(r.l, r.r)
            }
            if kind.hasRoom {
                let dry = tail(false), wet = tail(true)
                check("\(tag): Room adds a tail", wet > dry * 2 && wet > 1e-4, "dry \(db(dry)), room \(db(wet))")
                engine.setRoom(false)
            }
        }
    }

    // The mixer for speakers and the built-in head tracking switch.
    let mixer = MixerEngine()
    do {
        try mixer.prepare(sampleRate: 48_000, output: .builtInSpeakers)
        check("mixer renders for built-in speakers", true)
        try mixer.prepare(sampleRate: 48_000, output: .headphones)
        check("mixer accepts built-in head tracking", mixer.builtInTrackingAccepted)
    } catch {
        check("mixer alternate setups", false, "\(error)")
    }

    // Buffer layouts the device might hand us.
    let scratch = Scratch()
    var interleaved: [Float] = (0..<8).flatMap { [Float($0), -Float($0)] }
    interleaved.withUnsafeMutableBytes { raw in
        var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
            mNumberChannels: 2, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
        scratch.read(&list, offset: 2, frames: 4)
    }
    check("reads interleaved tap audio", scratch.inLeft[0] == 2 && scratch.inRight[3] == -5)
    for i in 0..<4 { scratch.outLeft[i] = 1; scratch.outRight[i] = -1 }
    var device = [Float](repeating: 9, count: 4 * 4)   // 4 frames x 4 channels
    device.withUnsafeMutableBytes { raw in
        var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
            mNumberChannels: 4, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
        scratch.write(&list, offset: 0, frames: 4)
    }
    check("writes to a 4-channel device", device[0] == 1 && device[1] == -1 && device[2] == 0 && device[15] == 0)

    // The ring between the audio thread and the system player.
    let ring = Ring(frames: 8)
    let ones = [Float](repeating: 1, count: 6), twos = [Float](repeating: 2, count: 6)
    ring.write(left: ones, right: twos, frames: 6)
    ring.write(left: ones, right: twos, frames: 6)   // would overflow: dropped
    var got = [Float](repeating: 0, count: 16)
    let n = ring.read(into: &got, frames: 8)
    check("ring passes frames through and drops on overflow", n == 6 && got[0] == 1 && got[1] == 2 && ring.available == 0)
    ring.write(left: ones, right: twos, frames: 6)   // wraps around the end
    let m = ring.read(into: &got, frames: 8)
    check("ring wraps", m == 6 && got[10] == 1 && got[11] == 2)

    // The system player: four seconds of silence through the real renderer
    // (inaudible), checking it accepts the format and keeps a steady lead.
    if args.contains("--no-player") == false {
        let player = SystemPlayer()
        do {
            if let v = ProcessInfo.processInfo.environment["LEAD"], let d = Double(v) { player.lead = d }
            let latency = CA.defaultOutput().map(CA.latency(of:)) ?? 0
            try player.start(sampleRate: 48_000, outputLatency: latency)
            let zeros = [Float](repeating: 0, count: 480)
            var leads: [Double] = []
            let t0 = Date()
            var fed = 0
            for step in 0..<400 {   // 4 s of tap audio, fed at real-time pace
                Thread.sleep(forTimeInterval: 0.01)
                let due = Int(Date().timeIntervalSince(t0) * 48_000)
                while fed + 480 <= due {
                    player.ring.write(left: zeros, right: zeros, frames: 480)
                    fed += 480
                }
                if step >= 300 { leads.append(player.queuedAhead) }
                if args.contains("--verbose"), step % 25 == 0 { print(String(format: "  t=%.2f queued %.0f ms", Double(step) / 100, player.queuedAhead * 1000)) }
            }
            let avg = leads.reduce(0, +) / Double(max(leads.count, 1))
            check("system player plays without failing", player.failed == nil,
                  player.failed.map { "\($0)" } ?? "")
            // Never below the output's latency (that would be silent), and
            // trimmed to near latency + margin once the output is awake.
            check("system player holds its lead just above the output latency",
                  avg >= latency && avg < latency + SystemPlayer.margin + 0.1,
                  String(format: "%.0f ms queued, output latency %.0f ms", avg * 1000, latency * 1000))
            check("system player has no glitches", player.glitches == 0, "\(player.glitches)")
            player.stop()
        } catch {
            check("system player starts", false, "\(error)")
        }
    }

    // Core Audio queries the app relies on.
    let output = CA.defaultOutput()
    check("finds the output device", output != nil,
          output.map { "\(CA.name($0)), \(CA.kind(of: $0).rawValue), \(Int(CA.sampleRate($0))) Hz" } ?? "")
    check("lists audio processes", !CA.processes().isEmpty, "\(CA.processes().count) processes")

    print(ok ? "PASS" : "FAIL")
    return ok
}

/// What the app would see right now, without tapping anything.
func runProbe() {
    let target = UserDefaults.standard.string(forKey: "target") ?? "com.spotify.client"
    if let output = CA.defaultOutput() {
        print("output: \(CA.name(output))  kind \(CA.kind(of: output).rawValue)  \(Int(CA.sampleRate(output))) Hz  "
              + String(format: "latency %.0f ms", CA.latency(of: output) * 1000))
    } else {
        print("output: none")
    }
    print("target: \(target)*")
    for p in CA.processes().sorted(by: { $0.bundleID < $1.bundleID }) {
        let mark = p.bundleID.hasPrefix(target) ? "→" : " "
        print("\(mark) \(p.isPlaying ? "▶" : " ") pid \(p.pid)\t\(p.bundleID.isEmpty ? "(no bundle id)" : p.bundleID)")
    }
}
