// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SwiftSaturationSampler",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "saturation-sampler", targets: ["SaturationSampler"])
    ],
    targets: [
        .executableTarget(name: "SaturationSampler")
    ]
)
