// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PDFCropper",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "PDFCropper",
            path: "Sources/PDFCropper",
            swiftSettings: [
                // Keep MVP friction low; tighten to Swift 6 strict concurrency in a later pass.
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "PDFCropperTests",
            dependencies: ["PDFCropper"],
            path: "Tests/PDFCropperTests",
            swiftSettings: [
                .swiftLanguageMode(.v5),
                // With Command Line Tools only (no Xcode), the build doesn't tell
                // the compiler where Swift Testing's @Test/@Suite macros live.
                // Harmless where that folder doesn't exist.
                .unsafeFlags(["-plugin-path", "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"])
            ]
        )
    ]
)
