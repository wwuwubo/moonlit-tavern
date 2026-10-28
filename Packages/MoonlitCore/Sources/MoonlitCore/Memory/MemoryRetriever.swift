import Foundation

/// 长期记忆检索：第一版用关键词，不依赖向量模型。
///
/// 选择顺序：
/// 1. 常驻（pinned）记忆
/// 2. 最新的两条剧情摘要（前情提要）
/// 3. 其余记忆按得分排序：关键词重合度（BM25 风格的 IDF 加权）× 1 + 重要度 × 0.4 + 新近度 × 0.3
/// 全程受 token 预算约束，放不下的跳过。
public struct MemoryRetriever {
    public struct Selection: Sendable {
        public var items: [MemoryItem]
        public var tokens: Int
    }

    public init() {}

    public func select(
        from memory: ChatMemory,
        query: String,
        tokenBudget: Int,
        maxRetrieved: Int,
        tokenCounter: TokenCounter
    ) -> Selection {
        let enabled = memory.items.filter { $0.enabled && !$0.content.isBlank }
        guard !enabled.isEmpty, tokenBudget > 0 else { return Selection(items: [], tokens: 0) }

        var chosen: [MemoryItem] = []
        var used = 0
        func tryAdd(_ item: MemoryItem) -> Bool {
            guard !chosen.contains(where: { $0.id == item.id }) else { return false }
            let cost = tokenCounter.count(item.promptLine) + 2
            guard used + cost <= tokenBudget else { return false }
            used += cost
            chosen.append(item)
            return true
        }

        for item in enabled where item.pinned { _ = tryAdd(item) }

        let summaries = enabled.filter { $0.kind == .summary && !$0.pinned }
            .sorted { ($0.messageIndex, $0.createdAt) > ($1.messageIndex, $1.createdAt) }
        for item in summaries.prefix(2) { _ = tryAdd(item) }

        let chosenIDs = Set(chosen.map(\.id))
        let pool = enabled.filter { !$0.pinned && !chosenIDs.contains($0.id) }
        let queryTerms = Set(KeywordExtractor.terms(in: query))
        let docTerms = pool.map { item -> Set<String> in
            var terms = Set(KeywordExtractor.terms(in: item.content + " " + item.subject + " " + item.object))
            for keyword in item.keywords { terms.formUnion(KeywordExtractor.terms(in: keyword)); terms.insert(keyword.lowercased()) }
            return terms
        }
        // IDF
        var df: [String: Int] = [:]
        for terms in docTerms { for t in terms { df[t, default: 0] += 1 } }
        let n = Double(max(pool.count, 1))
        let maxIndex = Double(max(pool.map(\.messageIndex).max() ?? 1, 1))

        let scored: [(MemoryItem, Double)] = zip(pool, docTerms).map { item, terms in
            let overlap = terms.intersection(queryTerms)
            let lexical = overlap.reduce(0.0) { acc, t in
                acc + log(1 + n / Double(df[t] ?? 1))
            }
            let importance = Double(item.importance) / 5.0
            let recency = Double(item.messageIndex) / maxIndex
            // 关系类记忆对角色一致性帮助大，略微加权
            let kindBoost = item.kind == .relationship ? 0.15 : 0
            return (item, lexical + importance * 0.4 + recency * 0.3 + kindBoost)
        }
        var retrieved = 0
        for (item, _) in scored.sorted(by: { $0.1 > $1.1 }) where retrieved < maxRetrieved {
            if tryAdd(item) { retrieved += 1 }
        }
        return Selection(items: chosen, tokens: used)
    }

    /// 渲染进提示词。摘要在前，其余按类型分组。
    public static func render(_ items: [MemoryItem]) -> String {
        var lines = ["【长期记忆（此前发生的事，保持一致）】"]
        let summaries = items.filter { $0.kind == .summary }.sorted { $0.messageIndex < $1.messageIndex }
        if !summaries.isEmpty {
            lines.append("前情提要：")
            lines += summaries.map { $0.content.trimmed }
        }
        for kind in [MemoryKind.event, .relationship, .fact] {
            let group = items.filter { $0.kind == kind }
            guard !group.isEmpty else { continue }
            lines.append("\(kind.rawValue)：")
            lines += group.map { "- " + $0.promptLine.trimmed }
        }
        return lines.joined(separator: "\n")
    }
}

/// 关键词抽取：英文按单词（去停用词），中文按二字组（汉字没有空格分词，二元组召回效果稳定）。
public enum KeywordExtractor {
    static let englishStopwords: Set<String> = [
        "the", "a", "an", "and", "or", "but", "of", "to", "in", "on", "at", "for", "with", "is", "are", "was",
        "were", "be", "been", "it", "this", "that", "you", "i", "he", "she", "they", "we", "me", "my", "your",
        "his", "her", "their", "our", "as", "by", "from", "not", "no", "do", "did", "have", "has", "had"
    ]
    static let cjkStopChars: Set<Swift.Character> = ["的", "了", "是", "在", "我", "你", "他", "她", "它", "们", "这", "那", "就", "也", "和", "着", "吗", "呢", "吧", "啊", "一", "不"]

    public static func terms(in text: String) -> [String] {
        var result: [String] = []
        var word = ""
        var cjkRun: [Swift.Character] = []

        func flushWord() {
            let w = word.lowercased()
            if w.count >= 2, !englishStopwords.contains(w) { result.append(w) }
            word = ""
        }
        func flushCJK() {
            let chars = cjkRun.filter { !cjkStopChars.contains($0) }
            if chars.count == 1 {
                // 单字不作为检索词，太泛
            } else if chars.count >= 2 {
                for i in 0..<(chars.count - 1) {
                    result.append(String(chars[i...i + 1]))
                }
            }
            cjkRun = []
        }

        for ch in text {
            if let scalar = ch.unicodeScalars.first, scalar.isCJKLike, ch.isLetter {
                flushWord()
                cjkRun.append(ch)
            } else if ch.isLetter || ch.isNumber {
                flushCJK()
                word.append(ch)
            } else {
                flushWord()
                flushCJK()
            }
        }
        flushWord()
        flushCJK()
        return result
    }
}
