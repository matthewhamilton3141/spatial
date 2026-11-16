// swift-tools-version:5.9
import PackageDescription

// The module can't be called "Spatial": Apple ships a framework by that name.
let package = Package(
    name: "Spatial",
    platforms: [.macOS("15.0")],   // process taps (14.2) + Synchronization atomics (15)
    products: [.executable(name: "Spatial", targets: ["SpatialApp"])],
    targets: [
        .executableTarget(name: "SpatialApp", path: "Sources/SpatialApp")
    ]
)
