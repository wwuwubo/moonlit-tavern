# 第三方组件许可

## llama.cpp / ggml

- 用途：本地 GGUF 模型推理（Metal GPU 加速）
- 来源：https://github.com/ggml-org/llama.cpp ，官方发布的预编译 XCFramework，版本 `b11960`
- 获取方式：构建时由 `scripts/fetch-llama.sh` 下载并校验 SHA-256，不存入本仓库
- 许可：MIT License

```
MIT License

Copyright (c) 2023-2026 The ggml authors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## 构建工具（不进入 App）

- XcodeGen（MIT）：在 CI 中由 `project.yml` 生成 Xcode 工程

## 模型

模型权重不随 App 分发，由用户自行下载。推荐模型的许可：

| 模型 | 许可 |
|---|---|
| Qwen3.5-4B / Qwen3.5-2B | Apache-2.0 |
| Qwen3-4B-Instruct-2507 | Apache-2.0 |

除此之外，App 只使用 Apple 系统框架（SwiftUI、Foundation、Security、PhotosUI 等）。
