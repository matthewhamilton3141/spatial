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

    static func list(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                     _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var address = address(selector, scope)
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

    /// AirPlay (HomePod, Apple TV, AirPlay speakers): about 2 s of latency,
    /// and no Spatial Audio menu to gain.
    static func isAirPlay(_ device: AudioObjectID) -> Bool {
        get(device, kAudioDevicePropertyTransportType, as: UInt32.self) == kAudioDeviceTransportTypeAirPlay
    }

    /// Lets the Mac idle-sleep while this process runs audio. Spatial's
    /// player runs nonstop (silence while Spotify is paused), and by default
    /// any audio IO holds off idle sleep. While Spotify really plays, its
    /// own audio keeps the Mac awake exactly as it would without Spatial.
    static func allowIdleSleep() {
        var address = address(kAudioHardwarePropertySleepingIsAllowed)
        var allowed: UInt32 = 1
        AudioObjectSetPropertyData(system, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &allowed)
    }

    /// Turns off every input stream of `device` for `proc` except `keep`, so
    /// the device doesn't start inputs nobody reads (a headset's mic).
    @discardableResult
    static func useOnlyInputStream(_ keep: Int, of device: AudioObjectID, proc: AudioDeviceIOProcID) -> OSStatus {
        let count = list(device, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput).count
        guard count > 1 else { return noErr }
        // AudioHardwareIOProcStreamUsage: the IOProc, a stream count, then one
        // UInt32 per stream (a variable-length C struct).
        let header = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn)!
        let size = header + count * MemoryLayout<UInt32>.size
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<AudioHardwareIOProcStreamUsage>.alignment)
        defer { raw.deallocate() }
        raw.storeBytes(of: unsafeBitCast(proc, to: UnsafeMutableRawPointer.self), as: UnsafeMutableRawPointer.self)
        raw.storeBytes(of: UInt32(count), toByteOffset: MemoryLayout<UnsafeMutableRawPointer>.size, as: UInt32.self)
        for i in 0..<count {
            raw.storeBytes(of: UInt32(i == keep ? 1 : 0), toByteOffset: header + i * 4, as: UInt32.self)
        }
        var address = address(kAudioDevicePropertyIOProcStreamUsage, kAudioObjectPropertyScopeInput)
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(size), raw)
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

/// A Core Audio property listener that really stops when removed. Calls
/// `action` on the main thread.
///
/// Not the block API: Swift imports AudioObjectPropertyListenerBlock as a
/// Swift closure, so every Add and Remove call wraps a new block, Remove
/// never matches what Add registered, and it reports success anyway.
/// Listeners then piled up for the life of the app and kept firing for
/// devices long since left. The function-pointer API matches on (proc,
/// client data), which stay the same.
final class PropertyListener {
    private final class Box {
        let action: () -> Void
        var live = true   // main thread only
        init(_ action: @escaping () -> Void) { self.action = action }
    }

    private let object: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let box: Box
    private var token: UnsafeMutableRawPointer?

    init?(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, _ action: @escaping () -> Void) {
        self.object = object
        self.address = address
        box = Box(action)
        let token = Unmanaged.passRetained(box).toOpaque()
        guard AudioObjectAddPropertyListener(object, &self.address, Self.proc, token) == noErr else {
            Unmanaged<Box>.fromOpaque(token).release()
            return nil
        }
        self.token = token
    }

    deinit { remove() }

    /// Main thread.
    func remove() {
        guard let token else { return }
        self.token = nil
        box.live = false
        AudioObjectRemovePropertyListener(object, &address, Self.proc, token)
        // A callback already on its way may still hold the pointer: let go
        // of it a moment later rather than now.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { Unmanaged<Box>.fromOpaque(token).release() }
    }

    private static let proc: AudioObjectPropertyListenerProc = { _, _, _, data in
        guard let data else { return noErr }
        let box = Unmanaged<Box>.fromOpaque(data).takeUnretainedValue()
        DispatchQueue.main.async { if box.live { box.action() } }
        return noErr
    }
}

/// Whether macOS lets this app hear other apps (System Audio Recording).
///
/// There's no public API to ask, so this makes the same private TCC call
/// Core Audio makes before it prompts. If that call ever goes away, the
/// answer is `.unknown` and Spatial carries on as if it had never asked.
enum AudioCapturePermission {
    case granted, denied, unknown

    static var status: AudioCapturePermission {
        guard let preflight else { return .unknown }
        switch preflight("kTCCServiceAudioCapture" as CFString, nil) {
        case 0: return .granted
        case 1: return .denied
        default: return .unknown   // 2: not asked yet
        }
    }

    /// System Settings › Privacy & Security › Screen & System Audio Recording.
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!

    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int32
    private static let preflight: Preflight? = {
        guard let tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW),
              let symbol = dlsym(tcc, "TCCAccessPreflight") else { return nil }
        return unsafeBitCast(symbol, to: Preflight.self)
    }()
}
