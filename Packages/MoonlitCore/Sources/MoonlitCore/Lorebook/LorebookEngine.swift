import Foundation

/// 世界书激活引擎。
///
/// 规则（按执行顺序）：
/// 1. **候选过滤**：条目需启用、内容非空、满足角色过滤、满足剧情状态条件、消息数达到 delay、不在冷却中
///    （粘滞中的条目无视冷却）。
/// 2. **初次激活**：常驻条目直接激活；粘滞剩余回合 > 0 的条目直接激活；其余条目在最近 scanDepth
///    条消息（含本次输入）里匹配主关键词，命中后再按 selectiveLogic 校验次要关键词。
/// 3. **概率**：常驻和关键词激活的条目按 probability 掷骰；粘滞条目不掷骰。
/// 4. **递归**：已激活条目（preventRecursion 除外）的内容作为新的扫描文本，最多 maxRecursionSteps 轮，
///    excludeRecursion 的条目不参与递归激活。
/// 5. **组内互斥**：同一 group 只保留一个，比较顺序：常驻 > 粘滞 > priority 高 > insertionOrder 高 > uid 小。
/// 6. **预算裁剪**：按「常驻 > 粘滞 > priority 高 > insertionOrder 高」排序依次装入，超出 token 预算的丢弃。
/// 7. **输出排序**：同一位置内按 insertionOrder 升序（数值大的离生成点更近）。
public struct LorebookEngine {
    public enum Reason: Hashable, Sendable {
        case constant
        case sticky
        case keyword(String)
        case recursion(String)

        public var label: String {
            switch self {
            case .constant: return "常驻"
            case .sticky: return "粘滞"
            case .keyword(let k): return "关键词「\(k)」"
            case .recursion(let k): return "递归「\(k)」"
            }
        }
    }

    public enum DropReason: String, Sendable {
        case budget = "超出预算"
        case group = "同组已有更高优先级条目"
    }

    public struct Activation: Identifiable, Sendable {
        public var entry: LoreEntry
        public var bookName: String
        public var reason: Reason
        public var tokens: Int
        public var id: UUID { entry.id }
    }

    public struct Dropped: Sendable {
        public var activation: Activation
        public var reason: DropReason
    }

    public struct Input {
        public var books: [Lorebook]
        /// 最近的消息文本，旧 → 新。
        public var recentMessages: [String]
        /// 本次用户输入（尚未进入历史）。
        public var pendingInput: String?
        public var activeCharacterName: String
        public var plotState: [String: String]
        public var messageCount: Int
        public var state: LorebookRuntimeState
        public var tokenBudget: Int
        public var tokenCounter: TokenCounter
        /// 返回 0..<100 的随机数；测试时可注入固定值。
        public var roll: (LoreEntry) -> Int

        public init(
            books: [Lorebook],
            recentMessages: [String],
            pendingInput: String? = nil,
            activeCharacterName: String,
            plotState: [String: String] = [:],
            messageCount: Int,
            state: LorebookRuntimeState = LorebookRuntimeState(),
            tokenBudget: Int,
            tokenCounter: TokenCounter = HeuristicTokenCounter(),
            roll: @escaping (LoreEntry) -> Int = { _ in Int.random(in: 0..<100) }
        ) {
            self.books = books
            self.recentMessages = recentMessages
            self.pendingInput = pendingInput
            self.activeCharacterName = activeCharacterName
            self.plotState = plotState
            self.messageCount = messageCount
            self.state = state
            self.tokenBudget = tokenBudget
            self.tokenCounter = tokenCounter
            self.roll = roll
        }
    }

    public struct Result: Sendable {
        /// 最终注入的条目，已按位置和 insertionOrder 排好。
        public var included: [Activation]
        public var dropped: [Dropped]
        /// 推进一回合后的状态。只有真正发出生成请求时才应保存。
        public var nextState: LorebookRuntimeState
        public var tokensUsed: Int

        public func entries(at position: LorePosition) -> [Activation] {
            included.filter { $0.entry.position == position }
        }
    }

    public init() {}

    public func evaluate(_ input: Input) -> Result {
        struct Candidate {
            var entry: LoreEntry
            var book: Lorebook
        }

        // 1. 候选过滤
        var seen = Set<UUID>()
        var candidates: [Candidate] = []
        for book in input.books {
            for entry in book.entries where entry.enabled && !entry.content.isBlank {
                guard seen.insert(entry.id).inserted else { continue }
                guard passesCharacterFilter(entry, name: input.activeCharacterName) else { continue }
                guard entry.conditions.allSatisfy({ $0.isSatisfied(by: input.plotState) }) else { continue }
                guard input.messageCount >= entry.delay else { continue }
                let isSticky = (input.state.stickyRemaining[entry.id] ?? 0) > 0
                if !isSticky, (input.state.cooldownRemaining[entry.id] ?? 0) > 0 { continue }
                candidates.append(Candidate(entry: entry, book: book))
            }
        }

        var scanCache: [Int: String] = [:]
        func scanText(depth: Int) -> String {
            if let cached = scanCache[depth] { return cached }
            var parts = Array(input.recentMessages.suffix(max(depth, 0)))
            if let pending = input.pendingInput, !pending.isBlank { parts.append(pending) }
            let text = parts.joined(separator: "\n")
            scanCache[depth] = text
            return text
        }

        // 2-3. 初次激活
        var activated: [UUID: Activation] = [:]
        var order: [UUID] = []
        func activate(_ c: Candidate, _ reason: Reason) {
            guard activated[c.entry.id] == nil else { return }
            activated[c.entry.id] = Activation(
                entry: c.entry,
                bookName: c.book.name,
                reason: reason,
                tokens: input.tokenCounter.count(c.entry.content)
            )
            order.append(c.entry.id)
        }

        for c in candidates {
            if (input.state.stickyRemaining[c.entry.id] ?? 0) > 0 {
                activate(c, .sticky)
                continue
            }
            if c.entry.constant {
                if input.roll(c.entry) < c.entry.probability { activate(c, .constant) }
                continue
            }
            let depth = c.entry.scanDepth ?? c.book.scanDepth
            if let key = matchedKey(c.entry, in: scanText(depth: depth)),
               input.roll(c.entry) < c.entry.probability {
                activate(c, .keyword(key))
            }
        }

        // 4. 递归
        let recursionAllowed = input.books.contains { $0.recursiveScanning }
        if recursionAllowed {
            let maxSteps = input.books.map(\.maxRecursionSteps).max() ?? 0
            var buffer = order.compactMap { activated[$0] }
                .filter { !$0.entry.preventRecursion }
                .map(\.entry.content)
                .joined(separator: "\n")
            var step = 0
            while step < maxSteps, !buffer.isEmpty {
                step += 1
                var newContents: [String] = []
                for c in candidates where activated[c.entry.id] == nil && !c.entry.excludeRecursion && c.book.recursiveScanning {
                    if let key = matchedKey(c.entry, in: buffer), input.roll(c.entry) < c.entry.probability {
                        activate(c, .recursion(key))
                        if !c.entry.preventRecursion { newContents.append(c.entry.content) }
                    }
                }
                buffer = newContents.joined(separator: "\n")
            }
        }

        var list = order.compactMap { activated[$0] }
        var dropped: [Dropped] = []

        // 5. 组内互斥
        let grouped = Dictionary(grouping: list.filter { !$0.entry.group.isBlank }, by: { $0.entry.group })
        var losers = Set<UUID>()
        for (_, members) in grouped where members.count > 1 {
            let winner = members.sorted(by: Self.importance).first!
            for member in members where member.id != winner.id {
                losers.insert(member.id)
                dropped.append(Dropped(activation: member, reason: .group))
            }
        }
        list.removeAll { losers.contains($0.id) }

        // 6. 预算裁剪
        var used = 0
        var kept: [Activation] = []
        for item in list.sorted(by: Self.importance) {
            if input.tokenBudget > 0, used + item.tokens > input.tokenBudget {
                dropped.append(Dropped(activation: item, reason: .budget))
                continue
            }
            used += item.tokens
            kept.append(item)
        }

        // 7. 输出排序
        let positionRank: [LorePosition: Int] = [.beforeCharacter: 0, .afterCharacter: 1, .atDepth: 2]
        kept.sort {
            let p0 = positionRank[$0.entry.position] ?? 0, p1 = positionRank[$1.entry.position] ?? 0
            if p0 != p1 { return p0 < p1 }
            if $0.entry.insertionOrder != $1.entry.insertionOrder { return $0.entry.insertionOrder < $1.entry.insertionOrder }
            return $0.entry.uid < $1.entry.uid
        }

        return Result(
            included: kept,
            dropped: dropped,
            nextState: advanceState(input.state, included: kept, allEntries: candidates.map(\.entry)),
            tokensUsed: used
        )
    }

    /// 排序：常驻 > 粘滞 > priority 高 > insertionOrder 高 > uid 小
    static func importance(_ a: Activation, _ b: Activation) -> Bool {
        func rank(_ r: Reason) -> Int {
            switch r {
            case .constant: return 0
            case .sticky: return 1
            default: return 2
            }
        }
        if rank(a.reason) != rank(b.reason) { return rank(a.reason) < rank(b.reason) }
        if a.entry.priority != b.entry.priority { return a.entry.priority > b.entry.priority }
        if a.entry.insertionOrder != b.entry.insertionOrder { return a.entry.insertionOrder > b.entry.insertionOrder }
        return a.entry.uid < b.entry.uid
    }

    func advanceState(_ state: LorebookRuntimeState, included: [Activation], allEntries: [LoreEntry]) -> LorebookRuntimeState {
        var next = LorebookRuntimeState()
        // 冷却每回合减一
        for (id, remaining) in state.cooldownRemaining where remaining - 1 > 0 {
            next.cooldownRemaining[id] = remaining - 1
        }
        for item in included {
            let entry = item.entry
            if case .sticky = item.reason {
                let remaining = (state.stickyRemaining[entry.id] ?? 0) - 1
                if remaining > 0 {
                    next.stickyRemaining[entry.id] = remaining
                } else if entry.cooldown > 0 {
                    next.cooldownRemaining[entry.id] = entry.cooldown
                }
            } else if entry.sticky > 0 {
                // 本回合算第一回合
                if entry.sticky - 1 > 0 {
                    next.stickyRemaining[entry.id] = entry.sticky - 1
                } else if entry.cooldown > 0 {
                    next.cooldownRemaining[entry.id] = entry.cooldown
                }
            } else if entry.cooldown > 0 {
                next.cooldownRemaining[entry.id] = entry.cooldown
            }
        }
        return next
    }

    func passesCharacterFilter(_ entry: LoreEntry, name: String) -> Bool {
        guard !entry.characterFilter.isEmpty else { return true }
        let listed = entry.characterFilter.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
        return entry.characterFilterExclude ? !listed : listed
    }

    /// 返回命中的主关键词；未命中或次要关键词校验失败时返回 nil。
    public func matchedKey(_ entry: LoreEntry, in text: String) -> String? {
        guard !text.isEmpty else { return nil }
        guard let primary = entry.keys.first(where: { keyMatches($0, entry: entry, text: text) }) else { return nil }
        guard entry.selective, !entry.secondaryKeys.isEmpty else { return primary }
        let hits = entry.secondaryKeys.map { keyMatches($0, entry: entry, text: text) }
        let passed: Bool
        switch entry.selectiveLogic {
        case .andAny: passed = hits.contains(true)
        case .andAll: passed = hits.allSatisfy { $0 }
        case .notAny: passed = !hits.contains(true)
        case .notAll: passed = !hits.allSatisfy { $0 }
        }
        return passed ? primary : nil
    }

    func keyMatches(_ rawKey: String, entry: LoreEntry, text: String) -> Bool {
        let key = rawKey.trimmed
        guard !key.isEmpty else { return false }

        // /正则/flags
        if key.count > 2, key.hasPrefix("/"), let lastSlash = key.lastIndex(of: "/"), lastSlash != key.startIndex {
            let pattern = String(key[key.index(after: key.startIndex)..<lastSlash])
            let flags = key[key.index(after: lastSlash)...]
            var options: NSRegularExpression.Options = []
            if flags.contains("i") || !entry.caseSensitive { options.insert(.caseInsensitive) }
            if let regex = try? NSRegularExpression(pattern: pattern, options: options) {
                let range = NSRange(text.startIndex..<text.endIndex, in: text)
                return regex.firstMatch(in: text, options: [], range: range) != nil
            }
        }

        let options: String.CompareOptions = entry.caseSensitive ? [] : [.caseInsensitive]
        let containsCJK = key.unicodeScalars.contains { $0.isCJKLike }
        if !entry.matchWholeWords || containsCJK {
            return text.range(of: key, options: options) != nil
        }
        // 整词匹配：前后不能是字母或数字
        var searchRange = text.startIndex..<text.endIndex
        while let found = text.range(of: key, options: options, range: searchRange) {
            let beforeOK = found.lowerBound == text.startIndex || !text[text.index(before: found.lowerBound)].isWordCharacter
            let afterOK = found.upperBound == text.endIndex || !text[found.upperBound].isWordCharacter
            if beforeOK && afterOK { return true }
            searchRange = found.upperBound..<text.endIndex
        }
        return false
    }
}

extension Swift.Character {
    var isWordCharacter: Bool { isLetter || isNumber || self == "_" }
}
