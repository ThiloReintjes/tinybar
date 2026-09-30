// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Subar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Subar", targets: ["Subar"]),
        .executable(name: "subar-cli", targets: ["subar-cli"]),
    ],
    targets: [
        .target(
            name: "SubarCore",
            linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(
            name: "Subar",
            dependencies: ["SubarCore"]),
        .executableTarget(
            name: "subar-cli",
            dependencies: ["SubarCore"]),
        .testTarget(
            name: "SubarCoreTests",
            dependencies: ["SubarCore"]),
    ])
