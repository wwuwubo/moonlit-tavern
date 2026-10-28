import Foundation
import MoonlitCore

/// 本地模型的加载配置。
struct LlamaLoadConfig: Equatable, Sendable {
    var modelURL: URL
    var contextLength: Int
    var kvCacheType: KVCacheType
    var gpuLayers: Int
    var threads: Int
    var batchSize: Int
    var flashAttention: Bool
    var promptFormat: PromptFormat
    var disableThinking: Bool
}

/// 已加载模型的信息（全部来自 llama.cpp 的真实返回值）。
struct LoadedModelInfo: Equatable, Sendable {
    var fileName: String
    var description: String
    var architecture: String
    var parameterCount: UInt64
    var modelSizeBytes: UInt64
    var trainContext: Int
    var contextLength: Int
    var batchSize: Int
    var resolvedFormat: PromptFormat
    var supportsThinking: Bool
    var gpuOffload: Bool
    var loadSeconds: Double
    var footprintAfterLoadMB: Double?
    var kvCacheType: KVCacheType
}

/// 取消标记。每次生成一个，互不干扰。
final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    func cancel() {
        lock.lock(); flag = true; lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return flag
    }
}

#if canImport(llama)
import llama

/// 基于 llama.cpp（Metal 后端）的本地推理引擎。
///
/// 线程模型：所有 llama.cpp 调用都在一条专用串行队列上执行，UI 线程从不阻塞。
/// 取消：每次生成持有一个 CancelToken，在每个 token、每个提示词批次之间检查。
/// KV 缓存复用：记录缓存里的 token 序列，新提示词与之共享的前缀不重复计算；
/// 混合架构（如 Qwen3.5 的 DeltaNet 层）无法部分回退时，自动清空重算。
final class LlamaEngine: InferenceEngine, @unchecked Sendable {
    let engineName = "llama.cpp · Metal"
    let isLocal = true

    private let queue = DispatchQueue(label: "moonlit.llama.engine", qos: .userInitiated)
    /// 保护 model/vocab 生命周期，供其他线程安全地分词。
    private let lifetimeLock = NSLock()
    private let stateLock = NSLock()

    // 以下只在 queue 上读写（vocab 另受 lifetimeLock 保护）
    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var vocab: OpaquePointer?
    private var cachedTokens: [llama_token] = []
    private var config: LlamaLoadConfig?
    private var chatTemplate: String?
    /// 混合 / 循环架构（Qwen3.5 的 DeltaNet 层等）：状态无法部分回退。
    private var needsCheckpoints = false
    /// 提示词末尾前一个位置的「部分状态」检查点（只含循环层状态，几十 MB）。
    /// 重新生成、停止后重来时，从这里恢复，不用整段重算。
    private var checkpoint: (tokens: [llama_token], data: [UInt8])?

    private var _info: LoadedModelInfo?
    private var currentToken: CancelToken?

    private static let backendInit: Void = {
        llama_backend_init()
        llama_log_set({ level, text, _ in
            guard let text else { return }
            // 只保留警告和错误，信息级日志太多
            if level.rawValue >= GGML_LOG_LEVEL_WARN.rawValue {
                EngineLog.shared.append("llama: " + String(cString: text))
            }
        }, nil)
    }()

    init() {
        _ = Self.backendInit
    }

    deinit {
        if let context { llama_free(context) }
        if let model { llama_model_free(model) }
    }

    var info: LoadedModelInfo? {
        stateLock.lock(); defer { stateLock.unlock() }
        return _info
    }

    var loadedConfig: LlamaLoadConfig? {
        stateLock.lock(); defer { stateLock.unlock() }
        return config
    }

    // MARK: - 加载与卸载

    func load(_ config: LlamaLoadConfig, progress: @escaping @Sendable (Double) -> Void) async throws -> LoadedModelInfo {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<LoadedModelInfo, Error>) in
            queue.async {
                do {
                    let info = try self.loadOnQueue(config, progress: progress)
                    cont.resume(returning: info)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private final class ProgressBox {
        let handler: (Double) -> Void
        init(_ handler: @escaping (Double) -> Void) { self.handler = handler }
    }

    private func loadOnQueue(_ config: LlamaLoadConfig, progress: @escaping (Double) -> Void) throws -> LoadedModelInfo {
        unloadOnQueue()
        let path = config.modelURL.path
        guard FileManager.default.fileExists(atPath: path) else {
            throw InferenceError.modelFileMissing(config.modelURL.lastPathComponent)
        }
        let start = Date()
        EngineLog.shared.append("开始加载 \(config.modelURL.lastPathComponent)，上下文 \(config.contextLength)，KV \(config.kvCacheType.rawValue)")

        var mparams = llama_model_default_params()
        mparams.n_gpu_layers = Int32(config.gpuLayers)
        #if targetEnvironment(simulator)
        mparams.n_gpu_layers = 0
        #endif
        let box = ProgressBox(progress)
        let boxPointer = Unmanaged.passRetained(box).toOpaque()
        defer { Unmanaged<ProgressBox>.fromOpaque(boxPointer).release() }
        mparams.progress_callback = { value, userData in
            if let userData {
                Unmanaged<ProgressBox>.fromOpaque(userData).takeUnretainedValue().handler(Double(value))
            }
            return true
        }
        mparams.progress_callback_user_data = boxPointer

        guard let loadedModel = llama_model_load_from_file(path, mparams) else {
            throw InferenceError.modelLoadFailed("llama.cpp 无法读取该文件，可能不是受支持的 GGUF 模型，或者内存不足")
        }

        let threads = config.threads > 0
            ? config.threads
            : max(1, min(6, ProcessInfo.processInfo.activeProcessorCount - 2))
        var cparams = llama_context_default_params()
        cparams.n_ctx = UInt32(config.contextLength)
        cparams.n_batch = UInt32(config.batchSize)
        cparams.n_ubatch = UInt32(min(config.batchSize, 512))
        cparams.n_seq_max = 1
        cparams.n_threads = Int32(threads)
        cparams.n_threads_batch = Int32(threads)
        cparams.flash_attn_type = config.flashAttention ? LLAMA_FLASH_ATTN_TYPE_AUTO : LLAMA_FLASH_ATTN_TYPE_DISABLED
        switch config.kvCacheType {
        case .f16:
            cparams.type_k = GGML_TYPE_F16
            cparams.type_v = GGML_TYPE_F16
        case .q8_0:
            cparams.type_k = GGML_TYPE_Q8_0
            // 量化的 V 缓存要求开启 Flash Attention
            cparams.type_v = config.flashAttention ? GGML_TYPE_Q8_0 : GGML_TYPE_F16
        }

        guard let ctx = llama_init_from_model(loadedModel, cparams) else {
            llama_model_free(loadedModel)
            throw InferenceError.contextCreationFailed("上下文 \(config.contextLength) 所需内存可能超出限制")
        }

        let loadedVocab = llama_model_get_vocab(loadedModel)
        lifetimeLock.lock()
        model = loadedModel
        context = ctx
        vocab = loadedVocab
        lifetimeLock.unlock()
        cachedTokens = []
        checkpoint = nil
        needsCheckpoints = llama_model_is_recurrent(loadedModel) || llama_model_is_hybrid(loadedModel)

        let template = llama_model_chat_template(loadedModel, nil).map { String(cString: $0) }
        chatTemplate = template
        let architecture = metaString(loadedModel, key: "general.architecture") ?? "未知"
        let resolved = config.promptFormat == .auto
            ? PromptFormat.detect(chatTemplate: template, architecture: architecture)
            : config.promptFormat

        var descBuffer = [CChar](repeating: 0, count: 256)
        _ = llama_model_desc(loadedModel, &descBuffer, descBuffer.count)

        let info = LoadedModelInfo(
            fileName: config.modelURL.lastPathComponent,
            description: String(cString: descBuffer),
            architecture: architecture,
            parameterCount: llama_model_n_params(loadedModel),
            modelSizeBytes: llama_model_size(loadedModel),
            trainContext: Int(llama_model_n_ctx_train(loadedModel)),
            contextLength: Int(llama_n_ctx(ctx)),
            batchSize: Int(llama_n_batch(ctx)),
            resolvedFormat: resolved,
            supportsThinking: PromptFormat.supportsThinking(chatTemplate: template),
            gpuOffload: llama_supports_gpu_offload() && config.gpuLayers != 0,
            loadSeconds: Date().timeIntervalSince(start),
            footprintAfterLoadMB: DeviceMetrics.footprintMB(),
            kvCacheType: config.kvCacheType
        )
        stateLock.lock()
        self.config = config
        _info = info
        stateLock.unlock()
        EngineLog.shared.append(String(format: "加载完成：%@，%.1f 秒，进程内存 %.0f MB",
                                       info.description, info.loadSeconds, info.footprintAfterLoadMB ?? -1))
        return info
    }

    private func metaString(_ model: OpaquePointer, key: String) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        let n = llama_model_meta_val_str(model, key, &buffer, buffer.count)
        return n >= 0 ? String(cString: buffer) : nil
    }

    func unload() async {
        currentTokenSnapshot()?.cancel()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                self.unloadOnQueue()
                cont.resume()
            }
        }
    }

    private func unloadOnQueue() {
        lifetimeLock.lock()
        if let context { llama_free(context) }
        if let model { llama_model_free(model) }
        context = nil
        model = nil
        vocab = nil
        lifetimeLock.unlock()
        cachedTokens = []
        checkpoint = nil
        chatTemplate = nil
        stateLock.lock()
        let hadModel = _info != nil
        _info = nil
        config = nil
        stateLock.unlock()
        if hadModel { EngineLog.shared.append("模型已卸载") }
    }

    // MARK: - 分词

    func tokenize(_ text: String, addSpecial: Bool, parseSpecial: Bool) -> [llama_token]? {
        lifetimeLock.lock()
        defer { lifetimeLock.unlock() }
        guard let vocab else { return nil }
        return Self.tokenize(vocab: vocab, text: text, addSpecial: addSpecial, parseSpecial: parseSpecial)
    }

    private static func tokenize(vocab: OpaquePointer, text: String, addSpecial: Bool, parseSpecial: Bool) -> [llama_token] {
        let byteCount = Int32(text.utf8.count)
        var capacity = Int(byteCount) + 8
        var tokens = [llama_token](repeating: 0, count: capacity)
        var n = llama_tokenize(vocab, text, byteCount, &tokens, Int32(capacity), addSpecial, parseSpecial)
        if n < 0 {
            capacity = Int(-n)
            tokens = [llama_token](repeating: 0, count: capacity)
            n = llama_tokenize(vocab, text, byteCount, &tokens, Int32(capacity), addSpecial, parseSpecial)
        }
        return n > 0 ? Array(tokens.prefix(Int(n))) : []
    }

    private static func piece(vocab: OpaquePointer, token: llama_token) -> [UInt8] {
        var buffer = [CChar](repeating: 0, count: 32)
        var n = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        if n < 0 {
            buffer = [CChar](repeating: 0, count: Int(-n))
            n = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        }
        guard n > 0 else { return [] }
        return buffer.prefix(Int(n)).map { UInt8(bitPattern: $0) }
    }

    func tokenCounter() -> TokenCounter? {
        guard info != nil else { return nil }
        return LlamaTokenCounter(engine: self)
    }

    // MARK: - 生成

    private func currentTokenSnapshot() -> CancelToken? {
        stateLock.lock(); defer { stateLock.unlock() }
        return currentToken
    }

    func cancel() {
        currentTokenSnapshot()?.cancel()
    }

    func generate(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error> {
        let token = CancelToken()
        stateLock.lock()
        currentToken = token
        stateLock.unlock()

        return AsyncThrowingStream { continuation in
            continuation.onTermination = { _ in token.cancel() }
            queue.async {
                do {
                    let stats = try self.runGeneration(request, token: token) { event in
                        continuation.yield(event)
                    }
                    continuation.yield(.finished(stats))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// 渲染提示词文本。模型内置模板交给 llama_chat_apply_template。
    private func renderPrompt(_ request: GenerationRequest, format: PromptFormat, disableThinking: Bool, supportsThinking: Bool) -> RenderedPrompt {
        if format == .modelBuiltin, let template = chatTemplate {
            let merged = ChatTemplateRenderer.mergeConsecutive(request.messages)
            let roles: [UnsafeMutablePointer<CChar>] = merged.map { strdup($0.role.rawValue)! }
            let contents: [UnsafeMutablePointer<CChar>] = merged.map { strdup($0.content)! }
            defer {
                roles.forEach { free($0) }
                contents.forEach { free($0) }
            }
            let chat: [llama_chat_message] = zip(roles, contents).map {
                llama_chat_message(role: UnsafePointer($0), content: UnsafePointer($1))
            }
            var buffer = [CChar](repeating: 0, count: 64 * 1024)
            var n = llama_chat_apply_template(template, chat, chat.count, true, &buffer, Int32(buffer.count))
            if n > Int32(buffer.count) {
                buffer = [CChar](repeating: 0, count: Int(n) + 1)
                n = llama_chat_apply_template(template, chat, chat.count, true, &buffer, Int32(buffer.count))
            }
            if n > 0 {
                let bytes = buffer.prefix(Int(n)).map { UInt8(bitPattern: $0) }
                return RenderedPrompt(text: String(decoding: bytes, as: UTF8.self) + request.prefill, stopSequences: [])
            }
            EngineLog.shared.append("内置模板渲染失败，改用 ChatML")
        }
        return ChatTemplateRenderer.render(
            request.messages,
            format: format,
            prefill: request.prefill,
            disableThinking: disableThinking,
            modelSupportsThinking: supportsThinking
        )
    }

    /// 保存「部分状态」检查点（只含循环层状态）。只在 queue 上调用。
    private func saveCheckpoint(ctx: OpaquePointer) {
        let flags = llama_state_seq_flags(LLAMA_STATE_SEQ_FLAGS_PARTIAL_ONLY)
        let size = llama_state_seq_get_size_ext(ctx, 0, flags)
        guard size > 0 else { checkpoint = nil; return }
        var data = [UInt8](repeating: 0, count: size)
        let written = llama_state_seq_get_data_ext(ctx, &data, size, 0, flags)
        if written == size {
            checkpoint = (tokens: cachedTokens, data: data)
        } else {
            checkpoint = nil
            EngineLog.shared.append("检查点保存失败（\(written)/\(size) 字节）")
        }
    }

    private func restoreCheckpoint(_ ckpt: (tokens: [llama_token], data: [UInt8]), ctx: OpaquePointer) -> Bool {
        let flags = llama_state_seq_flags(LLAMA_STATE_SEQ_FLAGS_PARTIAL_ONLY)
        let read = ckpt.data.withUnsafeBufferPointer { buffer in
            llama_state_seq_set_data_ext(ctx, buffer.baseAddress, buffer.count, 0, flags)
        }
        if read != ckpt.data.count {
            EngineLog.shared.append("检查点恢复失败，改为整段重算")
            return false
        }
        return true
    }

    private func runGeneration(
        _ request: GenerationRequest,
        token cancelToken: CancelToken,
        emit: (GenerationEvent) -> Void
    ) throws -> GenerationStats {
        guard let ctx = context, let vocab, let info = self.info, let config = self.loadedConfig else {
            throw InferenceError.noModelSelected
        }
        let startTime = Date()
        let rendered = renderPrompt(request, format: info.resolvedFormat,
                                    disableThinking: config.disableThinking, supportsThinking: info.supportsThinking)
        let addBOS = llama_vocab_get_add_bos(vocab)
        let promptTokens = Self.tokenize(vocab: vocab, text: rendered.text, addSpecial: addBOS, parseSpecial: true)
        let nCtx = Int(llama_n_ctx(ctx))
        guard !promptTokens.isEmpty else { throw InferenceError.modelLoadFailed("提示词分词结果为空") }
        guard promptTokens.count < nCtx - 16 else {
            throw InferenceError.promptTooLong(tokens: promptTokens.count, context: nCtx)
        }
        let maxNew = min(request.maxNewTokens, nCtx - promptTokens.count - 1)

        // ---- KV 缓存前缀复用 ----
        let memory = llama_get_memory(ctx)
        var common = 0
        let limit = min(cachedTokens.count, promptTokens.count)
        while common < limit && cachedTokens[common] == promptTokens[common] { common += 1 }
        if common == promptTokens.count { common -= 1 } // 至少重新计算最后一个 token 以取得 logits
        if common < cachedTokens.count {
            if llama_memory_seq_rm(memory, 0, Int32(common), -1) {
                // 标准 Transformer：直接截断
            } else if let ckpt = checkpoint, ckpt.tokens.count <= common,
                      promptTokens.starts(with: ckpt.tokens),
                      restoreCheckpoint(ckpt, ctx: ctx),
                      llama_memory_seq_rm(memory, 0, Int32(ckpt.tokens.count), -1) {
                // 混合架构：恢复循环层检查点，再截断注意力层的 KV
                common = ckpt.tokens.count
            } else {
                llama_memory_clear(memory, true)
                checkpoint = nil
                common = 0
            }
        }
        cachedTokens = Array(promptTokens.prefix(common))

        // ---- 处理提示词 ----
        let batchCapacity = max(Int(llama_n_batch(ctx)), 32)
        var batch = llama_batch_init(Int32(batchCapacity), 0, 1)
        defer { llama_batch_free(batch) }

        let toEvaluate = Array(promptTokens[common...])
        emit(.progress(.processingPrompt, 0))
        var processed = 0
        while processed < toEvaluate.count {
            if cancelToken.isCancelled { throw InferenceError.cancelled }
            let chunk = toEvaluate[processed..<min(processed + batchCapacity, toEvaluate.count)]
            batch.n_tokens = 0
            for (offset, tok) in chunk.enumerated() {
                let i = Int(batch.n_tokens)
                batch.token[i] = tok
                batch.pos[i] = llama_pos(common + processed + offset)
                batch.n_seq_id[i] = 1
                batch.seq_id[i]![0] = 0
                batch.logits[i] = 0
                batch.n_tokens += 1
            }
            let isLastChunk = processed + chunk.count == toEvaluate.count
            if isLastChunk {
                // 混合架构：最后一个 token 单独计算，在它之前保存检查点
                if needsCheckpoints && chunk.count > 1 {
                    batch.n_tokens -= 1
                    let rcPrefix = llama_decode(ctx, batch)
                    if rcPrefix != 0 {
                        llama_memory_clear(memory, true)
                        cachedTokens = []
                        checkpoint = nil
                        throw InferenceError.decodeFailed(rcPrefix)
                    }
                    cachedTokens.append(contentsOf: chunk.dropLast())
                    processed += chunk.count - 1
                    saveCheckpoint(ctx: ctx)
                    batch.n_tokens = 0
                    let i = 0
                    batch.token[i] = chunk.last!
                    batch.pos[i] = llama_pos(common + processed)
                    batch.n_seq_id[i] = 1
                    batch.seq_id[i]![0] = 0
                    batch.n_tokens = 1
                } else if needsCheckpoints, checkpoint?.tokens != cachedTokens {
                    saveCheckpoint(ctx: ctx)
                }
                batch.logits[Int(batch.n_tokens) - 1] = 1
            }
            let chunkCount = Int(batch.n_tokens)
            let evaluatedSlice = isLastChunk && needsCheckpoints && chunk.count > 1 ? Array(chunk.suffix(1)) : Array(chunk)
            let rc = llama_decode(ctx, batch)
            if rc != 0 {
                llama_memory_clear(memory, true)
                cachedTokens = []
                checkpoint = nil
                throw InferenceError.decodeFailed(rc)
            }
            processed += chunkCount
            cachedTokens.append(contentsOf: evaluatedSlice)
            emit(.progress(.processingPrompt, Double(processed) / Double(toEvaluate.count)))
        }
        let promptDone = Date()

        // ---- 采样器 ----
        let sampling = request.sampling
        let chain = llama_sampler_chain_init(llama_sampler_chain_default_params())!
        defer { llama_sampler_free(chain) }
        if sampling.repeatPenalty != 1 || sampling.presencePenalty != 0 || sampling.frequencyPenalty != 0 {
            llama_sampler_chain_add(chain, llama_sampler_init_penalties(
                llama_vocab_n_tokens(vocab),
                Int32(sampling.repeatLastN),
                Float(sampling.repeatPenalty),
                Float(sampling.frequencyPenalty),
                Float(sampling.presencePenalty)
            ))
        }
        if sampling.topK > 0 { llama_sampler_chain_add(chain, llama_sampler_init_top_k(Int32(sampling.topK))) }
        if sampling.topP < 1 { llama_sampler_chain_add(chain, llama_sampler_init_top_p(Float(sampling.topP), 1)) }
        if sampling.minP > 0 { llama_sampler_chain_add(chain, llama_sampler_init_min_p(Float(sampling.minP), 1)) }
        if sampling.temperature <= 0 {
            llama_sampler_chain_add(chain, llama_sampler_init_greedy())
        } else {
            llama_sampler_chain_add(chain, llama_sampler_init_temp(Float(sampling.temperature)))
            // UInt32.max 即 LLAMA_DEFAULT_SEED：每次随机
            llama_sampler_chain_add(chain, llama_sampler_init_dist(sampling.seed ?? UInt32.max))
        }
        // 让重复惩罚看到最近的上下文
        for tok in promptTokens.suffix(max(sampling.repeatLastN, 0)) {
            llama_sampler_accept(chain, tok)
        }

        // ---- 逐 token 生成 ----
        emit(.progress(.generating, nil))
        var utf8 = UTF8Accumulator()
        var filter = StreamingTextFilter(stopSequences: request.stopSequences + rendered.stopSequences, hideThinking: true)
        var generated = 0
        var firstTokenTime: Date?
        var stopReason = "长度上限"
        var nPast = promptTokens.count

        while generated < maxNew {
            if cancelToken.isCancelled { stopReason = "用户停止"; break }
            let next = llama_sampler_sample(chain, ctx, -1)
            if firstTokenTime == nil { firstTokenTime = Date() }
            if llama_vocab_is_eog(vocab, next) { stopReason = "自然结束"; break }
            generated += 1

            let text = utf8.append(Self.piece(vocab: vocab, token: next))
            let visible = filter.feed(text)
            if !visible.isEmpty { emit(.text(visible)) }
            if filter.stopped { stopReason = "停止词"; break }

            if nPast >= nCtx - 1 { stopReason = "上下文已满"; break }
            batch.n_tokens = 1
            batch.token[0] = next
            batch.pos[0] = llama_pos(nPast)
            batch.n_seq_id[0] = 1
            batch.seq_id[0]![0] = 0
            batch.logits[0] = 1
            let rc = llama_decode(ctx, batch)
            if rc != 0 {
                llama_memory_clear(memory, true)
                cachedTokens = []
                throw InferenceError.decodeFailed(rc)
            }
            cachedTokens.append(next)
            nPast += 1
        }
        if !filter.stopped {
            let rest = filter.feed(utf8.flush()) + filter.finish()
            if !rest.isEmpty { emit(.text(rest)) }
        }
        let end = Date()
        let firstToken = firstTokenTime ?? end

        return GenerationStats(
            engine: engineName,
            modelName: info.fileName,
            promptTokens: promptTokens.count,
            promptTokensEvaluated: toEvaluate.count,
            generatedTokens: generated,
            timeToFirstToken: firstToken.timeIntervalSince(startTime),
            promptSeconds: promptDone.timeIntervalSince(startTime),
            generationSeconds: end.timeIntervalSince(firstToken),
            contextLength: nCtx,
            stopReason: stopReason,
            peakMemoryMB: DeviceMetrics.footprintMB()
        )
    }
}

/// 用已加载模型的分词器精确计数。
struct LlamaTokenCounter: TokenCounter {
    let engine: LlamaEngine

    func count(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        // parseSpecial = false：按普通文本计，避免把用户文本里的模板符号当控制符
        return engine.tokenize(text, addSpecial: false, parseSpecial: false)?.count ?? HeuristicTokenCounter().count(text)
    }
}

enum LlamaAvailability {
    static let isAvailable = true
    static let detail = "llama.cpp 已集成（Metal GPU 加速）"
}

#else

/// 本构建没有链接 llama.cpp（例如在模拟器上编译）。不提供任何假推理：调用即报错。
final class LlamaEngine: InferenceEngine, @unchecked Sendable {
    let engineName = "llama.cpp（未包含）"
    let isLocal = true
    var info: LoadedModelInfo? { nil }
    var loadedConfig: LlamaLoadConfig? { nil }

    func load(_ config: LlamaLoadConfig, progress: @escaping @Sendable (Double) -> Void) async throws -> LoadedModelInfo {
        throw InferenceError.backendUnavailable("此构建未包含 llama.cpp 推理库，无法运行本地模型。")
    }

    func unload() async {}

    func generate(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: InferenceError.backendUnavailable("此构建未包含 llama.cpp 推理库，无法运行本地模型。")) }
    }

    func cancel() {}
    func tokenCounter() -> TokenCounter? { nil }
}

enum LlamaAvailability {
    static let isAvailable = false
    static let detail = "此构建未包含 llama.cpp"
}

#endif
