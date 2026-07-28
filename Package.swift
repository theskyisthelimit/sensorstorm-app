// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SensorstormCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "SensorstormCore", targets: ["SensorstormCore"])
    ],
    targets: [
        .target(name: "SensorstormCore"),
        .testTarget(name: "SensorstormCoreTests", dependencies: ["SensorstormCore"])
    ]
)
