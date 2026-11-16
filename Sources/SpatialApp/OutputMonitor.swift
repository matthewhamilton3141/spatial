import CoreAudio
import Foundation

/// Diagnostics for `--log`: taps this app's own output (left audible) and
/// reports its loudest sample, so "is anything actually coming out?" can be
/// answered without someone listening.
final class OutputMonitor {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let peak = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    private let mute: Bool
    /// Optional recording of what the app played (interleaved L/R).
    let recording: UnsafeMutablePointer<Float>
    let recordCapacity: Int
    private let recorded = UnsafeMutablePointer<Int>.allocate(capacity: 1)
    var recordedFrames: Int { recorded.pointee }

    /// `mute` silences this app at the speakers while monitoring (for tests).
    init(mute: Bool = false, recordFrames: Int = 0) {
        self.mute = mute
        recordCapacity = recordFrames
        recording = .allocate(capacity: max(1, recordFrames * 2))
        peak.initialize(to: 0)
        recorded.initialize(to: 0)
    }

    deinit {
        stop()
        peak.deallocate()
        recording.deallocate()
        recorded.deallocate()
    }

    func takePeak() -> Float {
        let p = peak.pointee
        peak.pointee = 0
        return p
    }

    func start() throws {
        stop()
        var pid = getpid()
        var address = CA.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var me = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(CA.system, &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &me),
                  "find own process")
        guard me != kAudioObjectUnknown else { throw AudioError("this app has no audio process object yet") }
        guard let output = CA.defaultOutput(), let outputUID = CA.uid(output) else { throw AudioError("no output") }

        let tap = CATapDescription(stereoMixdownOfProcesses: [me])
        tap.uuid = UUID()
        tap.name = "Spatial monitor"
        tap.isPrivate = true
        tap.muteBehavior = mute ? .muted : .unmuted
        try check(AudioHardwareCreateProcessTap(tap, &tapID), "create monitor tap")
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Spatial monitor",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: false,
                                               kAudioSubTapUIDKey: tap.uuid.uuidString]],
        ]
        try check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &deviceID), "create monitor device")
        if recordCapacity > 0, let f = CA.get(tapID, kAudioTapPropertyFormat, as: AudioStreamBasicDescription.self) {
            print("monitor: tap \(Int(f.mSampleRate)) Hz \(f.mChannelsPerFrame) ch, its device \(Int(CA.sampleRate(deviceID))) Hz, output \(Int(CA.sampleRate(output))) Hz")
        }
        let peak = self.peak, recording = self.recording, capacity = recordCapacity, recorded = self.recorded
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, nil) { _, input, _, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            if capacity > 0, buffers.count > 0, let d = buffers[0].mData?.assumingMemoryBound(to: Float.self) {
                let ch = Int(buffers[0].mNumberChannels)
                let frames = Int(buffers[0].mDataByteSize) / (4 * max(1, ch))
                var at = recorded.pointee
                for i in 0..<frames where at < capacity {
                    recording[at * 2] = d[i * ch]
                    recording[at * 2 + 1] = ch > 1 ? d[i * ch + 1] : d[i * ch]
                    at += 1
                }
                recorded.pointee = at
            }
            var p = peak.pointee
            for b in buffers {
                guard let d = b.mData?.assumingMemoryBound(to: Float.self) else { continue }
                for i in 0..<(Int(b.mDataByteSize) / 4) { p = max(p, abs(d[i])) }
            }
            peak.pointee = p
        }, "create monitor reader")
        try check(AudioDeviceStart(deviceID, procID), "start monitor")
    }

    func stop() {
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
    }
}
