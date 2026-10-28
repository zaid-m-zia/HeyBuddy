// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "Buddy",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "Buddy", path: "Sources/Buddy"),
        .testTarget(name: "BuddyTests", dependencies: ["Buddy"], path: "Tests/BuddyTests")
    ]
)
