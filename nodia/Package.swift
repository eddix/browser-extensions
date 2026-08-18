// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "nodia",
    // Spelled as a string because the `.v26` shorthand needs
    // swift-tools-version 6.2, and that version switches the whole package to
    // the Swift 6 language mode — a concurrency migration this app hasn't done
    // and doesn't need in order to ask for a newer macOS.
    platforms: [.macOS("26.0")],
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
        .testTarget(
            name: "NodiaCoreTests",
            dependencies: ["NodiaCore"]
        ),
    ]
)
