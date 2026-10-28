# 测试报告

版本 0.1.0 · 构建 #14 · 提交 `35aa1c4` · 2026 年 10 月 29 日

完整版（含截图、技术调研、里程碑）见 Release 附带的《月下酒馆 交付与测试报告》。

## 验收问题

| # | 问题 | 状态 |
|---|---|---|
| 1 | SwiftUI 工程是否真实存在？ | 已完成并验证 |
| 2 | 是否通过真实的 iOS 编译？ | 已完成并验证 |
| 3 | 是否产生了 IPA 或其他可供签名的构建产物？ | 已完成并验证 |
| 4 | 是否可以导入角色卡？ | 已完成并验证 |
| 5 | 聊天记录能否在重启后保留？ | 已完成并验证（模拟器） |
| 6 | 是否真正调用本地模型？ | 已完成并验证 |
| 7 | 断网后能否生成 AI 回复？ | 已实现但未验证 |
| 8 | 是否存在任何强制云端依赖？ | 已完成并验证（不存在） |
| 9 | 是否完成 8K 上下文测试？ | 已完成并验证（macOS 虚拟机）；真机受环境限制 |
| 10 | 是否完成真实 iPad 设备测试？ | 受环境限制 |

### 1. SwiftUI 工程是否真实存在？

**已完成并验证**。App 由 SwiftUI 编写，App 层 20 个源文件，核心库 26 个源文件，合计约 9900 行 Swift，另有约 1800 行测试代码。工程由 XcodeGen 的 project.yml 描述，每次构建自动生成 MoonlitTavern.xcodeproj 后编译。

证据：仓库目录 `MoonlitTavern/`、`Packages/MoonlitCore/`、`project.yml`；`MoonlitTavern-XcodeProject.zip` 内含 `MoonlitTavern.xcodeproj/project.pbxproj`。

### 2. 是否通过真实的 iOS 编译？

**已完成并验证**。在 GitHub 托管的 macOS 机器上用 xcodebuild 编译 Release、iphoneos、arm64。Xcode 27.1（iOS 27.1 SDK）与 Xcode 26.6（iOS 26.5 SDK）两个版本都编译成功。

证据：Actions 运行 Build #14（编号 40788450491）；`build-logs.zip` 中的 `xcodebuild.log` 以 `** BUILD SUCCEEDED **` 结束，`environment.log` 记录 Xcode 与 SDK 版本。

### 3. 是否产生了 IPA 或其他可供签名的构建产物？

**已完成并验证**。产出未签名 IPA，结构检查全部通过：真机平台、arm64、内嵌 llama.framework、未签名、无描述文件。能否安装取决于签名，这一步没有测试。

证据：Releases `build-14` 中的 `MoonlitTavern-unsigned.ipa` 及其 `.sha256`；`build-logs.zip` 中的 `verify-ipa.log`。

### 4. 是否可以导入角色卡？

**已完成并验证**。支持 PNG（读取 chara 与 ccv3 文本块）和 JSON，兼容 Character Card V1、V2、V3 以及 TavernAI 的字段别名；角色卡内嵌的世界书一起导入；导出时未知字段原样保留。解析与导出由单元测试验证；App 里的导入入口（系统文件选择器）没有纳入 UI 自动化测试。

证据：`MoonlitCore/CharacterCards/CharacterCardCodec.swift`、`PNGChunks.swift`；`CharacterCardTests`（9 项）与 `Tests/MoonlitCoreTests/Fixtures/` 样例文件。

### 5. 聊天记录能否在重启后保留？

**已完成并验证（模拟器）**。每个存档保存为独立 JSON 文件，原子写入。模拟器测试中先完成一轮对话，再退出并重新启动 App：用户消息与助手消息数量和重启前一致，最后一条回复的文本完全相同；随后又成功生成了一条新回复。

证据：`MoonlitCore/Persistence/TavernStore.swift`、`PersistenceTests`；模拟器测试日志 `uitest-steps.txt` 与截图「10-重启后」「11-重启后继续对话」（仓库 `ci-logs/simulator-uitest` 分支）。

### 6. 是否真正调用本地模型？

**已完成并验证**。推理通过 llama.cpp 的 C 接口完成。IPA 主程序引用了 48 个 llama.cpp 接口；引擎测试和模拟器测试都加载真实 GGUF 文件生成回复，日志里有 Metal 初始化信息、提示词 token 数、实际计算的 token 数和速度。App 里没有预设回复，示例角色的开场白属于角色卡内容，界面上标有「示例」。

证据：`MoonlitTavern/Inference/LlamaEngine.swift`；`verify-ipa.log`；`docs/evidence/engine-*.log`；模拟器截图。

### 7. 断网后能否生成 AI 回复？

**已实现但未验证**。本地模式的生成只读取本机模型文件。整个 App 里会联网的代码只在两个文件中：模型下载（用户点击时）和云端引擎（云端模式时）；本地模式选择的是 llama.cpp 引擎，不会调用它们。云端测试机必须保持联网才能和 GitHub 通信，没法在断网条件下实测。真机测试清单第 5 项用飞行模式验证。

证据：`App/AppState+Generation.swift` 中 `activeEngine()` 本地模式返回 llama 引擎；网络调用只出现在 `Inference/ModelLibrary.swift` 与 `Providers/OpenAICompatibleEngine.swift`。

### 8. 是否存在任何强制云端依赖？

**已完成并验证（不存在）**。默认本地模式，不需要账号、服务器或任何在线验证，也没有统计上报。llama.cpp 以框架形式内嵌在 IPA 中。模拟器测试全程使用本地模式。

证据：同上；`verify-ipa.log` 中的动态库依赖列表只有系统框架和内嵌的 llama.framework。

### 9. 是否完成 8K 上下文测试？

**已完成并验证（macOS 虚拟机）；真机受环境限制**。引擎测试以 8192 上下文加载 Qwen3-0.6B，7686 token 的提示词全部读入并正常生成；首发主力 Qwen3.5-4B 也以 8192 上下文完成加载和首轮生成。iPad 上的 8K 测试需要真机，App 内「真机性能测试」的长上下文测试可以完成。

证据：`docs/evidence/engine-qwen3-0.6b-ctx8192.log`（「长上下文：8192 上下文跑通」）、`docs/evidence/engine-qwen35-4b-partial.log`。

### 10. 是否完成真实 iPad 设备测试？

**受环境限制**。没有可用的 iPad 真机，也没有能连接设备的 Mac。替代验证是 iPad 模拟器端到端测试和 macOS 真实模型引擎测试。真机测试按第 10 章清单进行。

证据：本报告 8.3、8.4 节；第 10 章。

## 单元测试

`Packages/MoonlitCore` 共 71 项，在 Linux（Swift 6.0.3）和 macOS（Swift 6.4）上全部通过。日志：`docs/evidence/core-tests-linux.log`，以及每个 Release 附带的 `core-tests.log`。

| 测试组 | 数量 |
|---|---|
| 角色卡 | 9 |
| 世界书引擎 | 13 |
| 世界书格式 | 4 |
| 提示词组装与模板 | 14 |
| 对话树、流式文本、群聊调度、Markdown | 9 |
| 记忆 | 8 |
| GGUF 解析、内存估算、OpenAI 接口 | 9 |
| 持久化 | 5 |

## iOS 构建

| 构建 | 环境 | 结果 |
|---|---|---|
| Build #14 | Xcode 27.1 · Swift 6.4 · iOS 27.1 SDK · Release · iphoneos | 成功，IPA 结构检查通过 |
| Build #14 兼容构建 | Xcode 26.6 · Swift 6.3.3 · iOS 26.5 SDK | 成功，IPA 结构检查通过 |

IPA 检查（`scripts/verify-ipa.sh`）：iphoneos 平台、arm64、最低系统 17.0、仅 iPad；链接并内嵌 `llama.framework`（含 Metal 后端）；主程序引用 48 个 llama.cpp 接口；未签名、无描述文件。

## 引擎测试（真实模型，GitHub macOS 虚拟机）

`Tools/EngineHarness` 直接编译 App 的 `LlamaEngine.swift` 与核心库，链接同版本 llama.cpp 的 macOS 切片，跑 22 项检查。

| 模型 | 上下文 | 结果 | 日志 |
|---|---|---|---|
| Qwen3-0.6B Q8_0 | 8192 | 22/22 | `docs/evidence/engine-qwen3-0.6b-ctx8192.log` |
| Qwen3.5-0.8B Q4_K_M | 4096 | 22/22 | `docs/evidence/engine-qwen35-0.8b-ctx4096.log` |
| Qwen3.5-4B Q4_K_M | 8192 | 加载与首轮 5 项通过（手动停止） | `docs/evidence/engine-qwen35-4b-partial.log` |

虚拟机 GPU（Apple Paravirtual device）速度远低于真机，日志中的速度只用来确认功能正确。

## 模拟器端到端测试

iPad Pro 13 英寸（M5）模拟器，真实 App + 真实模型 Qwen3.5-0.8B Q4_K_M，上下文 2048，回复上限 48 token。运行编号 40788449971，TEST SUCCEEDED。截图在 `docs/evidence/screenshots/`。

| 步骤 | 结果 |
|---|---|
| 启动 App | 加载示例数据，聊天界面出现，示例存档含开场白 |
| 设置 › 模型管理 | 识别到测试模型并选中 |
| 输入并发送「你好，艾琳。今晚还有空房吗？」 | 出现停止按钮，进入生成状态 |
| 等待回复 | 9.5 秒后收到回复（含首次加载模型）；首 token 1.98 秒，读取 252 token/秒，生成 27.3 token/秒，进程内存 747 MB |
| 右侧五个面板、角色编辑、群聊存档、竖屏 | 全部正常显示并截图 |
| 退出 App 再启动 | 用户消息 1/1、助手消息 2/2，最后一条回复文本与重启前完全一致 |
| 发送「那就要朝钟楼的那间。」 | 9.2 秒后收到新回复（含重新加载模型）；首 token 2.52 秒，生成 50.2 token/秒 |

模拟器里 `os_proc_available_memory()` 返回 0，速度与内存只说明流程跑通。

## 没有覆盖的测试

- 真机安装、推理、速度与内存（没有 iPad 真机）
- 全能签签名安装（需要你的证书）
- 断网条件下的推理（云端测试机必须联网）
- 云端模式连接真实服务（需要 API Key）
- App 内下载模型（文件较大，未放进自动化测试）
