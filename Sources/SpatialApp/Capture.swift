import Foundation

/// Diagnostics: `Spatial --log --capture <dir>` records what Spotify sends
/// (the tap, before anything of ours touches it) and what this app actually
/// plays (a self-tap), at the same time, on real music. Both are written as
/// interleaved stereo float32 files for offline comparison.
final class Capture {
    let frames: Int
    let input: UnsafeMutablePointer<Float>
    private let written = UnsafeMutablePointer<Int>.allocate(capacity: 1)
    private let armed = UnsafeMutablePointer<Bool>.allocate(capacity: 1)
    private var monitor: OutputMonitor?
    let dir: String

    init(dir: String, seconds: Double, rate: Double) {
        self.dir = dir
        frames = Int(seconds * rate)
        input = .allocate(capacity: frames * 2)
        written.initialize(to: 0)
        armed.initialize(to: false)
    }

    deinit {
        input.deallocate()
        written.deallocate()
        armed.deallocate()
    }

    /// Audio thread: append tap frames while armed.
    func record(left: UnsafePointer<Float>, right: UnsafePointer<Float>, count: Int) {
        guard armed.pointee else { return }
        var at = written.pointee
        for i in 0..<count where at < frames {
            input[at * 2] = left[i]
            input[at * 2 + 1] = right[i]
            at += 1
        }
        written.pointee = at
    }

    /// Main thread: start both recordings now, dump when full.
    func start(rate: Double) {
        let m = OutputMonitor(mute: false, recordFrames: frames + Int(2 * rate))
        do { try m.start() } catch {
            FileHandle.standardError.write("capture: monitor failed \(error)\n".data(using: .utf8)!)
            return
        }
        monitor = m
        armed.pointee = true
        let seconds = Double(frames) / rate + 2.5
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [self] in
            armed.pointee = false
            m.stop()
            let a = Data(bytes: input, count: written.pointee * 8)
            let b = Data(bytes: m.recording, count: m.recordedFrames * 8)
            try? a.write(to: URL(fileURLWithPath: dir + "/cap_input.f32"))
            try? b.write(to: URL(fileURLWithPath: dir + "/cap_output.f32"))
            FileHandle.standardError.write("capture: wrote \(written.pointee) input, \(m.recordedFrames) output frames to \(dir)\n".data(using: .utf8)!)
            monitor = nil
        }
    }
}
