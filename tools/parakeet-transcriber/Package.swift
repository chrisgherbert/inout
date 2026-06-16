// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ParakeetTranscriber",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.3")
    ],
    targets: [
        .executableTarget(
            name: "ParakeetTranscriber",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio")
            ]
        )
    ]
)
