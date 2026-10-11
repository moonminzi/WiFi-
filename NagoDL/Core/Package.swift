// swift-tools-version:5.9
import PackageDescription

// NAGO DL의 엔진(분할 다운로드, HLS, TS→MP4). UI가 없어서 리눅스에서도 빌드·테스트된다.
let package = Package(
    name: "NagoDLCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "NagoDLCore", targets: ["NagoDLCore"]),
    ],
    targets: [
        .target(name: "NagoDLCore", path: "Sources/NagoDLCore"),
        .testTarget(name: "NagoDLCoreTests", dependencies: ["NagoDLCore"], path: "Tests/NagoDLCoreTests"),
    ],
    swiftLanguageVersions: [.v5]
)
