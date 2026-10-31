// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Murmur",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Murmur", targets: ["Murmur"]),
        .library(name: "MurmurKit", targets: ["MurmurKit"]),
    ],
    targets: [
        .target(
            name: "MurmurKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Murmur",
            dependencies: ["MurmurKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "DemoBroker",
            dependencies: ["MurmurKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MurmurKitTests",
            dependencies: ["MurmurKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
