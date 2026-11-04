// swift-tools-version:5.9
import PackageDescription

// Two images, for launch speed: the Blink executable links only AppKit and ImageIO
// (images, text, CSV). Everything that pulls in a heavy framework — PDFKit, WebKit,
// MapKit, AVKit, Quick Look — lives in libBlinkViewers.dylib, which is dlopen'ed the
// first time such a file is opened.
let package = Package(
    name: "Blink",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Blink", targets: ["Blink"]),
        .library(name: "BlinkViewers", type: .dynamic, targets: ["BlinkViewers"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-cmark.git", branch: "gfm"),
    ],
    targets: [
        .target(name: "BlinkShared", path: "Sources/BlinkShared"),
        .executableTarget(
            name: "Blink",
            dependencies: ["BlinkShared"],
            path: "Sources/Blink"
        ),
        .target(
            name: "BlinkViewers",
            dependencies: [
                "BlinkShared",
                .product(name: "cmark-gfm", package: "swift-cmark"),
                .product(name: "cmark-gfm-extensions", package: "swift-cmark"),
            ],
            path: "Sources/BlinkViewers"
        ),
    ]
)
