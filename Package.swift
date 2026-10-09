// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Zakidushka",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Zakidushka",
            path: "Sources/Zakidushka",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ZakidushkaTests",
            dependencies: ["Zakidushka"],
            path: "Tests/ZakidushkaTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
