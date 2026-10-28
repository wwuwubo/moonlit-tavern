import Foundation
import MoonlitCore

/// 推荐模型。文件名与大小均已在 Hugging Face 仓库文件列表中核对过（2026-10-29）。
struct ModelPreset: Identifiable, Hashable {
    var id: String { fileName }
    let title: String
    let repo: String
    let fileName: String
    let approxSize: String
    let license: String
    let note: String

    var huggingFaceURL: URL { URL(string: "https://huggingface.co/\(repo)/resolve/main/\(fileName)")! }
    /// hf-mirror.com 是第三方公共镜像，路径与 Hugging Face 相同。
    var mirrorURL: URL { URL(string: "https://hf-mirror.com/\(repo)/resolve/main/\(fileName)")! }
    var pageURL: URL { URL(string: "https://huggingface.co/\(repo)")! }

    static let all: [ModelPreset] = [
        ModelPreset(
            title: "Qwen3.5-4B · Q4_K_M（首发推荐）",
            repo: "unsloth/Qwen3.5-4B-GGUF",
            fileName: "Qwen3.5-4B-Q4_K_M.gguf",
            approxSize: "2.74 GB",
            license: "Apache-2.0",
            note: "中文能力强；混合注意力架构，8K 上下文的 KV 缓存很小。默认关闭思考模式。"
        ),
        ModelPreset(
            title: "Qwen3-4B-Instruct-2507 · Q4_K_M（备用）",
            repo: "lmstudio-community/Qwen3-4B-Instruct-2507-GGUF",
            fileName: "Qwen3-4B-Instruct-2507-Q4_K_M.gguf",
            approxSize: "2.50 GB",
            license: "Apache-2.0",
            note: "纯指令版，无思考模式，标准 Transformer 架构，兼容性最稳。8K 上下文 KV 缓存约 640 MB。"
        ),
        ModelPreset(
            title: "Qwen3.5-2B · Q4_K_M（轻量）",
            repo: "unsloth/Qwen3.5-2B-GGUF",
            fileName: "Qwen3.5-2B-Q4_K_M.gguf",
            approxSize: "1.28 GB",
            license: "Apache-2.0",
            note: "内存紧张或想要更快速度时使用，文笔和人设遵循弱于 4B。"
        )
    ]
}

/// 本地模型文件。
struct LocalModelFile: Identifiable, Hashable {
    var id: String { fileName }
    let fileName: String
    let url: URL
    let sizeBytes: Int64
    let architecture: String?
    let displayName: String?
    let quantization: String
    let trainContext: Int?
    let shapeDescription: String?
    let shape: ModelShape?
    let chatTemplateFormat: PromptFormat
    let supportsThinking: Bool
    let metadataError: String?

    static func == (lhs: LocalModelFile, rhs: LocalModelFile) -> Bool { lhs.fileName == rhs.fileName && lhs.sizeBytes == rhs.sizeBytes }
    func hash(into hasher: inout Hasher) { hasher.combine(fileName); hasher.combine(sizeBytes) }

    var sizeLabel: String { ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file) }

    func estimate(contextLength: Int, cacheType: KVCacheType) -> MemoryEstimate {
        MemoryPlanner.estimate(fileSizeBytes: sizeBytes, shape: shape, contextLength: contextLength, cacheType: cacheType)
    }
}

/// 模型文件管理：存放在「文稿/Models」目录。
/// 该目录在「文件」App 的「我的 iPad › 月下酒馆 › Models」里可见，可以直接把 GGUF 拖进去，省去一次复制。
/// 目录标记为不参与 iCloud 备份，避免数 GB 文件占用备份空间。
@MainActor
final class ModelLibrary: NSObject, ObservableObject {
    @Published private(set) var models: [LocalModelFile] = []
    @Published private(set) var isScanning = false
    @Published var importProgress: Double?
    @Published var importingName: String?
    @Published var downloads: [String: DownloadState] = [:]
    @Published var lastError: String?

    struct DownloadState: Equatable {
        var fileName: String
        var received: Int64
        var expected: Int64
        var finished = false
        var error: String?

        var fraction: Double? { expected > 0 ? Double(received) / Double(expected) : nil }
    }

    let directory: URL
    private var session: URLSession!
    private var taskFileNames: [Int: String] = [:]

    override init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        directory = docs.appendingPathComponent("Models", isDirectory: true)
        super.init()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 60 * 60 * 6
        config.waitsForConnectivity = true
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    func url(for fileName: String) -> URL {
        directory.appendingPathComponent(fileName)
    }

    func model(named fileName: String?) -> LocalModelFile? {
        guard let fileName else { return nil }
        return models.first { $0.fileName == fileName }
    }

    /// 扫描目录并读取每个文件的 GGUF 元数据（只读文件头）。
    func refresh() async {
        isScanning = true
        let dir = directory
        let scanned: [LocalModelFile] = await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            return files
                .filter { $0.pathExtension.lowercased() == "gguf" && !$0.lastPathComponent.hasPrefix("mmproj") }
                .map { ModelLibrary.inspect($0) }
                .sorted { $0.fileName < $1.fileName }
        }.value
        models = scanned
        isScanning = false
    }

    nonisolated static func inspect(_ url: URL) -> LocalModelFile {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? 0
        do {
            let meta = try GGUFReader.read(url: url)
            let shape = MemoryPlanner.shape(from: meta)
            return LocalModelFile(
                fileName: url.lastPathComponent, url: url, sizeBytes: size,
                architecture: meta.architecture, displayName: meta.name,
                quantization: meta.quantizationLabel, trainContext: meta.contextLength,
                shapeDescription: shape?.description, shape: shape,
                chatTemplateFormat: PromptFormat.detect(chatTemplate: meta.chatTemplate, architecture: meta.architecture),
                supportsThinking: PromptFormat.supportsThinking(chatTemplate: meta.chatTemplate),
                metadataError: nil
            )
        } catch {
            return LocalModelFile(
                fileName: url.lastPathComponent, url: url, sizeBytes: size,
                architecture: nil, displayName: nil, quantization: "未知", trainContext: nil,
                shapeDescription: nil, shape: nil, chatTemplateFormat: .auto, supportsThinking: false,
                metadataError: error.localizedDescription
            )
        }
    }

    // MARK: - 导入

    /// 从「文件」选择器导入：复制到模型目录。复制过程中按文件大小显示进度。
    func importModel(from source: URL) async {
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }

        let name = source.lastPathComponent
        guard name.lowercased().hasSuffix(".gguf") else {
            lastError = "只支持 .gguf 格式的模型文件"
            return
        }
        let destination = uniqueDestination(for: name)
        let total = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? 0
        importingName = name
        importProgress = 0

        let copyTask = Task.detached(priority: .userInitiated) { () -> String? in
            do {
                try FileManager.default.copyItem(at: source, to: destination)
                return nil
            } catch {
                return error.localizedDescription
            }
        }
        // 复制期间轮询目标文件大小作为进度
        let poller = Task { @MainActor in
            while !Task.isCancelled {
                if total > 0, let size = try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    self.importProgress = min(Double(size) / Double(total), 0.99)
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
        let failure = await copyTask.value
        poller.cancel()
        importProgress = nil
        importingName = nil
        if let failure {
            try? FileManager.default.removeItem(at: destination)
            lastError = "导入失败：\(failure)"
        } else {
            EngineLog.shared.append("已导入模型 \(destination.lastPathComponent)")
        }
        await refresh()
    }

    private func uniqueDestination(for name: String) -> URL {
        var candidate = url(for: name)
        var index = 2
        let base = (name as NSString).deletingPathExtension
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = url(for: "\(base)-\(index).gguf")
            index += 1
        }
        return candidate
    }

    func delete(_ model: LocalModelFile) async {
        do {
            try FileManager.default.removeItem(at: model.url)
        } catch {
            lastError = "删除失败：\(error.localizedDescription)"
        }
        await refresh()
    }

    // MARK: - 下载

    func download(from url: URL, fileName: String) {
        if let state = downloads[fileName], !state.finished, state.error == nil { return } // 已在下载
        let task = session.downloadTask(with: url)
        taskFileNames[task.taskIdentifier] = fileName
        downloads[fileName] = DownloadState(fileName: fileName, received: 0, expected: 0)
        EngineLog.shared.append("开始下载 \(fileName) 自 \(url.host ?? "")")
        task.resume()
    }

    func cancelDownload(_ fileName: String) {
        session.getAllTasks { tasks in
            Task { @MainActor in
                for task in tasks where self.taskFileNames[task.taskIdentifier] == fileName {
                    task.cancel()
                }
                self.downloads[fileName] = nil
            }
        }
    }
}

extension ModelLibrary: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let id = downloadTask.taskIdentifier
        Task { @MainActor in
            guard let name = self.taskFileNames[id] else { return }
            self.downloads[name]?.received = totalBytesWritten
            self.downloads[name]?.expected = totalBytesExpectedToWrite
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let id = downloadTask.taskIdentifier
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        // 临时文件在回调返回后就会被删除，必须同步移动
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".gguf")
        let moved = (try? FileManager.default.moveItem(at: location, to: staging)) != nil
        Task { @MainActor in
            guard let name = self.taskFileNames[id] else { return }
            guard moved, (200..<300).contains(status) else {
                try? FileManager.default.removeItem(at: staging)
                self.downloads[name]?.error = status == 0 ? "下载文件保存失败" : "服务器返回 \(status)"
                return
            }
            // 校验确实是 GGUF（防止把错误页面当模型）
            if !Self.hasGGUFMagic(staging) {
                try? FileManager.default.removeItem(at: staging)
                self.downloads[name]?.error = "下载内容不是 GGUF 文件"
                return
            }
            let destination = self.uniqueDestination(for: name)
            do {
                try FileManager.default.moveItem(at: staging, to: destination)
                self.downloads[name]?.finished = true
                EngineLog.shared.append("下载完成 \(destination.lastPathComponent)")
            } catch {
                self.downloads[name]?.error = error.localizedDescription
            }
            await self.refresh()
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let id = task.taskIdentifier
        Task { @MainActor in
            guard let name = self.taskFileNames[id] else { return }
            if (error as NSError).code == NSURLErrorCancelled { return }
            self.downloads[name]?.error = error.localizedDescription
        }
    }

    nonisolated static func hasGGUFMagic(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return handle.readData(ofLength: 4) == Data("GGUF".utf8)
    }
}
