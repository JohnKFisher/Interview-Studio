// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "YearlyInterviewStudio",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .library(name: "Core", targets: ["Core"]),
        .executable(name: "YearlyInterviewStudioApp", targets: ["YearlyInterviewStudioApp"]),
        .executable(name: "YearlyInterviewStudioCLI", targets: ["YearlyInterviewStudioCLI"])
    ],
    targets: [
        .target(
            name: "Core",
            path: "Sources/Core"
        ),
        .executableTarget(
            name: "YearlyInterviewStudioApp",
            dependencies: ["Core"],
            path: "Sources/App",
            resources: [
                .process("Resources")
            ]
        ),
        .executableTarget(
            name: "YearlyInterviewStudioCLI",
            dependencies: ["Core"],
            path: "Sources/CLI"
        ),
        .testTarget(
            name: "CoreTests",
            dependencies: ["Core"],
            path: "Tests/CoreTests",
            resources: [
                .process("Fixtures")
            ]
        )
    ]
)
