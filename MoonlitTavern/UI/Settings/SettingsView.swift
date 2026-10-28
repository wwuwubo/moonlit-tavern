import SwiftUI
import UniformTypeIdentifiers
import MoonlitCore

struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("推理方式", selection: $state.settings.providerMode) {
                        Text("本地模型（离线）").tag(ProviderMode.local)
                        Text("云端 API").tag(ProviderMode.cloud)
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text(state.settings.providerMode == .local
                         ? "本地模式下，所有推理都在这台 iPad 上完成，聊天内容不会离开设备。"
                         : "云端模式会把提示词（含聊天记录）发送到你配置的服务。角色卡和聊天记录仍只保存在本机。")
                }

                Section("本地模型") {
                    NavigationLink { ModelManagerView() } label: {
                        Label("模型管理", systemImage: "cpu")
                    }
                    .accessibilityIdentifier("modelManagerLink")
                    NavigationLink { InferenceSettingsView() } label: {
                        Label("推理参数（上下文、KV 缓存、模板）", systemImage: "slider.horizontal.3")
                    }
                    NavigationLink { BenchmarkView() } label: {
                        Label("真机性能测试", systemImage: "speedometer")
                    }
                }

                Section("云端") {
                    NavigationLink { CloudSettingsView() } label: {
                        Label("OpenAI 兼容 API", systemImage: "cloud")
                    }
                }

                Section("角色扮演") {
                    NavigationLink { PersonaSettingsView() } label: {
                        Label("我的身份与系统提示词", systemImage: "person.text.rectangle")
                    }
                    NavigationLink { LorebookListView() } label: {
                        Label("世界书", systemImage: "book.closed")
                    }
                }

                Section("数据") {
                    NavigationLink { BackupView() } label: {
                        Label("备份与恢复", systemImage: "externaldrive")
                    }
                    NavigationLink { DiagnosticsView() } label: {
                        Label("诊断日志", systemImage: "list.bullet.rectangle")
                    }
                    NavigationLink { AboutView() } label: {
                        Label("关于与开源许可", systemImage: "info.circle")
                    }
                }
            }
            .navigationTitle("设置")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        state.flushSettings()
                        dismiss()
                    }
                    .accessibilityIdentifier("settingsDone")
                }
            }
        }
    }
}

// MARK: - 模型管理

struct ModelManagerView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var library: ModelLibrary
    @State private var showImporter = false
    @State private var customURL = ""
    @State private var pendingDelete: LocalModelFile?

    var body: some View {
        List {
            Section {
                LoadedModelCard()
            }

            Section {
                if library.models.isEmpty {
                    Text("还没有模型。可以从下方下载，或者点右上角从「文件」导入 .gguf。")
                        .font(.callout)
                        .foregroundStyle(Theme.textSecondary)
                }
                ForEach(library.models) { model in
                    ModelRow(model: model, selected: state.settings.local.selectedModelFile == model.fileName)
                        .contentShape(Rectangle())
                        .onTapGesture { state.selectModel(model) }
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityIdentifier("model-row")
                        .swipeActions {
                            Button(role: .destructive) { pendingDelete = model } label: { Label("删除", systemImage: "trash") }
                        }
                }
                if let name = library.importingName {
                    VStack(alignment: .leading) {
                        Text("正在导入 \(name)").font(.caption)
                        ProgressView(value: library.importProgress ?? 0)
                    }
                }
            } header: {
                Text("已有模型")
            } footer: {
                Text("模型保存在「文件 › 我的 iPad › 月下酒馆 › Models」，也可以直接把 .gguf 拷进这个文件夹，然后下拉刷新。该目录不参与 iCloud 备份。")
            }

            Section {
                ForEach(ModelPreset.all) { preset in
                    PresetRow(preset: preset)
                }
                VStack(alignment: .leading, spacing: 8) {
                    TextField("其他 GGUF 直链（https://…/xxx.gguf）", text: $customURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("下载") {
                        guard let url = URL(string: customURL.trimmed), url.scheme == "https" else {
                            state.show(.warning, "请输入以 https 开头的直链")
                            return
                        }
                        library.download(from: url, fileName: url.lastPathComponent)
                        customURL = ""
                    }
                    .disabled(customURL.isBlank)
                }
            } header: {
                Text("下载推荐模型")
            } footer: {
                Text("Hugging Face 在国内通常无法直连，可选 hf-mirror.com 镜像（第三方服务）。也可以在电脑或其他设备下载后通过「文件」导入。下载期间请保持 App 在前台。")
            }
        }
        .navigationTitle("模型管理")
        .refreshable { await library.refresh() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showImporter = true } label: { Label("导入", systemImage: "square.and.arrow.down") }
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.gguf, .data]) { result in
            if case .success(let url) = result {
                Task { await library.importModel(from: url) }
            }
        }
        .task { await library.refresh() }
        .onChange(of: library.lastError) { _, error in
            if let error { state.show(.error, error); library.lastError = nil }
        }
        .confirmationDialog("删除 \(pendingDelete?.fileName ?? "")？",
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible) {
            Button("删除模型文件", role: .destructive) {
                if let model = pendingDelete {
                    Task {
                        if state.settings.local.selectedModelFile == model.fileName {
                            await state.unloadModel()
                            state.settings.local.selectedModelFile = nil
                        }
                        await library.delete(model)
                    }
                }
                pendingDelete = nil
            }
        }
    }
}

struct LoadedModelCard: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch state.modelState {
            case .loaded(let info):
                Label("已加载 \(info.fileName)", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(Theme.success)
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    GridRow { Text("模型").foregroundStyle(Theme.textTertiary); Text(info.description) }
                    GridRow { Text("参数量").foregroundStyle(Theme.textTertiary); Text(String(format: "%.2f B", Double(info.parameterCount) / 1e9)) }
                    GridRow { Text("上下文").foregroundStyle(Theme.textTertiary); Text("\(info.contextLength)（训练 \(info.trainContext)）") }
                    GridRow { Text("模板").foregroundStyle(Theme.textTertiary); Text(info.resolvedFormat.label + (info.supportsThinking ? " · 支持思考模式" : "")) }
                    GridRow { Text("GPU").foregroundStyle(Theme.textTertiary); Text(info.gpuOffload ? "Metal 加速" : "仅 CPU") }
                    GridRow { Text("加载耗时").foregroundStyle(Theme.textTertiary); Text(String(format: "%.1f 秒", info.loadSeconds)) }
                    GridRow {
                        Text("进程内存").foregroundStyle(Theme.textTertiary)
                        Text(info.footprintAfterLoadMB.map { String(format: "%.0f MB（实测）", $0) } ?? "未知")
                    }
                }
                .font(.caption)
                Button("卸载模型") { Task { await state.unloadModel() } }
                    .buttonStyle(.bordered)
            case .loading(let p):
                Text("正在加载…").font(.subheadline)
                ProgressView(value: p)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.danger).font(.caption)
                loadButtons
            case .unloaded:
                Text("未加载。发送消息时会自动加载所选模型。").font(.caption).foregroundStyle(Theme.textSecondary)
                loadButtons
            }
            HStack(spacing: 12) {
                Text(String(format: "系统允许本应用再使用约 %.0f MB", DeviceMetrics.availableMemoryMB()))
                Text(String(format: "物理内存 %.0f GB", DeviceMetrics.physicalMemoryMB / 1024))
            }
            .font(.caption2)
            .foregroundStyle(Theme.textTertiary)
        }
        .padding(.vertical, 4)
    }

    private var loadButtons: some View {
        HStack {
            Button("加载所选模型") { Task { await state.loadModel() } }
                .buttonStyle(.borderedProminent)
                .disabled(state.settings.local.selectedModelFile == nil)
            Button("忽略内存估算强制加载") { Task { await state.loadModel(force: true) } }
                .buttonStyle(.bordered)
                .font(.caption)
                .disabled(state.settings.local.selectedModelFile == nil)
        }
    }
}

private struct ModelRow: View {
    @EnvironmentObject private var state: AppState
    let model: LocalModelFile
    let selected: Bool

    var body: some View {
        let ctx = state.settings.local.contextLength
        let estimate = model.estimate(contextLength: ctx, cacheType: state.settings.local.kvCacheType)
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(selected ? Theme.amber : Theme.textTertiary)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.fileName).font(.subheadline.weight(.medium))
                if let error = model.metadataError {
                    Text("无法读取元数据：\(error)").font(.caption).foregroundStyle(Theme.danger)
                } else {
                    Text([model.architecture ?? "?", model.quantization, model.sizeLabel, model.chatTemplateFormat.label]
                        .joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                    if let shape = model.shapeDescription {
                        Text(shape).font(.caption2).foregroundStyle(Theme.textTertiary)
                    }
                    Text(String(format: "理论估算 %ld 上下文：约 %.1f GB（权重 %.1f + KV %.2f + 计算 %.2f + 应用 %.2f）",
                                ctx, estimate.totalMB / 1024, estimate.weightsMB / 1024, estimate.kvCacheMB / 1024,
                                estimate.computeMB / 1024, estimate.overheadMB / 1024))
                        .font(.caption2)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct PresetRow: View {
    @EnvironmentObject private var library: ModelLibrary
    let preset: ModelPreset

    var body: some View {
        let state = library.downloads[preset.fileName]
        let installed = library.models.contains { $0.fileName == preset.fileName }
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(preset.title).font(.subheadline.weight(.medium))
                Spacer()
                Text(preset.approxSize).font(.caption).foregroundStyle(Theme.textSecondary)
            }
            Text(preset.note).font(.caption).foregroundStyle(Theme.textSecondary)
            Text("\(preset.repo) · \(preset.license)").font(.caption2).foregroundStyle(Theme.textTertiary)
            if installed {
                Label("已下载", systemImage: "checkmark.circle").font(.caption).foregroundStyle(Theme.success)
            } else if let s = state, !s.finished, s.error == nil {
                HStack {
                    ProgressView(value: s.fraction ?? 0)
                    Text(ByteCountFormatter.string(fromByteCount: s.received, countStyle: .file)).font(.caption2.monospacedDigit())
                    Button("取消") { library.cancelDownload(preset.fileName) }.font(.caption)
                }
            } else {
                if let error = state?.error {
                    Text("下载失败：\(error)").font(.caption).foregroundStyle(Theme.danger)
                }
                HStack {
                    Button("从 hf-mirror 下载") { library.download(from: preset.mirrorURL, fileName: preset.fileName) }
                        .buttonStyle(.borderedProminent)
                    Button("从 Hugging Face 下载") { library.download(from: preset.huggingFaceURL, fileName: preset.fileName) }
                        .buttonStyle(.bordered)
                    Link("模型页面", destination: preset.pageURL).font(.caption)
                }
                .font(.caption)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - 推理参数

struct InferenceSettingsView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Form {
            Section {
                Picker("上下文长度", selection: $state.settings.local.contextLength) {
                    ForEach([2048, 3072, 4096, 6144, 8192, 12288, 16384], id: \.self) { Text("\($0)").tag($0) }
                }
                Picker("KV 缓存精度", selection: $state.settings.local.kvCacheType) {
                    Text("Q8_0（省一半内存）").tag(KVCacheType.q8_0)
                    Text("F16（最高精度）").tag(KVCacheType.f16)
                }
                Toggle("Flash Attention", isOn: $state.settings.local.flashAttention)
            } header: {
                Text("上下文与内存")
            } footer: {
                Text("8GB 内存的 iPad 上，系统通常只允许单个应用使用其中一部分。上下文越长，KV 缓存越大；放不下时会自动降到能放下的长度并提示。Q8_0 KV 缓存需要开启 Flash Attention。")
            }

            Section("提示词模板") {
                Picker("模板", selection: $state.settings.local.promptFormat) {
                    ForEach(PromptFormat.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Toggle("关闭思考模式（Qwen3 / Qwen3.5 等）", isOn: $state.settings.local.disableThinking)
            }

            Section {
                Stepper(state.settings.local.gpuLayers < 0 ? "GPU 层数：全部" : "GPU 层数：\(state.settings.local.gpuLayers)",
                        value: $state.settings.local.gpuLayers, in: -1...200)
                Stepper(state.settings.local.threads == 0 ? "CPU 线程：自动" : "CPU 线程：\(state.settings.local.threads)",
                        value: $state.settings.local.threads, in: 0...10)
                Picker("批大小", selection: $state.settings.local.batchSize) {
                    ForEach([128, 256, 512, 1024], id: \.self) { Text("\($0)").tag($0) }
                }
                Toggle("切到后台时卸载模型", isOn: $state.settings.local.unloadOnBackground)
            } header: {
                Text("高级")
            } footer: {
                Text("参数改动会在下次生成时自动重新加载模型。")
            }
        }
        .navigationTitle("推理参数")
    }
}

// MARK: - 云端

struct CloudSettingsView: View {
    @EnvironmentObject private var state: AppState
    @State private var keyInput = ""
    @State private var masked = KeychainStore.maskedKey()

    var body: some View {
        Form {
            Section {
                TextField("API 地址", text: $state.settings.cloud.baseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                TextField("模型名，例如 deepseek/deepseek-chat", text: $state.settings.cloud.model)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Stepper("超时 \(Int(state.settings.cloud.timeoutSeconds)) 秒", value: $state.settings.cloud.timeoutSeconds, in: 30...600, step: 30)
            } header: {
                Text("服务")
            } footer: {
                Text("兼容 OpenAI Chat Completions 接口即可，例如 OpenRouter：https://openrouter.ai/api/v1")
            }

            Section {
                if let masked {
                    HStack {
                        Text("已保存：\(masked)")
                        Spacer()
                        Button("删除", role: .destructive) {
                            KeychainStore.deleteAPIKey()
                            self.masked = nil
                        }
                    }
                }
                SecureField("粘贴 API Key", text: $keyInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("保存到钥匙串") {
                    if KeychainStore.saveAPIKey(keyInput) {
                        keyInput = ""
                        masked = KeychainStore.maskedKey()
                        state.show(.success, "API Key 已保存到钥匙串")
                    } else {
                        state.show(.error, "保存失败")
                    }
                }
                .disabled(keyInput.isBlank)
            } header: {
                Text("API Key")
            } footer: {
                Text("API Key 只保存在本机钥匙串中，不会写入备份文件和诊断日志。")
            }

            Section {
                Toggle("使用云端模式", isOn: Binding(
                    get: { state.settings.providerMode == .cloud },
                    set: { state.settings.providerMode = $0 ? .cloud : .local }
                ))
            } footer: {
                Text("关闭后立即回到本地模式，不再向任何服务器发送聊天内容。")
            }
        }
        .navigationTitle("云端 API")
    }
}

// MARK: - 身份与系统提示词

struct PersonaSettingsView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Form {
            Section("默认身份（可在每个存档里单独修改）") {
                TextField("名字", text: $state.settings.persona.name)
                TextField("身份描述", text: $state.settings.persona.description, axis: .vertical)
                    .lineLimit(3...8)
            }
            Section {
                TextEditor(text: $state.settings.defaultSystemPrompt)
                    .frame(minHeight: 220)
                Button("恢复内置提示词") { state.settings.defaultSystemPrompt = AppSettings.builtinSystemPrompt }
            } header: {
                Text("全局系统提示词")
            } footer: {
                Text("{{char}} 会被替换为角色名，{{user}} 替换为你的名字。角色卡自带系统提示词时优先使用角色卡的。")
            }
        }
        .navigationTitle("身份与提示词")
    }
}

// MARK: - 备份

struct BackupView: View {
    @EnvironmentObject private var state: AppState
    @State private var pendingExport: PendingExport?
    @State private var showImporter = false
    @State private var includeSettings = true

    var body: some View {
        Form {
            Section {
                Button {
                    do {
                        let data = try state.makeBackup()
                        let stamp = Date().formatted(.iso8601.year().month().day())
                        pendingExport = PendingExport(document: ExportDocument(data: data), contentType: .json, fileName: "月下酒馆备份-\(stamp).json")
                    } catch {
                        state.show(.error, "备份失败：\(error.localizedDescription)")
                    }
                } label: { Label("导出完整备份", systemImage: "square.and.arrow.up") }
            } footer: {
                Text("包含角色、头像、存档、世界书、长期记忆和设置。不包含模型文件和 API Key。")
            }
            Section {
                Toggle("同时恢复设置", isOn: $includeSettings)
                Button { showImporter = true } label: { Label("从备份恢复", systemImage: "square.and.arrow.down") }
            } footer: {
                Text("按 id 覆盖同一条数据，备份里没有的现有数据会保留。")
            }
        }
        .navigationTitle("备份与恢复")
        .exporter($pendingExport) { result in
            switch result {
            case .success: state.show(.success, "备份已保存")
            case .failure(let error): state.show(.error, "备份保存失败：\(error.localizedDescription)")
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json, .data]) { result in
            if case .success(let url) = result { state.restoreBackup(from: url, includeSettings: includeSettings) }
        }
    }
}

// MARK: - 诊断

struct DiagnosticsView: View {
    @State private var lines: [String] = EngineLog.shared.snapshot()

    var body: some View {
        List {
            Section {
                LabeledContent("推理库", value: LlamaAvailability.detail)
                LabeledContent("设备", value: AppState.deviceModelIdentifier())
                LabeledContent("系统", value: "iPadOS " + AppState.systemVersionString())
                LabeledContent("物理内存", value: String(format: "%.1f GB", DeviceMetrics.physicalMemoryMB / 1024))
                LabeledContent("应用可用内存", value: String(format: "%.0f MB", DeviceMetrics.availableMemoryMB()))
                LabeledContent("进程内存", value: DeviceMetrics.footprintMB().map { String(format: "%.0f MB", $0) } ?? "未知")
                LabeledContent("温度状态", value: DeviceMetrics.thermalLabel)
                LabeledContent("应用版本", value: AppState.appVersion)
            }
            Section("引擎日志（不含聊天内容与密钥）") {
                ForEach(Array(lines.enumerated().reversed()), id: \.offset) { _, line in
                    Text(line).font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                }
            }
        }
        .navigationTitle("诊断")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { lines = EngineLog.shared.snapshot() } label: { Image(systemName: "arrow.clockwise") }
                Button { UIPasteboard.general.string = lines.joined(separator: "\n") } label: { Image(systemName: "doc.on.doc") }
            }
        }
    }
}

struct AboutView: View {
    var body: some View {
        List {
            Section {
                LabeledContent("应用", value: "月下酒馆 Moonlit Tavern")
                LabeledContent("版本", value: AppState.appVersion)
                LabeledContent("推理库", value: LlamaAvailability.detail)
            }
            Section("第三方组件") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("llama.cpp / ggml").font(.subheadline.weight(.medium))
                    Text("MIT License · Copyright (c) 2023-2026 The ggml authors").font(.caption).foregroundStyle(Theme.textSecondary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("模型文件").font(.subheadline.weight(.medium))
                    Text("模型不随应用分发，由用户自行下载。推荐的 Qwen3.5 / Qwen3 系列模型采用 Apache-2.0 许可，使用时请遵守各自许可证。")
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                }
            }
            Section("兼容格式") {
                Text("角色卡：Character Card V1 / V2 / V3（JSON、PNG）\n世界书：SillyTavern World Info、V2 character_book")
                    .font(.caption)
            }
        }
        .navigationTitle("关于")
    }
}
