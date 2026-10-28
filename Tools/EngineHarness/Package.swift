// swift-tools-version: 5.9
// 推理引擎实测工具：把 App 里的 LlamaEngine.swift 原样编译到 macOS 命令行程序中，
// 链接同一个 llama.cpp XCFramework（macOS 切片），用真实 GGUF 模型跑完整流程。
// CI 在运行前把 Vendor/llama.xcframework 和 App 的推理源码复制进来（见 scripts/run-engine-harness.sh）。

import PackageDescription

let package = Package(
    name: "EngineHarness",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../../Packages/MoonlitCore")
    ],
    targets: [
        .binaryTarget(name: "llama", path: "llama.xcframework"),
        .executableTarget(
            name: "EngineHarness",
            dependencies: [
                "llama",
                .product(name: "MoonlitCore", package: "MoonlitCore")
            ],
            path: "Sources/EngineHarness"
        )
    ]
)
