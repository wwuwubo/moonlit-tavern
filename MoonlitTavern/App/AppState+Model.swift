import Foundation
import MoonlitCore

/// 设备上真实测得的性能数据。只在用户点击「测速」或「长上下文测试」时产生，不做任何推算。
struct BenchmarkResult: Codable, Identifiable, Hashable {
    var id = UUID()
    var date = Date()
    var kind: String
    var modelFile: String
    var contextLength: Int
    var kvCache: String
    var promptTokens: Int
    var generatedTokens: Int
    var timeToFirstToken: Double
    var promptTokensPerSecond: Double
    var generationTokensPerSecond: Double
    var footprintMB: Double?
    var availableMBBeforeLoad: Double?
    var thermal: String
    var deviceModel: String
    var systemVersion: String
    var succeeded: Bool
    var note: String

    static func fileURL(in root: URL) -> URL { root.appendingPathComponent("benchmarks.json") }

    static func load(from root: URL) -> [BenchmarkResult] {
        guard let data = try? Data(contentsOf: fileURL(in: root)) else { return [] }
        return (try? JSONDecoder().decode([BenchmarkResult].self, from: data)) ?? []
    }

    static func save(_ results: [BenchmarkResult], to root: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(results) {
            try? data.write(to: fileURL(in: root), options: .atomic)
        }
    }

    /// 以 Markdown 表格行导出，便于贴进测试报告。
    var markdownRow: String {
        let footprint = footprintMB.map { String(format: "%.0f", $0) } ?? "-"
        return String(format: "| %@ | %@ | %@ | %d | %@ | %d | %d | %.2f | %.1f | %.1f | %@ | %@ | %@ |",
                      date.formatted(date: .numeric, time: .shortened), kind, modelFile, contextLength, kvCache,
                      promptTokens, generatedTokens, timeToFirstToken, promptTokensPerSecond, generationTokensPerSecond,
                      footprint, thermal, succeeded ? "成功" : "失败：\(note)")
    }
}

extension AppState {
    var selectedModelFile: LocalModelFile? {
        models.model(named: settings.local.selectedModelFile)
    }

    func desiredLoadConfig(for file: LocalModelFile, contextOverride: Int? = nil) -> LlamaLoadConfig {
        LlamaLoadConfig(
            modelURL: file.url,
            contextLength: contextOverride ?? settings.local.contextLength,
            kvCacheType: settings.local.kvCacheType,
            gpuLayers: settings.local.gpuLayers,
            threads: settings.local.threads,
            batchSize: settings.local.batchSize,
            flashAttention: settings.local.flashAttention,
            promptFormat: settings.local.promptFormat,
            disableThinking: settings.local.disableThinking
        )
    }

    /// 确保本地模型已按当前设置加载；设置变了会重新加载。
    /// 加载前用 GGUF 元数据估算内存，超过系统给本应用的可用内存时自动降低上下文。
    func ensureModelLoaded(force: Bool = false) async throws {
        if models.models.isEmpty { await models.refresh() }
        if settings.local.selectedModelFile == nil, let first = models.models.first {
            settings.local.selectedModelFile = first.fileName
        }
        guard let fileName = settings.local.selectedModelFile else { throw InferenceError.noModelSelected }
        guard let file = models.model(named: fileName) else { throw InferenceError.modelFileMissing(fileName) }

        var config = desiredLoadConfig(for: file)
        if !force, let loaded = llama.loadedConfig, case .loaded = modelState {
            if loaded == config { return }
            // 上下文曾因内存不足被自动调低，而用户设置没变：不重复加载
            var sameExceptContext = config
            sameExceptContext.contextLength = loaded.contextLength
            if loaded == sameExceptContext, reducedContextRequest == config.contextLength { return }
        }
        if modelState.isLoaded || llama.info != nil {
            await llama.unload()
            modelState = .unloaded
        }

        let available = DeviceMetrics.availableMemoryMB()
        let estimate = file.estimate(contextLength: config.contextLength, cacheType: config.kvCacheType)
        EngineLog.shared.append(String(format: "内存估算 %.0f MB（权重 %.0f + KV %.0f + 计算 %.0f + 应用 %.0f），当前可用 %.0f MB",
                                       estimate.totalMB, estimate.weightsMB, estimate.kvCacheMB, estimate.computeMB, estimate.overheadMB, available))
        if !force, estimate.totalMB > available * 0.95 {
            if let smaller = MemoryPlanner.recommendedContext(
                fileSizeBytes: file.sizeBytes, shape: file.shape, cacheType: config.kvCacheType, availableMB: available
            ), smaller < config.contextLength {
                reducedContextRequest = config.contextLength
                config.contextLength = smaller
                show(.warning, "按估算，\(settings.local.contextLength) 上下文可能超出内存，本次自动改用 \(smaller)。")
            } else {
                throw InferenceError.insufficientMemory(requiredMB: Int(estimate.totalMB), availableMB: Int(available))
            }
        }

        if config.contextLength == settings.local.contextLength { reducedContextRequest = nil }
        modelState = .loading(0)
        do {
            let info = try await llama.load(config) { [weak self] value in
                Task { @MainActor in
                    if case .loading = self?.modelState { self?.modelState = .loading(value) }
                }
            }
            modelState = .loaded(info)
        } catch {
            modelState = .failed(error.localizedDescription)
            throw error
        }
    }

    func loadModel(force: Bool = false) async {
        do {
            try await ensureModelLoaded(force: force)
        } catch {
            show(.error, error.localizedDescription)
        }
    }

    func unloadModel() async {
        stopGeneration()
        await llama.unload()
        modelState = .unloaded
    }

    func selectModel(_ file: LocalModelFile) {
        settings.local.selectedModelFile = file.fileName
        // 根据模型模板自动设置格式；思考模式模型默认关闭思考
        settings.local.promptFormat = .auto
        if modelState.isLoaded {
            Task { await unloadModel() }
        }
    }

    // MARK: - 真机性能测试

    /// 测速：固定的中文角色扮演提示词（约 600 token），贪心解码 128 token。
    /// 每次在提示词开头加入随机标记，确保不命中 KV 缓存，测到的是完整的提示词处理速度。
    func runBenchmark(longContext: Bool = false) async {
        guard generation == nil else { return }
        let availableBefore = DeviceMetrics.availableMemoryMB()
        generation = GenerationState(chatID: nil, speakerID: nil, speakerName: longContext ? "长上下文测试" : "测速",
                                     purpose: .benchmark, phase: .loadingModel, progress: nil)
        defer { generation = nil }

        let kind = longContext ? "长上下文" : "测速"
        let fileName = settings.local.selectedModelFile ?? "未选择"
        do {
            try await ensureModelLoaded()
            guard case .loaded(let info) = modelState else { return }
            let marker = UUID().uuidString.prefix(8)
            let paragraph = """
            月光从酒馆高窗斜照进来，落在吧台上一排擦得发亮的锡杯上。艾琳把账本合上，听见门外的风铃响了三声。\
            来的是个披着斗篷的旅人，靴子上沾着钟楼广场特有的青灰色泥土。她没有抬头，只是把一杯热麦酒推了过去。\
            炉火噼啪作响，角落里的骑士握紧了剑柄。今夜是满月，镇上的人都知道，第十三声钟响之后最好别出门。
            """
            let targetTokens = longContext ? max(info.contextLength - 600, 1024) : 600
            var body = "[\(marker)]\n"
            let counter = llama.tokenCounter() ?? HeuristicTokenCounter()
            while counter.count(body) < targetTokens {
                body += paragraph + "\n"
            }
            let messages = [
                PromptMessage(role: .system, content: "你是一名小说作者，续写下面的故事，保持人物性格一致。"),
                PromptMessage(role: .user, content: body + "\n请续写下一段。")
            ]
            var sampling = SamplingParams()
            sampling.temperature = 0
            sampling.repeatPenalty = 1.0
            let request = GenerationRequest(messages: messages, sampling: sampling, maxNewTokens: longContext ? 64 : 128)
            var stats: GenerationStats?
            for try await event in llama.generate(request) {
                switch event {
                case .progress(let phase, let value):
                    generation?.phase = phase
                    generation?.progress = value
                case .text(let delta):
                    generation?.text += delta
                case .finished(let s):
                    stats = s
                }
            }
            guard let s = stats else { return }
            let result = BenchmarkResult(
                kind: kind, modelFile: info.fileName, contextLength: info.contextLength,
                kvCache: info.kvCacheType.rawValue, promptTokens: s.promptTokensEvaluated,
                generatedTokens: s.generatedTokens, timeToFirstToken: s.timeToFirstToken,
                promptTokensPerSecond: s.promptTokensPerSecond, generationTokensPerSecond: s.generationTokensPerSecond,
                footprintMB: s.peakMemoryMB, availableMBBeforeLoad: availableBefore,
                thermal: DeviceMetrics.thermalLabel, deviceModel: Self.deviceModelIdentifier(),
                systemVersion: Self.systemVersionString(), succeeded: true, note: s.stopReason
            )
            benchmarks.insert(result, at: 0)
            BenchmarkResult.save(benchmarks, to: store.root)
            lastStats = s
            show(.success, String(format: "%@完成：首 token %.2f 秒，生成 %.1f token/秒", kind, s.timeToFirstToken, s.generationTokensPerSecond))
        } catch {
            let result = BenchmarkResult(
                kind: kind, modelFile: fileName, contextLength: settings.local.contextLength,
                kvCache: settings.local.kvCacheType.rawValue, promptTokens: 0, generatedTokens: 0,
                timeToFirstToken: 0, promptTokensPerSecond: 0, generationTokensPerSecond: 0,
                footprintMB: DeviceMetrics.footprintMB(), availableMBBeforeLoad: availableBefore,
                thermal: DeviceMetrics.thermalLabel, deviceModel: Self.deviceModelIdentifier(),
                systemVersion: Self.systemVersionString(), succeeded: false, note: error.localizedDescription
            )
            benchmarks.insert(result, at: 0)
            BenchmarkResult.save(benchmarks, to: store.root)
            show(.error, "\(kind)失败：\(error.localizedDescription)")
        }
    }

    func clearBenchmarks() {
        benchmarks = []
        BenchmarkResult.save(benchmarks, to: store.root)
    }

    static func deviceModelIdentifier() -> String {
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
        return machine
    }

    static func systemVersionString() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
}
