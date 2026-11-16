import CoreAudio
import Foundation

struct AudioError: Error, CustomStringConvertible {
    let description: String
    init(_ what: String, _ status: OSStatus? = nil) {
        description = status.map { "\(what) failed (\($0))" } ?? what
    }
}

func check(_ status: OSStatus, _ what: String) throws {
    guard status == noErr else { throw AudioError(what, status) }
}

/// One process that has talked to Core Audio.
struct AudioProcess {
    let object: AudioObjectID
    let pid: pid_t
    let bundleID: String
    let isPlaying: Bool
}

/// What kind of thing the sound comes out of. Picks how Apple's renderer
/// shapes it: binaural for headphones, virtual surround for speakers.
enum OutputKind: String {
    case headphones, builtInSpeakers, externalSpeakers
}

/// Thin, typed reads of Core Audio properties.
enum CA {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func get<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, as _: T.Type) -> T? {
        var address = address(selector, scope)
        var size = UInt32(MemoryLayout<T>.size)
        let value = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { value.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, value) == noErr else { return nil }
        return value.pointee
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func list(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var address = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func defaultOutput() -> AudioObjectID? {
        guard let id = get(system, kAudioHardwarePropertyDefaultOutputDevice, as: AudioObjectID.self),
              id != kAudioObjectUnknown else { return nil }
        return id
    }

    static func uid(_ device: AudioObjectID) -> String? { string(device, kAudioDevicePropertyDeviceUID) }
    static func name(_ device: AudioObjectID) -> String { string(device, kAudioObjectPropertyName) ?? "Output" }

    static func sampleRate(_ device: AudioObjectID) -> Double {
        get(device, kAudioDevicePropertyNominalSampleRate, as: Float64.self) ?? 0
    }

    static func processes() -> [AudioProcess] {
        list(system, kAudioHardwarePropertyProcessObjectList).compactMap { object in
            guard let pid = get(object, kAudioProcessPropertyPID, as: pid_t.self) else { return nil }
            let bundle = string(object, kAudioProcessPropertyBundleID) ?? ""
            let playing = (get(object, kAudioProcessPropertyIsRunningOutput, as: UInt32.self) ?? 0) != 0
            return AudioProcess(object: object, pid: pid, bundleID: bundle, isPlaying: playing)
        }
    }

    /// Headphones, the MacBook's own speakers, or speakers plugged in somewhere.
    static func kind(of device: AudioObjectID) -> OutputKind {
        let transport = get(device, kAudioDevicePropertyTransportType, as: UInt32.self) ?? 0
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn:
            // The built-in output is one device whose "data source" flips
            // between the speakers and the headphone jack.
            let source = get(device, kAudioDevicePropertyDataSource, kAudioObjectPropertyScopeOutput, as: UInt32.self)
            return source == fourCC("hdpn") ? .headphones : .builtInSpeakers
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort,
             kAudioDeviceTransportTypeAirPlay, kAudioDeviceTransportTypeThunderbolt:
            return .externalSpeakers
        default:
            return .headphones   // Bluetooth, USB headsets and DACs
        }
    }

    /// Seconds between handing samples to a device and hearing them.
    static func latency(of device: AudioObjectID) -> Double {
        let rate = sampleRate(device)
        guard rate > 0 else { return 0 }
        let out = kAudioObjectPropertyScopeOutput
        let frames = Double(get(device, kAudioDevicePropertyLatency, out, as: UInt32.self) ?? 0)
                   + Double(get(device, kAudioDevicePropertySafetyOffset, out, as: UInt32.self) ?? 0)
                   + Double(get(device, kAudioDevicePropertyBufferFrameSize, as: UInt32.self) ?? 0)
        return frames / rate
    }
}

func fourCC(_ s: String) -> UInt32 {
    s.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
}
