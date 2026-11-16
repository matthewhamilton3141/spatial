import AudioToolbox
import Foundation

/// Where the mixer's input callback finds this block's samples.
private struct StereoInput {
    var left: UnsafePointer<Float>?
    var right: UnsafePointer<Float>?
}

private let feedMixer: AURenderCallback = { refCon, _, _, _, frames, ioData in
    guard let ioData else { return noErr }
    let input = refCon.assumingMemoryBound(to: StereoInput.self).pointee
    let buffers = UnsafeMutableAudioBufferListPointer(ioData)
    for (i, buffer) in buffers.enumerated() {
        guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
        if let src = i == 0 ? input.left : input.right {
            data.update(from: src, count: Int(frames))
        } else {
            data.update(repeating: 0, count: Int(frames))
        }
    }
    return noErr
}

/// Apple's AUSpatialMixer set up the way "Spatialize Stereo" sounds on an
/// iPhone: the stereo pair becomes an ambience bed (left and right as
/// far-field sources around you), rendered for whatever you're listening on.
final class MixerEngine: SpatialEngine {
    let kind = EngineKind.mixer
    private(set) var usingPersonalProfile: Bool?

    private var unit: AudioUnit?
    private let input = UnsafeMutablePointer<StereoInput>.allocate(capacity: 1)
    private let output = AudioBufferList.allocate(maximumBuffers: 2)
    private var time = AudioTimeStamp()
    private var headTracking = HeadTracking.off

    init() { input.initialize(to: StereoInput()) }

    deinit {
        teardown()
        input.deallocate()
        output.unsafeMutablePointer.deallocate()
    }

    private func teardown() {
        if let unit {
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        unit = nil
    }

    func prepare(sampleRate: Double, output kind: OutputKind) throws {
        teardown()
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Mixer,
            componentSubType: kAudioUnitSubType_SpatialMixer,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw AudioError("AUSpatialMixer is not on this Mac")
        }
        var made: AudioUnit?
        try check(AudioComponentInstanceNew(component, &made), "open AUSpatialMixer")
        guard let unit = made else { throw AudioError("open AUSpatialMixer") }
        self.unit = unit

        func set<T>(_ property: AudioUnitPropertyID, _ scope: AudioUnitScope, _ value: T, _ what: String) throws {
            var v = value
            try check(AudioUnitSetProperty(unit, property, scope, 0, &v, UInt32(MemoryLayout<T>.size)), what)
        }

        let format = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        let stereo = AudioChannelLayout(mChannelLayoutTag: kAudioChannelLayoutTag_Stereo,
                                        mChannelBitmap: [], mNumberChannelDescriptions: 0,
                                        mChannelDescriptions: AudioChannelDescription())

        try set(kAudioUnitProperty_ElementCount, kAudioUnitScope_Input, UInt32(1), "set input count")
        try set(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, format, "set input format")
        try set(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, format, "set output format")
        try set(kAudioUnitProperty_AudioChannelLayout, kAudioUnitScope_Input, stereo, "set input layout")
        try set(kAudioUnitProperty_AudioChannelLayout, kAudioUnitScope_Output, stereo, "set output layout")
        try set(kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, UInt32(maxFrames), "set block size")

        // The heart of it: let Apple pick the best algorithm for the output,
        // and treat the two channels as a bed around you, not one point.
        try set(kAudioUnitProperty_SpatializationAlgorithm, kAudioUnitScope_Input,
                AUSpatializationAlgorithm.spatializationAlgorithm_UseOutputType.rawValue, "set algorithm")
        try set(kAudioUnitProperty_SpatialMixerSourceMode, kAudioUnitScope_Input,
                AUSpatialMixerSourceMode.spatialMixerSourceMode_AmbienceBed.rawValue, "set source mode")
        let outputType: AUSpatialMixerOutputType
        switch kind {
        case .headphones: outputType = .spatialMixerOutputType_Headphones
        case .builtInSpeakers: outputType = .spatialMixerOutputType_BuiltInSpeakers
        case .externalSpeakers: outputType = .spatialMixerOutputType_ExternalSpeakers
        }
        try set(kAudioUnitProperty_SpatialMixerOutputType, kAudioUnitScope_Global, outputType.rawValue, "set output type")
        // "Auto" follows System Settings, so a scanned ear profile is used if
        // you have one. Not fatal if refused.
        _ = try? set(kAudioUnitProperty_SpatialMixerPersonalizedHRTFMode, kAudioUnitScope_Global,
                     AUSpatialMixerPersonalizedHRTFMode.auto.rawValue, "set personal profile")
        // No reverb: with UseOutputType the mixer ignores its internal reverb
        // (measured), and Apple's own Spatialize Stereo has none either.
        try set(kAudioUnitProperty_UsesInternalReverb, kAudioUnitScope_Global, UInt32(0), "disable reverb")

        var callback = AURenderCallbackStruct(inputProc: feedMixer, inputProcRefCon: UnsafeMutableRawPointer(input))
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                                       &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "set feed")

        try check(AudioUnitInitialize(unit), "start AUSpatialMixer")

        applyHeadTracking()
        time = AudioTimeStamp()
        time.mFlags = .sampleTimeValid

        var personal: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioUnitGetProperty(unit, kAudioUnitProperty_SpatialMixerAnyInputIsUsingPersonalizedHRTF,
                                          kAudioUnitScope_Global, 0, &personal, &size)
        usingPersonalProfile = status == noErr ? personal != 0 : nil
    }

    func render(left: UnsafePointer<Float>, right: UnsafePointer<Float>,
                outLeft: UnsafeMutablePointer<Float>, outRight: UnsafeMutablePointer<Float>, frames: Int) {
        guard let unit else {
            outLeft.update(from: left, count: frames)
            outRight.update(from: right, count: frames)
            return
        }
        input.pointee = StereoInput(left: left, right: right)
        let bytes = UInt32(frames * MemoryLayout<Float>.size)
        output[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: bytes, mData: UnsafeMutableRawPointer(outLeft))
        output[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: bytes, mData: UnsafeMutableRawPointer(outRight))
        var flags = AudioUnitRenderActionFlags()
        let status = AudioUnitRender(unit, &flags, &time, 0, UInt32(frames), output.unsafeMutablePointer)
        time.mSampleTime += Double(frames)
        if status != noErr {
            outLeft.update(repeating: 0, count: frames)
            outRight.update(repeating: 0, count: frames)
        }
    }

    func setHeadTracking(_ mode: HeadTracking) {
        headTracking = mode
        applyHeadTracking()
    }

    func setHeadPose(_ pose: HeadPose) {
        guard let unit, headTracking == .motion else { return }
        AudioUnitSetParameter(unit, kSpatialMixerParam_HeadYaw, kAudioUnitScope_Global, 0, pose.yaw, 0)
        AudioUnitSetParameter(unit, kSpatialMixerParam_HeadPitch, kAudioUnitScope_Global, 0, pose.pitch, 0)
        AudioUnitSetParameter(unit, kSpatialMixerParam_HeadRoll, kAudioUnitScope_Global, 0, pose.roll, 0)
    }

    /// Not offered for this engine; see prepare().
    func setRoom(_ on: Bool) {}

    private func applyHeadTracking() {
        guard let unit else { return }
        var on: UInt32 = headTracking == .builtIn ? 1 : 0
        AudioUnitSetProperty(unit, kAudioUnitProperty_SpatialMixerEnableHeadTracking, kAudioUnitScope_Global, 0,
                             &on, UInt32(MemoryLayout<UInt32>.size))
        if headTracking != .motion { setHeadPoseZero(unit) }
    }

    private func setHeadPoseZero(_ unit: AudioUnit) {
        for p in [kSpatialMixerParam_HeadYaw, kSpatialMixerParam_HeadPitch, kSpatialMixerParam_HeadRoll] {
            AudioUnitSetParameter(unit, p, kAudioUnitScope_Global, 0, 0, 0)
        }
    }

    /// Whether head tracking is switched on inside the mixer (for the smoke test).
    var builtInTrackingAccepted: Bool {
        guard let unit else { return false }
        var on: UInt32 = 1
        return AudioUnitSetProperty(unit, kAudioUnitProperty_SpatialMixerEnableHeadTracking, kAudioUnitScope_Global, 0,
                                    &on, UInt32(MemoryLayout<UInt32>.size)) == noErr
    }
}
