// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "NightscoutAdvisorKit",
    platforms: [
        .iOS(.v17),
        .watchOS(.v10),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "NightscoutAdvisorKit",
            targets: ["NightscoutAdvisorKit"]
        )
    ],
    targets: [
        .target(
            name: "NightscoutAdvisorKit",
            path: "Sources/NightscoutAdvisorKit"
        ),
        .testTarget(
            name: "NightscoutAdvisorKitTests",
            dependencies: ["NightscoutAdvisorKit"],
            path: "Tests/NightscoutAdvisorKitTests"
        )
    ]
)
