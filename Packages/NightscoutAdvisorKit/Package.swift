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
        ),
        .executable(
            name: "advisor-cli",
            targets: ["AdvisorCLI"]
        )
    ],
    targets: [
        .target(
            name: "NightscoutAdvisorKit",
            path: "Sources/NightscoutAdvisorKit"
        ),
        .executableTarget(
            name: "AdvisorCLI",
            dependencies: ["NightscoutAdvisorKit"],
            path: "Sources/AdvisorCLI"
        ),
        .testTarget(
            name: "NightscoutAdvisorKitTests",
            dependencies: ["NightscoutAdvisorKit"],
            path: "Tests/NightscoutAdvisorKitTests"
        )
    ]
)
