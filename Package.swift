// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Gauge",
    platforms: [.macOS(.v13)],
    targets: [.executableTarget(name: "Gauge")],
    swiftLanguageModes: [.v5]
)
