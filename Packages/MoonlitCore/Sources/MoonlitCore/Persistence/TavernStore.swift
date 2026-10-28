import Foundation

/// 本地数据存储。每个实体一个 JSON 文件，原子写入；单个文件损坏不影响其他数据。
///
/// 目录结构（位于应用沙盒的 Application Support/MoonlitTavern/）：
///   characters/<id>.json
///   avatars/<文件名>
///   chats/<id>.json
///   lorebooks/<id>.json
///   memories/<chatID>.json
///   settings.json
public final class TavernStore: @unchecked Sendable {
    public let root: URL
    private let fm = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// 读取时遇到的损坏文件，界面上会提示。
    public private(set) var loadIssues: [String] = []

    public init(root: URL) throws {
        self.root = root
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // 日期用默认的高精度数值格式：同一秒内生成的多个版本也能正确排序
        decoder = JSONDecoder()
        for dir in ["characters", "avatars", "chats", "lorebooks", "memories"] {
            try fm.createDirectory(at: root.appendingPathComponent(dir, isDirectory: true), withIntermediateDirectories: true)
        }
    }

    // MARK: - 通用

    private func url(_ dir: String, _ id: UUID) -> URL {
        root.appendingPathComponent(dir, isDirectory: true).appendingPathComponent(id.uuidString + ".json")
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try encoder.encode(value)
        try data.write(to: url, options: [.atomic])
    }

    private func loadAll<T: Decodable>(_ dir: String, as type: T.Type) -> [T] {
        let folder = root.appendingPathComponent(dir, isDirectory: true)
        guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return [] }
        var items: [T] = []
        for file in files where file.pathExtension == "json" {
            do {
                let data = try Data(contentsOf: file)
                items.append(try decoder.decode(T.self, from: data))
            } catch {
                loadIssues.append("\(dir)/\(file.lastPathComponent) 读取失败：\(error.localizedDescription)")
            }
        }
        return items
    }

    // MARK: - 角色

    public func loadCharacters() -> [TavernCharacter] {
        loadAll("characters", as: TavernCharacter.self).sorted { $0.updatedAt > $1.updatedAt }
    }

    public func save(_ character: TavernCharacter) throws {
        try write(character, to: url("characters", character.id))
    }

    public func deleteCharacter(_ character: TavernCharacter) throws {
        try? fm.removeItem(at: url("characters", character.id))
        if let avatar = character.avatarFileName {
            try? fm.removeItem(at: avatarURL(avatar))
        }
    }

    // MARK: - 头像

    public func avatarURL(_ fileName: String) -> URL {
        root.appendingPathComponent("avatars", isDirectory: true).appendingPathComponent(fileName)
    }

    /// 保存头像并返回文件名。
    public func saveAvatar(_ data: Data, for characterID: UUID, fileExtension: String = "png") throws -> String {
        let name = "\(characterID.uuidString)-\(Int(Date().timeIntervalSince1970)).\(fileExtension)"
        try data.write(to: avatarURL(name), options: [.atomic])
        return name
    }

    public func avatarData(_ fileName: String?) -> Data? {
        guard let fileName else { return nil }
        return try? Data(contentsOf: avatarURL(fileName))
    }

    public func removeAvatar(_ fileName: String?) {
        guard let fileName else { return }
        try? fm.removeItem(at: avatarURL(fileName))
    }

    // MARK: - 聊天

    public func loadChats() -> [ChatSession] {
        loadAll("chats", as: ChatSession.self).sorted { $0.updatedAt > $1.updatedAt }
    }

    public func save(_ chat: ChatSession) throws {
        try write(chat, to: url("chats", chat.id))
    }

    public func deleteChat(_ id: UUID) {
        try? fm.removeItem(at: url("chats", id))
        try? fm.removeItem(at: url("memories", id))
    }

    // MARK: - 世界书

    public func loadLorebooks() -> [Lorebook] {
        loadAll("lorebooks", as: Lorebook.self).sorted { $0.name < $1.name }
    }

    public func save(_ lorebook: Lorebook) throws {
        try write(lorebook, to: url("lorebooks", lorebook.id))
    }

    public func deleteLorebook(_ id: UUID) {
        try? fm.removeItem(at: url("lorebooks", id))
    }

    // MARK: - 记忆

    public func loadMemory(chatID: UUID) -> ChatMemory {
        let file = url("memories", chatID)
        guard let data = try? Data(contentsOf: file) else { return ChatMemory(chatID: chatID) }
        do {
            return try decoder.decode(ChatMemory.self, from: data)
        } catch {
            loadIssues.append("memories/\(chatID.uuidString).json 读取失败：\(error.localizedDescription)")
            return ChatMemory(chatID: chatID)
        }
    }

    public func loadAllMemories() -> [ChatMemory] {
        loadAll("memories", as: ChatMemory.self)
    }

    public func save(_ memory: ChatMemory) throws {
        try write(memory, to: url("memories", memory.chatID))
    }

    // MARK: - 设置

    private var settingsURL: URL { root.appendingPathComponent("settings.json") }

    public func loadSettings() -> AppSettings {
        guard let data = try? Data(contentsOf: settingsURL) else { return AppSettings() }
        return (try? decoder.decode(AppSettings.self, from: data)) ?? AppSettings()
    }

    public func save(_ settings: AppSettings) throws {
        try write(settings, to: settingsURL)
    }

    /// 是否是全新安装（没有任何角色和设置文件）。
    public var isFirstLaunch: Bool {
        !fm.fileExists(atPath: settingsURL.path) && loadCharacters().isEmpty
    }

    // MARK: - 备份

    public func makeBackup(appVersion: String) throws -> Data {
        var avatars: [String: Data] = [:]
        let characters = loadCharacters()
        for c in characters {
            if let name = c.avatarFileName, let data = avatarData(name) { avatars[name] = data }
        }
        let bundle = BackupBundle(
            appVersion: appVersion,
            characters: characters,
            chats: loadChats(),
            lorebooks: loadLorebooks(),
            memories: loadAllMemories(),
            settings: loadSettings(),
            avatars: avatars
        )
        return try encoder.encode(bundle)
    }

    public struct RestoreSummary: Sendable {
        public var characters = 0
        public var chats = 0
        public var lorebooks = 0
        public var memories = 0
        public var settingsRestored = false
    }

    /// 从备份恢复：按 id 覆盖同名实体，备份里没有的现有数据保留。
    @discardableResult
    public func restore(from data: Data, includeSettings: Bool) throws -> RestoreSummary {
        let bundle = try decoder.decode(BackupBundle.self, from: data)
        guard bundle.formatVersion <= BackupBundle.currentFormat else {
            throw BackupBundle.BackupError.newerFormat(bundle.formatVersion)
        }
        var summary = RestoreSummary()
        for (name, data) in bundle.avatars {
            // 文件名来自备份，只取最后一段，防止路径穿越
            let safe = URL(fileURLWithPath: name).lastPathComponent
            try data.write(to: avatarURL(safe), options: [.atomic])
        }
        for c in bundle.characters { try save(c); summary.characters += 1 }
        for chat in bundle.chats { try save(chat); summary.chats += 1 }
        for book in bundle.lorebooks { try save(book); summary.lorebooks += 1 }
        for memory in bundle.memories { try save(memory); summary.memories += 1 }
        if includeSettings, let settings = bundle.settings {
            try save(settings)
            summary.settingsRestored = true
        }
        return summary
    }
}

public struct BackupBundle: Codable, Sendable {
    public static let currentFormat = 1

    public enum BackupError: Error, LocalizedError {
        case newerFormat(Int)
        public var errorDescription: String? {
            switch self {
            case .newerFormat(let v): return "备份来自更新版本的应用（格式 \(v)），请先升级"
            }
        }
    }

    public var formatVersion: Int
    public var createdAt: Date
    public var appVersion: String
    public var characters: [TavernCharacter]
    public var chats: [ChatSession]
    public var lorebooks: [Lorebook]
    public var memories: [ChatMemory]
    public var settings: AppSettings?
    public var avatars: [String: Data]

    public init(
        appVersion: String,
        characters: [TavernCharacter],
        chats: [ChatSession],
        lorebooks: [Lorebook],
        memories: [ChatMemory],
        settings: AppSettings?,
        avatars: [String: Data]
    ) {
        self.formatVersion = BackupBundle.currentFormat
        self.createdAt = Date()
        self.appVersion = appVersion
        self.characters = characters
        self.chats = chats
        self.lorebooks = lorebooks
        self.memories = memories
        self.settings = settings
        self.avatars = avatars
    }
}
