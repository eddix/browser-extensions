// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "nodia",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "NodiaCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "nodia-probe",
            dependencies: ["NodiaCore"]
        ),
        .executableTarget(
            name: "nodia",
            dependencies: ["NodiaCore"]
        ),
    ]
)
