import Foundation

// 设置类结构体的宽松解码：新版本增加字段后，旧的设置文件仍能读出来，缺的字段取默认值。
// 写在扩展里，结构体的逐成员初始化器得以保留。

extension SamplingParams {
    enum CodingKeys: String, CodingKey {
        case temperature, topP, topK, minP, repeatPenalty, repeatLastN, presencePenalty, frequencyPenalty, maxNewTokens, seed
        case dryMultiplier, dryBase, dryAllowedLength
    }

    public init(from decoder: Decoder) throws {
        let d = SamplingParams()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            temperature: try c.decodeIfPresent(Double.self, forKey: .temperature) ?? d.temperature,
            topP: try c.decodeIfPresent(Double.self, forKey: .topP) ?? d.topP,
            topK: try c.decodeIfPresent(Int.self, forKey: .topK) ?? d.topK,
            minP: try c.decodeIfPresent(Double.self, forKey: .minP) ?? d.minP,
            repeatPenalty: try c.decodeIfPresent(Double.self, forKey: .repeatPenalty) ?? d.repeatPenalty,
            repeatLastN: try c.decodeIfPresent(Int.self, forKey: .repeatLastN) ?? d.repeatLastN,
            presencePenalty: try c.decodeIfPresent(Double.self, forKey: .presencePenalty) ?? d.presencePenalty,
            frequencyPenalty: try c.decodeIfPresent(Double.self, forKey: .frequencyPenalty) ?? d.frequencyPenalty,
            maxNewTokens: try c.decodeIfPresent(Int.self, forKey: .maxNewTokens) ?? d.maxNewTokens,
            seed: try c.decodeIfPresent(UInt32.self, forKey: .seed),
            dryMultiplier: try c.decodeIfPresent(Double.self, forKey: .dryMultiplier) ?? d.dryMultiplier,
            dryBase: try c.decodeIfPresent(Double.self, forKey: .dryBase) ?? d.dryBase,
            dryAllowedLength: try c.decodeIfPresent(Int.self, forKey: .dryAllowedLength) ?? d.dryAllowedLength
        )
    }
}

extension LocalModelSettings {
    enum CodingKeys: String, CodingKey {
        case selectedModelFile, contextLength, kvCacheType, gpuLayers, threads, batchSize, flashAttention
        case promptFormat, disableThinking, unloadOnBackground
    }

    public init(from decoder: Decoder) throws {
        let d = LocalModelSettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            selectedModelFile: try c.decodeIfPresent(String.self, forKey: .selectedModelFile),
            contextLength: try c.decodeIfPresent(Int.self, forKey: .contextLength) ?? d.contextLength,
            kvCacheType: try c.decodeIfPresent(KVCacheType.self, forKey: .kvCacheType) ?? d.kvCacheType,
            gpuLayers: try c.decodeIfPresent(Int.self, forKey: .gpuLayers) ?? d.gpuLayers,
            threads: try c.decodeIfPresent(Int.self, forKey: .threads) ?? d.threads,
            batchSize: try c.decodeIfPresent(Int.self, forKey: .batchSize) ?? d.batchSize,
            flashAttention: try c.decodeIfPresent(Bool.self, forKey: .flashAttention) ?? d.flashAttention,
            promptFormat: (try? c.decodeIfPresent(PromptFormat.self, forKey: .promptFormat)) ?? d.promptFormat,
            disableThinking: try c.decodeIfPresent(Bool.self, forKey: .disableThinking) ?? d.disableThinking,
            unloadOnBackground: try c.decodeIfPresent(Bool.self, forKey: .unloadOnBackground) ?? d.unloadOnBackground
        )
    }
}

extension CloudSettings {
    enum CodingKeys: String, CodingKey {
        case baseURL, model, extraHeaders, timeoutSeconds
    }

    public init(from decoder: Decoder) throws {
        let d = CloudSettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            baseURL: try c.decodeIfPresent(String.self, forKey: .baseURL) ?? d.baseURL,
            model: try c.decodeIfPresent(String.self, forKey: .model) ?? d.model,
            extraHeaders: try c.decodeIfPresent([String: String].self, forKey: .extraHeaders) ?? d.extraHeaders,
            timeoutSeconds: try c.decodeIfPresent(Double.self, forKey: .timeoutSeconds) ?? d.timeoutSeconds
        )
    }
}

extension MemorySettings {
    enum CodingKeys: String, CodingKey {
        case autoSummarize, summarizeBatch, tokenBudget, maxRetrieved
    }

    public init(from decoder: Decoder) throws {
        let d = MemorySettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            autoSummarize: try c.decodeIfPresent(Bool.self, forKey: .autoSummarize) ?? d.autoSummarize,
            summarizeBatch: try c.decodeIfPresent(Int.self, forKey: .summarizeBatch) ?? d.summarizeBatch,
            tokenBudget: try c.decodeIfPresent(Int.self, forKey: .tokenBudget) ?? d.tokenBudget,
            maxRetrieved: try c.decodeIfPresent(Int.self, forKey: .maxRetrieved) ?? d.maxRetrieved
        )
    }
}
