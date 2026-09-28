// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ScreenOff",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ScreenOff", targets: ["ScreenOff"])
    ],
    targets: [
        .executableTarget(name: "ScreenOff")
    ]
)
