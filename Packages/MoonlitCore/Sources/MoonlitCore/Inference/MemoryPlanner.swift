import Foundation

/// 加载前的内存估算。全部是**理论估算**，界面上会注明；真实占用以加载后测得的进程内存为准。
///
/// 组成：
/// - 权重：约等于 GGUF 文件大小（llama.cpp 以 mmap 方式映射，Apple 芯片上 Metal 直接使用这块内存）
/// - KV 缓存：上下文长度 × 注意力层数 × KV 头数 × (K 维度 + V 维度) × 每元素字节数
///   混合架构（如 Qwen3.5 每 4 层只有 1 层完整注意力）只计注意力层
/// - 计算缓冲：经验值，随上下文增长
/// - 应用本身：界面、数据等，取 180 MB
public struct MemoryEstimate: Sendable, Equatable {
    public var weightsMB: Double
    public var kvCacheMB: Double
    public var computeMB: Double
    public var overheadMB: Double

    public var totalMB: Double { weightsMB + kvCacheMB + computeMB + overheadMB }
}

public struct ModelShape: Sendable, Equatable {
    public var attentionLayers: Int
    /// 每个注意力层的 KV 头数 × (K 维度 + V 维度) 之和，按层累加。
    public var kvElementsPerToken: Int
    public var description: String

    public init(attentionLayers: Int, kvElementsPerToken: Int, description: String) {
        self.attentionLayers = attentionLayers
        self.kvElementsPerToken = kvElementsPerToken
        self.description = description
    }
}

public enum MemoryPlanner {
    public static let appOverheadMB: Double = 180

    /// 从 GGUF 元数据推算 KV 形状。缺少信息时返回 nil。
    public static func shape(from meta: GGUFMetadata) -> ModelShape? {
        guard let blocks = meta.blockCount, blocks > 0 else { return nil }
        let heads = meta.headCount ?? 0
        let embd = meta.embeddingLength ?? 0
        let defaultHeadDim = heads > 0 ? embd / heads : 128
        let kDim = meta.keyLength ?? defaultHeadDim
        let vDim = meta.valueLength ?? kDim

        var perLayerKV: [Int]
        if let array = meta.headCountKV, array.count == blocks {
            perLayerKV = array
        } else {
            let kv = meta.headCountKV?.first ?? heads
            perLayerKV = Array(repeating: kv, count: blocks)
        }
        if let interval = meta.fullAttentionInterval, interval > 1 {
            // 只有每 interval 层中的最后一层是完整注意力
            perLayerKV = perLayerKV.enumerated().map { (i, kv) in (i + 1) % interval == 0 ? kv : 0 }
        }
        let attentionLayers = perLayerKV.filter { $0 > 0 }.count
        let elements = perLayerKV.reduce(0) { $0 + $1 * (kDim + vDim) }
        let desc = "\(attentionLayers)/\(blocks) 层注意力，KV 头 \(perLayerKV.max() ?? 0)，头维度 \(kDim)"
        return ModelShape(attentionLayers: attentionLayers, kvElementsPerToken: elements, description: desc)
    }

    public static func kvCacheMB(shape: ModelShape, contextLength: Int, cacheType: KVCacheType) -> Double {
        Double(shape.kvElementsPerToken) * Double(contextLength) * cacheType.bytesPerElement / 1_048_576
    }

    public static func estimate(fileSizeBytes: Int64, shape: ModelShape?, contextLength: Int, cacheType: KVCacheType) -> MemoryEstimate {
        let weights = Double(fileSizeBytes) / 1_048_576
        let kv = shape.map { kvCacheMB(shape: $0, contextLength: contextLength, cacheType: cacheType) }
            // 不知道形状时按 4B 级别 Transformer 的典型值保守估算
            ?? Double(contextLength) * 0.14
        let compute = 260 + Double(contextLength) / 8192 * 140
        return MemoryEstimate(weightsMB: weights, kvCacheMB: kv, computeMB: compute, overheadMB: appOverheadMB)
    }

    /// 在给定可用内存下，从候选上下文长度里挑能放下的最大值（预留 10% 余量）。
    public static func recommendedContext(
        fileSizeBytes: Int64,
        shape: ModelShape?,
        cacheType: KVCacheType,
        availableMB: Double,
        candidates: [Int] = [8192, 6144, 4096, 3072, 2048]
    ) -> Int? {
        for ctx in candidates {
            let e = estimate(fileSizeBytes: fileSizeBytes, shape: shape, contextLength: ctx, cacheType: cacheType)
            if e.totalMB * 1.1 <= availableMB { return ctx }
        }
        return nil
    }
}
