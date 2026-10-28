# 月下酒馆 Moonlit Tavern

在 iPad 上离线运行大语言模型的私人角色扮演酒馆。SwiftUI 原生应用，本地推理基于 llama.cpp（Metal GPU 加速），兼容 SillyTavern 的角色卡与世界书。

## 能做什么

- **本地推理**：加载 GGUF 模型，流式输出，可随时停止；全程离线，聊天内容不离开设备
- **角色卡**：新建、编辑、删除；导入导出 Character Card V1 / V2 / V3（JSON 与 PNG），保留未知字段
- **对话**：重新生成（保留旧版本，左右切换）、编辑、删除、隐藏消息、从任意消息分出新存档、多存档
- **世界书**：关键词 / 次要关键词逻辑 / 正则 / 常驻 / 递归 / 互斥组 / 粘滞与冷却 / 延迟 / 剧情状态条件 / 角色过滤 / token 预算
- **长期记忆**：旧消息掉出上下文后自动摘要成「摘要 + 事件 + 关系 + 剧情状态」，按关键词检索注入，可查看、编辑、删除
- **群聊**：多角色同场，发言顺序可选，提示词层面做身份隔离并用停止词防止串台
- **云端（可选）**：OpenAI Chat Completions 兼容接口，API Key 存钥匙串；本地模式下不会联网发送聊天内容
- **真机测试工具**：测速、长上下文测试，结果可复制成 Markdown 表格

## 目录

```
MoonlitTavern/            iOS App（SwiftUI）
  App/                    入口与应用状态（生成流程、模型加载、生命周期）
  UI/                     界面：侧栏、聊天、右侧面板、编辑器、设置
  Inference/              llama.cpp 引擎、模型库、设备内存读数
  Providers/              OpenAI 兼容云端引擎
  Security/               钥匙串
  Resources/              图标、Info.plist（由 XcodeGen 生成）
Packages/MoonlitCore/     平台无关的核心逻辑（可在 Linux / macOS 上测试）
  Sources/MoonlitCore/    角色卡、世界书、提示词组装、记忆、流式文本、GGUF 解析、持久化
  Tests/                  单元测试
scripts/                  下载 llama.cpp、构建、打包 IPA、检查 IPA 结构
.github/workflows/        GitHub Actions：测试、构建、发布
project.yml               XcodeGen 工程描述
```

## 构建

只有 iPad、没有 Mac 也能构建：推送到 `main` 分支后，GitHub Actions 会在 macOS 机器上

1. 运行 `MoonlitCore` 单元测试
2. 下载并校验 llama.cpp 官方 XCFramework（`b11960`）
3. 用 XcodeGen 生成工程，`xcodebuild` 构建 iphoneos Release 版本（不签名）
4. 打包未签名 IPA 并检查结构
5. 发布到本仓库的 Releases 页面（预发布）

在有 Mac 的环境本地构建：

```bash
brew install xcodegen
scripts/fetch-llama.sh
xcodegen generate
scripts/build-ios.sh && scripts/package-ipa.sh && scripts/verify-ipa.sh
```

## 安装

Releases 里的 `MoonlitTavern-unsigned.ipa` **没有签名**，需要用全能签等工具配合你自己的证书和描述文件签名后安装。详见 `docs/` 中的安装指南。

## 许可

第三方组件见 [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md)。
