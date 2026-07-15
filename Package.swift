// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexMeter",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "CodexMeterCore", targets: ["CodexMeterCore"]),
        .executable(name: "CodexMeter", targets: ["CodexMeter"]),
        .executable(name: "codex-meter", targets: ["CodexMeterCLI"])
    ],
    targets: [
        .target(name: "CodexMeterCore", path: "Sources/CodexMeterCore"),
        .executableTarget(
            name: "CodexMeter",
            dependencies: ["CodexMeterCore"],
            path: "Sources/CodexMeter"
        ),
        .executableTarget(
            name: "CodexMeterCLI",
            dependencies: ["CodexMeterCore"],
            path: "Sources/CodexMeterCLI"
        )
    ]
)
