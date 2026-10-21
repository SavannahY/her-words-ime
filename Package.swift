// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HerWordsSpeech",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "HerBilingualASR", targets: ["HerBilingualASR"]),
        .executable(name: "her-transcribe", targets: ["HerTranscribe"]),
        .executable(name: "her-speech-mac", targets: ["HerSpeechMac"]),
    ],
    dependencies: [
        .package(url: "https://github.com/k2-fsa/sherpa-onnx", exact: "1.13.8"),
    ],
    targets: [
        .target(
            name: "HerSpeechTextCore",
            path: "ios/Shared",
            exclude: ["HerPinyinEngine.swift"],
            sources: ["HerSpeechText.swift", "HerModels.swift", "HerRewriter.swift", "HerSpeechWording.swift"]
        ),
        .target(
            name: "HerBilingualASR",
            dependencies: [
                "HerSpeechTextCore",
                .product(name: "sherpa-onnx", package: "sherpa-onnx"),
            ],
            path: "native/Sources/HerBilingualASR",
            resources: [.copy("Resources/asr-model.json")]
        ),
        .executableTarget(
            name: "HerTranscribe",
            dependencies: ["HerBilingualASR", "HerSpeechTextCore"],
            path: "native/Sources/HerTranscribe"
        ),
        .executableTarget(
            name: "HerSpeechMac",
            dependencies: ["HerBilingualASR", "HerSpeechTextCore"],
            path: "native/Sources/HerSpeechMac"
        ),
        .testTarget(
            name: "HerBilingualASRTests",
            dependencies: ["HerBilingualASR"],
            path: "native/Tests/HerBilingualASRTests"
        ),
    ]
)
