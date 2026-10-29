import SwiftUI
import UniformTypeIdentifiers
import UIKit
import MoonlitCore

struct Banner: Identifiable, Equatable {
    enum Kind { case info, warning, error, success }
    let id = UUID()
    var kind: Kind
    var text: String
}

enum ModelState: Equatable {
    case unloaded
    case loading(Double)
    case loaded(LoadedModelInfo)
    case failed(String)

    var isLoaded: Bool {
        if case .loaded = self { return true }
        return false
    }
}

/// 正在进行的生成（回复或摘要）。流式文本先放这里，结束后才写入聊天记录。
struct GenerationState: Equatable {
    enum Purpose { case reply, summary, benchmark }
    var chatID: UUID?
    var speakerID: UUID?
    var speakerName: String
    var purpose: Purpose
    var phase: GenerationPhase
    var progress: Double?
    var text: String = ""
    var startedAt = Date()
    var regeneratingMessageID: UUID?
}

/// 最近一次组装提示词的快照，用于右侧面板显示「上下文用量」「本轮激活的世界书」。
struct PlanSnapshot {
    var report: PromptReport
    var loreIncluded: [(title: String, book: String, reason: String, tokens: Int)]
    var loreDropped: [(title: String, reason: String)]
    var memoryIDs: [UUID]
    var promptPreview: [PromptMessage]
    var prefill: String
    var engine: String
}

@MainActor
final class AppState: ObservableObject {
    let store: TavernStore
    let models = ModelLibrary()
    let llama = LlamaEngine()

    @Published var characters: [TavernCharacter] = []
    @Published var chats: [ChatSession] = []
    @Published var lorebooks: [Lorebook] = []
    @Published var memories: [UUID: ChatMemory] = [:]
    @Published var settings: AppSettings {
        didSet { scheduleSettingsSave() }
    }

    @Published var selectedChatID: UUID?
    @Published var generation: GenerationState?
    @Published var modelState: ModelState = .unloaded
    @Published var banner: Banner?
    @Published var lastPlans: [UUID: PlanSnapshot] = [:]
    @Published var lastStats: GenerationStats?
    @Published var benchmarks: [BenchmarkResult] = []
    @Published var thermalLabel = DeviceMetrics.thermalLabel

    var generationTask: Task<Void, Never>?
    /// 正在生成剧情选项的那条回复
    @Published var suggestionJob: SuggestionJob?
    /// 备用的系统文件选择器（SwiftUI fileImporter，单选）。挂在根视图上，全 App 只有这一个
    @Published var showAlternateImporter = false
    var suggestionTask: Task<Void, Never>?
    /// 因内存不足自动降低上下文时，记录用户原本设置的值。
    var reducedContextRequest: Int?
    private var settingsSaveTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    static let appVersion: String = {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(version) (\(build))"
    }()

    init() {
        let env = ProcessInfo.processInfo.environment
        // UI 自动化测试：每轮测试使用独立的数据目录，从示例数据开始；
        // 同一轮测试里重启 App 时传入相同的 MOONLIT_UITEST_RUN，用来验证数据能保留
        let isUITest = env["MOONLIT_UITEST"] == "1"
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let testRun = env["MOONLIT_UITEST_RUN"] ?? UUID().uuidString
        let root = isUITest
            ? FileManager.default.temporaryDirectory.appendingPathComponent("MoonlitTavern-UITest-\(testRun)", isDirectory: true)
            : support.appendingPathComponent("MoonlitTavern", isDirectory: true)
        let opened: TavernStore
        do {
            opened = try TavernStore(root: root)
        } catch {
            // 沙盒目录无法创建属于系统级故障，退回临时目录保证能启动
            opened = try! TavernStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("MoonlitTavern"))
        }
        let firstLaunch = opened.isFirstLaunch
        store = opened
        var loadedSettings = opened.loadSettings()
        if isUITest {
            if let ctx = env["MOONLIT_CONTEXT"].flatMap(Int.init) { loadedSettings.local.contextLength = ctx }
            if let n = env["MOONLIT_MAX_TOKENS"].flatMap(Int.init) {
                loadedSettings.replyLength = .custom
                loadedSettings.sampling.maxNewTokens = n
            }
        }
        settings = loadedSettings
        characters = store.loadCharacters()
        chats = store.loadChats()
        lorebooks = store.loadLorebooks()
        benchmarks = BenchmarkResult.load(from: store.root)
        if firstLaunch { installSampleData() }
        Self.ensureCardFolder()
        if isUITest { Self.writeUITestCards() }
        if !store.loadIssues.isEmpty {
            banner = Banner(kind: .warning, text: "有 \(store.loadIssues.count) 个数据文件无法读取，已跳过。")
        }
        selectedChatID = chats.first?.id
        observeSystemEvents()
        Task { await models.refresh() }
    }

    // MARK: - 系统事件

    private func observeSystemEvents() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleMemoryWarning() }
        })
        observers.append(center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.thermalLabel = DeviceMetrics.thermalLabel
                if DeviceMetrics.isThermallyStressed {
                    self.show(.warning, "设备温度\(DeviceMetrics.thermalLabel)，系统可能降频，生成速度会变慢。")
                }
            }
        })
    }

    func handleMemoryWarning() {
        EngineLog.shared.append("收到系统内存警告，进程内存 \(Int(DeviceMetrics.footprintMB() ?? -1)) MB")
        cancelSuggestions()
        if generation != nil {
            stopGeneration()
            show(.warning, "系统内存紧张，已停止本次生成。")
        } else if modelState.isLoaded {
            Task {
                await llama.unload()
                modelState = .unloaded
                show(.warning, "系统内存紧张，已卸载本地模型。下次发送消息时会自动重新加载。")
            }
        }
    }

    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .background:
            // iPadOS 不允许后台提交 GPU 任务，必须先停下推理
            if generation != nil {
                let app = UIApplication.shared
                let taskID = app.beginBackgroundTask(withName: "stop-generation", expirationHandler: nil)
                stopGeneration()
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    app.endBackgroundTask(taskID)
                }
            }
            if settings.local.unloadOnBackground, modelState.isLoaded {
                Task {
                    await llama.unload()
                    modelState = .unloaded
                }
            }
            flushSettings()
        default:
            break
        }
    }

    // MARK: - 提示

    func show(_ kind: Banner.Kind, _ text: String) {
        banner = Banner(kind: kind, text: text)
    }

    // MARK: - 设置

    private func scheduleSettingsSave() {
        settingsSaveTask?.cancel()
        settingsSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            self?.flushSettings()
        }
    }

    func flushSettings() {
        do {
            try store.save(settings)
        } catch {
            show(.error, "设置保存失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 示例数据

    /// UI 自动化测试：在「角色卡」文件夹里放两张测试卡，一张从 App 内的文件夹列表导入，一张走系统文件选择器。
    private static func writeUITestCards() {
        ensureCardFolder()
        for (file, name) in [("uitest-card.json", "测试旅者"), ("uitest-picker.json", "选择器旅者"), ("uitest-alt.json", "备用旅者")] {
            let card: [String: Any] = [
                "spec": "chara_card_v2",
                "spec_version": "2.0",
                "data": [
                    "name": name,
                    "description": "用于自动化测试的角色。",
                    "personality": "安静",
                    "scenario": "",
                    "first_mes": "你好。",
                    "mes_example": "",
                    "tags": ["测试"],
                ] as [String: Any],
            ]
            if let data = try? JSONSerialization.data(withJSONObject: card, options: [.prettyPrinted]) {
                try? data.write(to: cardFolderURL.appendingPathComponent(file), options: .atomic)
            }
        }
    }

    private func installSampleData() {
        let book = SampleData.lorebook
        lorebooks = [book]
        try? store.save(book)
        for c in SampleData.characters {
            try? store.save(c)
        }
        characters = SampleData.characters
        // 一个单人存档 + 一个群聊存档，都标为示例
        var single = makeChat(characterIDs: [SampleData.erinID], title: "示例 · 深夜来客")
        single.lorebookIDs = [book.id]
        single.isSample = true
        var group = makeChat(characterIDs: [SampleData.erinID, SampleData.lyonID], title: "示例 · 满月前夜（群聊）")
        group.lorebookIDs = [book.id]
        group.plotState = ["月相": "满月"]
        group.isSample = true
        chats = [single, group]
        try? store.save(single)
        try? store.save(group)
        flushSettings()
    }

    // MARK: - 查询

    func character(_ id: UUID?) -> TavernCharacter? {
        guard let id else { return nil }
        return characters.first { $0.id == id }
    }

    func chat(_ id: UUID?) -> ChatSession? {
        guard let id else { return nil }
        return chats.first { $0.id == id }
    }

    var selectedChat: ChatSession? { chat(selectedChatID) }

    func participants(of chat: ChatSession) -> [TavernCharacter] {
        chat.characterIDs.compactMap { character($0) }
    }

    func chats(for character: TavernCharacter) -> [ChatSession] {
        chats.filter { $0.characterIDs.contains(character.id) && !$0.isGroup }
    }

    var groupChats: [ChatSession] { chats.filter(\.isGroup) }

    func avatarData(for character: TavernCharacter?) -> Data? {
        store.avatarData(character?.avatarFileName)
    }

    func persona(for chat: ChatSession) -> UserPersona {
        chat.persona ?? settings.persona
    }

    // MARK: - 角色

    func saveCharacter(_ character: TavernCharacter) {
        var c = character
        c.updatedAt = Date()
        do {
            try store.save(c)
            if let idx = characters.firstIndex(where: { $0.id == c.id }) {
                characters[idx] = c
            } else {
                characters.insert(c, at: 0)
            }
        } catch {
            show(.error, "角色保存失败：\(error.localizedDescription)")
        }
    }

    func deleteCharacter(_ character: TavernCharacter) {
        try? store.deleteCharacter(character)
        characters.removeAll { $0.id == character.id }
        // 单人存档一并删除；群聊里移除该角色
        for chat in chats where chat.characterIDs.contains(character.id) {
            if !chat.isGroup {
                deleteChat(chat.id)
            } else {
                var updated = chat
                updated.characterIDs.removeAll { $0 == character.id }
                saveChat(updated)
            }
        }
    }

    func setAvatar(_ data: Data, for characterID: UUID) {
        guard var c = character(characterID) else { return }
        // 统一转成 PNG，方便导出 PNG 角色卡
        let png = UIImage(data: data).flatMap { Self.normalizedAvatar($0) } ?? data
        do {
            let name = try store.saveAvatar(png, for: c.id, fileExtension: "png")
            store.removeAvatar(c.avatarFileName)
            c.avatarFileName = name
            saveCharacter(c)
        } catch {
            show(.error, "头像保存失败：\(error.localizedDescription)")
        }
    }

    /// 头像缩到最长边 768 像素以内并转为 PNG。
    static func normalizedAvatar(_ image: UIImage) -> Data? {
        let maxSide: CGFloat = 768
        let size = image.size
        let scale = min(1, maxSide / max(size.width, size.height))
        let target = CGSize(width: max(1, size.width * scale), height: max(1, size.height * scale))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }
        return resized.pngData()
    }

    /// 导入角色卡（PNG 或 JSON）。返回导入的角色。
    @discardableResult
    func importCharacterCard(from url: URL) -> TavernCharacter? {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let fileName = url.lastPathComponent
        let data: Data
        do {
            data = try Self.readFile(at: url)
        } catch {
            EngineLog.shared.append("读取角色卡失败：\(fileName)：\(error)")
            show(.error, "读不到文件「\(fileName)」：\(error.localizedDescription)")
            return nil
        }
        return importCharacterCard(data: data, fileName: fileName)
    }

    /// 「文件 › 我的 iPad › 月下酒馆 › 角色卡」文件夹。放进去的 PNG / JSON 可以在 App 里直接导入，不经过系统文件选择器。
    nonisolated static var cardFolderURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("角色卡", isDirectory: true)
    }

    nonisolated static func ensureCardFolder() {
        try? FileManager.default.createDirectory(at: cardFolderURL, withIntermediateDirectories: true)
    }

    /// 角色卡文件夹里的 PNG / JSON 文件，新的在前。
    func cardFolderFiles() -> [URL] {
        Self.ensureCardFolder()
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: Self.cardFolderURL, includingPropertiesForKeys: keys,
                                                                 options: [.skipsHiddenFiles])) ?? []
        return urls
            .filter { ["png", "json"].contains($0.pathExtension.lowercased()) }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a > b
            }
    }

    /// 从其他 App 交过来的文件（「文件」里长按 › 共享 › 月下酒馆），或备用选择器选中的文件。
    /// GGUF 当模型导入；JSON / PNG 先按角色卡识别，不是角色卡的 JSON 再按世界书识别。
    func importOpenedFile(_ url: URL, source: String) {
        let name = url.lastPathComponent
        EngineLog.shared.append("\(source)：\(name)")
        let ext = url.pathExtension.lowercased()
        if ext == "gguf" {
            Task { await models.importModel(from: url) }
            return
        }
        guard ext == "json" || ext == "png" else {
            show(.error, "「\(name)」不是角色卡、世界书或 GGUF 模型")
            return
        }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let data: Data
        do {
            data = try Self.readFile(at: url)
        } catch {
            EngineLog.shared.append("读取失败：\(name)：\(error)")
            show(.error, "读不到文件「\(name)」：\(error.localizedDescription)")
            return
        }
        importCardOrLorebook(data: data, fileName: name)
    }

    /// 拖进 App 的文件（iPad 分屏时从「文件」里把角色卡拖到月下酒馆）。只收 JSON 和 PNG。
    func importDropped(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers {
            let type: UTType
            if provider.hasItemConformingToTypeIdentifier(UTType.png.identifier) {
                type = .png
            } else if provider.hasItemConformingToTypeIdentifier(UTType.json.identifier) {
                type = .json
            } else {
                continue
            }
            accepted = true
            let base = provider.suggestedName ?? "拖入的角色卡"
            let name = base.lowercased().hasSuffix(".\(type.preferredFilenameExtension ?? "")") ? base : "\(base).\(type.preferredFilenameExtension ?? "json")"
            EngineLog.shared.append("拖入文件：\(name)")
            provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, error in
                let message = error.map { "\($0)" }
                Task { @MainActor in
                    if let data {
                        self.importCardOrLorebook(data: data, fileName: name)
                    } else {
                        EngineLog.shared.append("拖入文件读取失败：\(name)：\(message ?? "没有数据")")
                        self.show(.error, "读不到拖入的文件「\(name)」")
                    }
                }
            }
        }
        if !accepted { show(.error, "只能拖入角色卡（JSON / PNG）或世界书（JSON）") }
        return accepted
    }

    /// 先按角色卡识别；不是角色卡的 JSON 再按世界书识别；都不是时显示角色卡解析失败的原因。
    func importCardOrLorebook(data: Data, fileName: String) {
        if (try? CharacterCardCodec.importCard(from: data)) != nil {
            importCharacterCard(data: data, fileName: fileName)
        } else if !PNGChunks.isPNG(data),
                  (try? WorldInfoFormats.importLorebook(from: data, fallbackName: "")) != nil {
            importLorebook(data: data, fileName: fileName)
        } else {
            importCharacterCard(data: data, fileName: fileName)
        }
    }

    /// 将用户明确复制到剪贴板的 JSON 导入角色卡，绕开系统文件选择器。
    @discardableResult
    func importCharacterCard(jsonText: String) -> TavernCharacter? {
        let trimmed = jsonText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            show(.error, "剪贴板没有 JSON 文本")
            return nil
        }
        return importCharacterCard(data: Data(trimmed.utf8), fileName: "剪贴板 JSON")
    }

    @discardableResult
    func importCharacterCard(data: Data, fileName: String) -> TavernCharacter? {
        EngineLog.shared.append("导入角色卡：\(fileName)，\(data.count) 字节")
        do {
            let result = try CharacterCardCodec.importCard(from: data)
            var c = result.character
            c.id = UUID()
            if let png = result.avatarPNG {
                let avatarPNG = UIImage(data: png).flatMap { Self.normalizedAvatar($0) } ?? png
                c.avatarFileName = try store.saveAvatar(avatarPNG, for: c.id)
            }
            saveCharacter(c)
            var note = "已导入「\(c.name)」（\(result.specVersion.uppercased())）"
            if let book = c.characterBook { note += "，含世界书 \(book.entries.count) 条" }
            if !result.warnings.isEmpty { note += "。提示：" + result.warnings.joined(separator: "；") }
            show(.success, note)
            return c
        } catch {
            EngineLog.shared.append("解析角色卡失败：\(fileName)：\(error)")
            show(.error, "「\(fileName)」不是可识别的角色卡：\(error.localizedDescription)")
            return nil
        }
    }

    /// 读取用户选择的文件。经过文件协调器读取：iCloud 里还没下载到本机的文件会先下载。
    nonisolated static func readFile(at url: URL) throws -> Data {
        var coordinationError: NSError?
        var result: Result<Data, Error> = .failure(CocoaError(.fileReadUnknown))
        NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { readURL in
            result = Result(catching: { try Data(contentsOf: readURL) })
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }

    func exportCardPNG(_ character: TavernCharacter) throws -> Data {
        try CharacterCardCodec.exportPNG(character, basePNG: avatarData(for: character))
    }

    func exportCardJSON(_ character: TavernCharacter) throws -> Data {
        try CharacterCardCodec.exportJSON(character)
    }

    // MARK: - 世界书

    func saveLorebook(_ book: Lorebook) {
        do {
            try store.save(book)
            if let idx = lorebooks.firstIndex(where: { $0.id == book.id }) {
                lorebooks[idx] = book
            } else {
                lorebooks.append(book)
            }
        } catch {
            show(.error, "世界书保存失败：\(error.localizedDescription)")
        }
    }

    func deleteLorebook(_ id: UUID) {
        store.deleteLorebook(id)
        lorebooks.removeAll { $0.id == id }
        for chat in chats where chat.lorebookIDs.contains(id) {
            var updated = chat
            updated.lorebookIDs.removeAll { $0 == id }
            saveChat(updated)
        }
    }

    @discardableResult
    func importLorebook(from url: URL) -> Lorebook? {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            return importLorebook(data: try Self.readFile(at: url), fileName: url.lastPathComponent)
        } catch {
            show(.error, "世界书导入失败：\(error.localizedDescription)")
            return nil
        }
    }

    @discardableResult
    func importLorebook(data: Data, fileName: String) -> Lorebook? {
        EngineLog.shared.append("导入世界书：\(fileName)，\(data.count) 字节")
        do {
            let book: Lorebook
            if PNGChunks.isPNG(data) {
                // 从角色卡 PNG 里取世界书
                let result = try CharacterCardCodec.importCard(from: data)
                guard let embedded = result.character.characterBook else {
                    throw WorldInfoFormats.FormatError.unrecognized
                }
                book = embedded
            } else {
                book = try WorldInfoFormats.importLorebook(from: data, fallbackName: (fileName as NSString).deletingPathExtension)
            }
            var copy = book
            copy.id = UUID()
            copy.isSample = false
            saveLorebook(copy)
            show(.success, "已导入世界书「\(copy.name)」，共 \(copy.entries.count) 条")
            return copy
        } catch {
            show(.error, "世界书导入失败：\(error.localizedDescription)")
            return nil
        }
    }

    /// 本次对话会用到的全部世界书：存档关联的 + 参与角色自带的。
    func activeLorebooks(for chat: ChatSession) -> [Lorebook] {
        let linked = chat.lorebookIDs.compactMap { id in lorebooks.first { $0.id == id } }
        let embedded = participants(of: chat).compactMap(\.characterBook)
        return linked + embedded
    }

    // MARK: - 存档

    func makeChat(characterIDs: [UUID], title: String) -> ChatSession {
        var chat = ChatSession(title: title, characterIDs: characterIDs, turnOrder: .natural)
        // 开场白：单人存档用该角色的开场白；群聊用第一个角色的
        if let first = character(characterIDs.first) ?? SampleData.characters.first(where: { $0.id == characterIDs.first }),
           let greeting = first.allGreetings.first {
            let macro = MacroContext(characterName: first.name, userName: settings.persona.name)
            chat.append(ChatMessage(role: .assistant, speakerID: first.id, speakerName: first.name, content: macro.expand(greeting)))
            // 备选开场白作为第一条消息的其他版本，可左右切换
            if let rootID = chat.activeLeafID {
                for alt in first.allGreetings.dropFirst() {
                    chat.addSibling(ChatMessage(role: .assistant, speakerID: first.id, speakerName: first.name, content: macro.expand(alt)), siblingOf: rootID)
                }
                if first.allGreetings.count > 1 { chat.activeLeafID = rootID }
            }
        }
        return chat
    }

    @discardableResult
    func newChat(characterIDs: [UUID], title: String? = nil) -> ChatSession {
        let names = characterIDs.compactMap { character($0)?.name }
        let dateText = Date().formatted(date: .abbreviated, time: .shortened)
        var chat = makeChat(characterIDs: characterIDs, title: title ?? (names.count > 1 ? names.joined(separator: "、") : "\(names.first ?? "新存档") · \(dateText)"))
        // 带上已有世界书中与示例相关的：示例角色默认关联示例世界书
        if characterIDs.contains(where: { character($0)?.isSample == true }), lorebooks.contains(where: { $0.id == SampleData.lorebookID }) {
            chat.lorebookIDs = [SampleData.lorebookID]
        }
        saveChat(chat)
        selectedChatID = chat.id
        return chat
    }

    func saveChat(_ chat: ChatSession) {
        do {
            try store.save(chat)
            if let idx = chats.firstIndex(where: { $0.id == chat.id }) {
                chats[idx] = chat
            } else {
                chats.insert(chat, at: 0)
            }
        } catch {
            show(.error, "存档保存失败：\(error.localizedDescription)")
        }
    }

    func updateChat(_ id: UUID, _ change: (inout ChatSession) -> Void) {
        guard var chat = chat(id) else { return }
        change(&chat)
        chat.updatedAt = Date()
        saveChat(chat)
    }

    func deleteChat(_ id: UUID) {
        store.deleteChat(id)
        chats.removeAll { $0.id == id }
        memories[id] = nil
        lastPlans[id] = nil
        if selectedChatID == id { selectedChatID = chats.first?.id }
    }

    func forkChat(_ chatID: UUID, at messageID: UUID) {
        guard let chat = chat(chatID), let fork = chat.forked(at: messageID, title: chat.title + " · 分支") else { return }
        saveChat(fork)
        // 记忆也复制一份，分支从同一份记忆出发
        var memory = self.memory(for: chatID)
        memory.chatID = fork.id
        saveMemory(memory)
        selectedChatID = fork.id
        show(.success, "已从这条消息分出新存档")
    }

    // MARK: - 记忆

    func memory(for chatID: UUID) -> ChatMemory {
        if let cached = memories[chatID] { return cached }
        let loaded = store.loadMemory(chatID: chatID)
        memories[chatID] = loaded
        return loaded
    }

    func saveMemory(_ memory: ChatMemory) {
        memories[memory.chatID] = memory
        do {
            try store.save(memory)
        } catch {
            show(.error, "记忆保存失败：\(error.localizedDescription)")
        }
    }

    func updateMemory(_ chatID: UUID, _ change: (inout ChatMemory) -> Void) {
        var memory = memory(for: chatID)
        change(&memory)
        saveMemory(memory)
    }

    // MARK: - 备份

    func makeBackup() throws -> Data {
        flushSettings()
        return try store.makeBackup(appVersion: Self.appVersion)
    }

    func restoreBackup(from url: URL, includeSettings: Bool) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Self.readFile(at: url)
            let summary = try store.restore(from: data, includeSettings: includeSettings)
            characters = store.loadCharacters()
            chats = store.loadChats()
            lorebooks = store.loadLorebooks()
            memories = [:]
            if summary.settingsRestored { settings = store.loadSettings() }
            show(.success, "已恢复：角色 \(summary.characters) 个，存档 \(summary.chats) 个，世界书 \(summary.lorebooks) 本，记忆 \(summary.memories) 份")
        } catch {
            show(.error, "恢复失败：\(error.localizedDescription)")
        }
    }
}
