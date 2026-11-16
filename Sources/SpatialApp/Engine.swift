import Foundation

/// Which renderer turns Spotify's stereo into spatial sound.
enum EngineKind: String, CaseIterable {
    /// Hand Spotify's untouched stereo to macOS through a spatial-capable
    /// player, so the AirPods menu in Control Center works and macOS does the
    /// rendering (Off / Fixed / Head Tracked, your personal profile).
    case system
    /// Apple's AUSpatialMixer: the renderer behind "Spatialize Stereo" on
    /// iPhone. The song becomes a far-field bed around you; AirPods head
    /// tracking and your personalized profile are built in.
    case mixer

    /// Whether this app renders the spatial sound (vs macOS doing it).
    var rendersItself: Bool { self != .system }

    var title: String {
        switch self {
        case .system: return "System (AirPods Menu)"
        case .mixer: return "Apple Spatial Mixer"
        }
    }
}

enum HeadTracking: String, CaseIterable {
    case off
    /// The mixer reads the AirPods itself. Only the mixer engine has this.
    case builtIn
    /// We read the AirPods through CMHeadphoneMotionManager and turn the
    /// listener ourselves.
    case motion

    var title: String {
        switch self {
        case .off: return "Off (Fixed)"
        case .builtIn: return "Built In"
        case .motion: return "Motion Sensors"
        }
    }
}

/// Head orientation in degrees, relative to where you were facing when
/// tracking started (or the last recenter).
struct HeadPose {
    var yaw: Float = 0
    var pitch: Float = 0
    var roll: Float = 0
}

/// A stereo in, stereo out spatial renderer. `render` runs on the audio
/// thread: it must not allocate, lock, or wait.
protocol SpatialEngine: AnyObject {
    var kind: EngineKind { get }
    /// Builds the renderer for one sample rate. Called off the audio thread.
    func prepare(sampleRate: Double, output: OutputKind) throws
    func render(left: UnsafePointer<Float>, right: UnsafePointer<Float>,
                outLeft: UnsafeMutablePointer<Float>, outRight: UnsafeMutablePointer<Float>,
                frames: Int)
    func setHeadTracking(_ mode: HeadTracking)
    func setHeadPose(_ pose: HeadPose)
    /// True once Apple confirms your personal spatial audio profile is in
    /// use, false if it fell back to the generic one, nil if unknowable.
    var usingPersonalProfile: Bool? { get }
}

/// The largest block an engine is asked to render at once; bigger device
/// buffers are cut into pieces this size.
let maxFrames = 4096

func makeEngine(_ kind: EngineKind) -> SpatialEngine {
    switch kind {
    case .system: return PassthroughEngine()
    case .mixer: return MixerEngine()
    }
}

/// Stands in for an engine in system mode, where macOS does the rendering.
final class PassthroughEngine: SpatialEngine {
    let kind = EngineKind.system
    var usingPersonalProfile: Bool? { nil }
    func prepare(sampleRate: Double, output: OutputKind) throws {}
    func render(left: UnsafePointer<Float>, right: UnsafePointer<Float>,
                outLeft: UnsafeMutablePointer<Float>, outRight: UnsafeMutablePointer<Float>, frames: Int) {
        outLeft.update(from: left, count: frames)
        outRight.update(from: right, count: frames)
    }
    func setHeadTracking(_ mode: HeadTracking) {}
    func setHeadPose(_ pose: HeadPose) {}
}
