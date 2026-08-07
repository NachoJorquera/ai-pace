// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AIPace",
    platforms: [
        .macOS(.v14),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-testing.git", "6.2.4" ..< "6.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "AIPace",
            path: "Sources/AIPace",
            exclude: ["Info.plist"]
        ),
        .testTarget(
            name: "AIPaceTests",
            dependencies: [
                "AIPace",
                .product(name: "Testing", package: "swift-testing"),
            ],
            path: "Tests/AIPaceTests"
        ),
    ]
)
