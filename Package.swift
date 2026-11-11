// swift-tools-version:5.10
import Foundation
import PackageDescription

/// Minimum macOS. Release packaging overrides it (e.g. NOSLEEP_MIN_MACOS=27.0) to build per-OS DMGs.
let minimumMacOS = ProcessInfo.processInfo.environment["NOSLEEP_MIN_MACOS"] ?? "14.0"

let package = Package(
    name: "NoSleep",
    platforms: [.macOS(minimumMacOS)],
    products: [
        .executable(name: "NoSleepApp", targets: ["NoSleepApp"]),
        .executable(name: "nosleep", targets: ["NoSleepCLI"]),
        .executable(name: "nosleep-selftest", targets: ["NoSleepSelfTest"]),
    ],
    targets: [
        .target(name: "NoSleepCore"),
        .executableTarget(
            name: "NoSleepApp",
            dependencies: ["NoSleepCore"],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .executableTarget(name: "NoSleepCLI", dependencies: ["NoSleepCore"]),
        .executableTarget(name: "NoSleepSelfTest", dependencies: ["NoSleepCore"]),
    ]
)
