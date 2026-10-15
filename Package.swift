// swift-tools-version: 6.0
import PackageDescription

// Target names are deliberately generic; the app's display name and bundle id
// come from app.config (see scripts/gen-config.sh and scripts/build-app.sh).
let package = Package(
    name: "archive-burner",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "App", targets: ["App"]),
    ],
    targets: [
        .target(
            name: "BurnCore",
            linkerSettings: [.linkedFramework("DiscRecording")]
        ),
        .executableTarget(
            name: "App",
            dependencies: ["BurnCore"]
        ),
        .testTarget(
            name: "BurnCoreTests",
            dependencies: ["BurnCore"]
        ),
    ]
)
