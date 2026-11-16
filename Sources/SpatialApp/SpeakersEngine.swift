import AVFAudio
import Foundation

/// Where the source nodes find this block's samples.
private final class Feed {
    var left: UnsafePointer<Float>?
    var right: UnsafePointer<Float>?
}

/// The 3D engine route: AVAudioEnvironmentNode in manual rendering mode with
/// two point sources standing where a pair of studio monitors would, 30° to
/// either side, 2 m away. Driven block by block from the audio thread.
final class SpeakersEngine: SpatialEngine {
    let kind = EngineKind.speakers
    var usingPersonalProfile: Bool? { nil }   // this route can't ask

    private var engine: AVAudioEngine?
    private var environment: AVAudioEnvironmentNode?
    private var sources: [AVAudioSourceNode] = []
    private var block: AVAudioEngineManualRenderingBlock?
    private let feed = Feed()
    private let output = AudioBufferList.allocate(maximumBuffers: 2)
    private var headTracking = HeadTracking.off
    private var room = false

    deinit {
        engine?.stop()
        output.unsafeMutablePointer.deallocate()
    }

    func prepare(sampleRate: Double, output kind: OutputKind) throws {
        engine?.stop()
        let engine = AVAudioEngine()
        let environment = AVAudioEnvironmentNode()
        guard let stereo = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2),
              let mono = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            throw AudioError("no audio format at \(sampleRate) Hz")
        }
        try engine.enableManualRenderingMode(.realtime, format: stereo, maximumFrameCount: AVAudioFrameCount(maxFrames))
        engine.attach(environment)

        let feed = self.feed
        var sources: [AVAudioSourceNode] = []
        for (channel, azimuth) in [(0, -30.0), (1, 30.0)] {
            let source = AVAudioSourceNode(format: mono) { _, _, frames, list -> OSStatus in
                let buffers = UnsafeMutableAudioBufferListPointer(list)
                guard let out = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
                if let src = channel == 0 ? feed.left : feed.right {
                    out.update(from: src, count: Int(frames))
                } else {
                    out.update(repeating: 0, count: Int(frames))
                }
                return noErr
            }
            engine.attach(source)
            engine.connect(source, to: environment, format: mono)
            let a = azimuth * .pi / 180, distance = 2.0
            // Listener faces -Z with +X to the right.
            source.position = AVAudio3DPoint(x: Float(sin(a) * distance), y: 0, z: Float(-cos(a) * distance))
            source.renderingAlgorithm = .HRTFHQ
            source.sourceMode = .pointSource
            sources.append(source)
        }
        engine.connect(environment, to: engine.mainMixerNode, format: stereo)

        switch kind {
        case .headphones: environment.outputType = .headphones
        case .builtInSpeakers: environment.outputType = .builtInSpeakers
        case .externalSpeakers: environment.outputType = .externalSpeakers
        }
        // Keep the speakers at full level: no fade with their 2 m distance.
        environment.distanceAttenuationParameters.referenceDistance = 10
        environment.distanceAttenuationParameters.maximumDistance = 100
        environment.reverbParameters.enable = true
        environment.reverbParameters.loadFactoryReverbPreset(.mediumRoom)
        environment.reverbParameters.level = -6

        try engine.start()
        self.engine = engine
        self.environment = environment
        self.sources = sources
        self.block = engine.manualRenderingBlock
        applyRoom()
    }

    func render(left: UnsafePointer<Float>, right: UnsafePointer<Float>,
                outLeft: UnsafeMutablePointer<Float>, outRight: UnsafeMutablePointer<Float>, frames: Int) {
        guard let block else {
            outLeft.update(from: left, count: frames)
            outRight.update(from: right, count: frames)
            return
        }
        feed.left = left
        feed.right = right
        let bytes = UInt32(frames * MemoryLayout<Float>.size)
        output[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: bytes, mData: UnsafeMutableRawPointer(outLeft))
        output[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: bytes, mData: UnsafeMutableRawPointer(outRight))
        var error: OSStatus = noErr
        let status = block(AVAudioFrameCount(frames), output.unsafeMutablePointer, &error)
        if status != .success {
            outLeft.update(repeating: 0, count: frames)
            outRight.update(repeating: 0, count: frames)
        }
    }

    func setHeadTracking(_ mode: HeadTracking) {
        headTracking = mode
        if mode == .off { environment?.listenerAngularOrientation = AVAudio3DAngularOrientation(yaw: 0, pitch: 0, roll: 0) }
    }

    func setHeadPose(_ pose: HeadPose) {
        guard headTracking != .off else { return }   // built-in means motion here
        environment?.listenerAngularOrientation = AVAudio3DAngularOrientation(yaw: pose.yaw, pitch: pose.pitch, roll: pose.roll)
    }

    func setRoom(_ on: Bool) {
        room = on
        applyRoom()
    }

    private func applyRoom() {
        for source in sources { source.reverbBlend = room ? 0.2 : 0 }
    }
}
