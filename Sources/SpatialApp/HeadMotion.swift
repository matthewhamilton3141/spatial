import CoreMotion
import Foundation

/// Reads AirPods head movement through CoreMotion and reports it relative to
/// where you were facing at the start (or the last recenter).
final class HeadMotion {
    private let manager = CMHeadphoneMotionManager()
    private var reference: CMAttitude?
    private var onPose: ((HeadPose) -> Void)?

    var isAvailable: Bool { manager.isDeviceMotionAvailable }
    var isRunning: Bool { manager.isDeviceMotionActive }

    func start(_ onPose: @escaping (HeadPose) -> Void) {
        self.onPose = onPose
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        reference = nil
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let motion else { return }
            if self.reference == nil { self.reference = motion.attitude.copy() as? CMAttitude }
            let attitude = motion.attitude
            if let reference = self.reference { attitude.multiply(byInverseOf: reference) }
            let deg = Float(180 / Double.pi)
            // CoreMotion's +yaw is turning left; both engines read +yaw as
            // turning right (the smoke test shows +90 moves a centred sound
            // to the left ear). Pitch and roll signs are unverified by ear.
            self.onPose?(HeadPose(yaw: -Float(attitude.yaw) * deg,
                                  pitch: Float(attitude.pitch) * deg,
                                  roll: Float(attitude.roll) * deg))
        }
    }

    func recenter() { reference = nil }

    func stop() {
        manager.stopDeviceMotionUpdates()
        onPose?(HeadPose())
        onPose = nil
    }
}
