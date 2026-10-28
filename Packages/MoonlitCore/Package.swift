// swift-tools-version: 5.9
// MoonlitCore：月下酒馆的平台无关核心逻辑。
// 不依赖 UIKit / SwiftUI / llama.cpp，可在 iOS、macOS 和 Linux 上编译与测试。

import PackageDescription

let package = Package(
    name: "MoonlitCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "MoonlitCore", targets: ["MoonlitCore"])
    ],
    targets: [
        .target(
            name: "MoonlitCore",
            path: "Sources/MoonlitCore"
        ),
        .testTarget(
            name: "MoonlitCoreTests",
            dependencies: ["MoonlitCore"],
            path: "Tests/MoonlitCoreTests",
            resources: [.copy("Fixtures")]
        )
    ]
)
