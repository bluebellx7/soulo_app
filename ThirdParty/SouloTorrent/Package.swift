// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "SouloTorrent", platforms: [.iOS(.v17)],
    products: [.library(name: "SouloTorrent", targets: ["SouloTorrent"])],
    targets: [.binaryTarget(name: "SouloTorrent", path: "Artifacts/SouloTorrent.xcframework")])
