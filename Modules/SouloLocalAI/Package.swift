// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SouloLocalAI",
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "SouloLocalAI", targets: ["SouloLocalAI"]),
               .executable(name: "local-ai-check", targets: ["LocalAICheck"])],
    targets: [
        .binaryTarget(name: "llama", path: "Vendor/llama.xcframework"),
        .target(name: "CLocalAIBridge", dependencies: ["llama"], publicHeadersPath: "include",
                linkerSettings: [.linkedFramework("Foundation"), .linkedFramework("Metal"), .linkedFramework("Accelerate")]),
        .target(name: "SouloLocalAI", dependencies: ["CLocalAIBridge"], resources: [.process("Resources")]),
        .executableTarget(name: "LocalAICheck", dependencies: ["SouloLocalAI"]),
        .testTarget(name: "SouloLocalAITests", dependencies: ["SouloLocalAI"])
    ],
    cxxLanguageStandard: .cxx17
)
