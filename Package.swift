// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "PerformanceHUD",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PerformanceHUD", targets: ["PerformanceHUD"]),
    ],
    targets: [
        // Native sensor reading that needs C/Objective-C: the IOHID thermal hub
        // (temperatures) and a minimal SMC reader (fan RPM). Isolated here so all
        // the private-but-stable Apple SPI lives in one place.
        .target(
            name: "SensorBridge",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("Foundation"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
        .executableTarget(
            name: "PerformanceHUD",
            dependencies: ["SensorBridge"],
            linkerSettings: [
                .linkedFramework("IOKit"),
            ]
        ),
    ]
)
