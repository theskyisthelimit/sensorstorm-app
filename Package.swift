// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SensorstormCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "SensorstormCore", targets: ["SensorstormCore"])
    ],
    targets: [
        // libsqlite3 ships with every Apple platform; `SQLiteExporter` writes the database
        // export through its C API rather than pulling in a wrapper, so the package keeps
        // its zero third-party dependencies.
        .target(name: "SensorstormCore",
                linkerSettings: [.linkedLibrary("sqlite3")]),
        .testTarget(name: "SensorstormCoreTests", dependencies: ["SensorstormCore"])
    ]
)
