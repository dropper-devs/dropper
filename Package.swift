// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Dropper",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Dropper",
                          path: "Sources/Dropper",
                          resources: [.process("Resources")]),
        .testTarget(name: "DropperTests", dependencies: ["Dropper"],
                    path: "Tests/DropperTests")
    ]
)
