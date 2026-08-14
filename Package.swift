// swift-tools-version:6.0
// SPM build/test harness for environments without full Xcode (CLT only).
// The Xcode project (LTXVideoGenerator/LTXVideoGenerator.xcodeproj) remains the
// canonical way to produce the .app bundle; this package exists so the app
// sources compile and unit tests run via `swift build` / `swift run LTXTests`.
// SPM_BUILD is defined here (not in the Xcode build), gating out #Preview
// blocks and the @main entry point which need Xcode-only tooling.
import PackageDescription

let package = Package(
    name: "LTXVideoGenerator",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "LTXVideoGeneratorCore",
            path: "LTXVideoGenerator/Sources",
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .define("SPM_BUILD"),
                .unsafeFlags(["-enable-testing"])
            ]
        ),
        .executableTarget(
            name: "LTXTests",
            dependencies: ["LTXVideoGeneratorCore"],
            path: "Tests/LTXTests",
            exclude: ["Fixtures"],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .define("SPM_BUILD")
            ]
        ),
    ]
)
