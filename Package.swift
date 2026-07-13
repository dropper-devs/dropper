// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Dropper",
    platforms: [.macOS(.v14)],  // .focusEffectDisabled requires 14
    targets: [
        .target(name: "CaptureKit", path: "Sources/CaptureKit"),
        .executableTarget(name: "Dropper", dependencies: ["CaptureKit"],
                          path: "Sources/Dropper",
                          resources: [.process("Resources")]),
        .testTarget(name: "CaptureKitTests", dependencies: ["CaptureKit"],
                    path: "Tests/CaptureKitTests"),
        .testTarget(name: "DropperTests", dependencies: ["Dropper"],
                    path: "Tests/DropperTests")
    ]
)
