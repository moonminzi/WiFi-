// swift-tools-version:5.9
import PackageDescription

// NAGO TL의 엔진: 말풍선 정밀화·글자 지우기·식자 배치·Claude 요청·CBZ. UI가 없어서 리눅스에서도 시험된다.
let package = Package(
    name: "NagoTLCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "NagoTLCore", targets: ["NagoTLCore"]),
    ],
    targets: [
        .target(name: "NagoTLCore", path: "Sources/NagoTLCore"),
        .testTarget(name: "NagoTLCoreTests", dependencies: ["NagoTLCore"], path: "Tests/NagoTLCoreTests"),
    ],
    swiftLanguageVersions: [.v5]
)
