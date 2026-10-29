import Foundation

/// 消息树操作。每条消息记录父消息，重新生成会产生兄弟节点（「滑动」切换），
/// 从任意消息还可以分叉出新存档。当前显示的对话是从根到 `activeLeafID` 的路径。
public extension ChatSession {
    func message(_ id: UUID) -> ChatMessage? {
        messages.first { $0.id == id }
    }

    func children(of parentID: UUID?) -> [ChatMessage] {
        messages.filter { $0.parentID == parentID }.sorted { $0.createdAt < $1.createdAt }
    }

    /// 当前活动路径，根 → 叶。
    func activePath() -> [ChatMessage] {
        guard let leaf = activeLeafID else { return [] }
        let byID = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
        var path: [ChatMessage] = []
        var cursor: UUID? = leaf
        var guardCount = 0
        while let id = cursor, let message = byID[id], guardCount <= messages.count {
            path.append(message)
            cursor = message.parentID
            guardCount += 1
        }
        return path.reversed()
    }

    /// 兄弟消息（含自己），按时间排序。
    func siblings(of id: UUID) -> [ChatMessage] {
        guard let m = message(id) else { return [] }
        return children(of: m.parentID)
    }

    /// 某条消息在兄弟中的位置，例如 (2, 3) 表示 3 个版本中的第 2 个。
    func siblingPosition(of id: UUID) -> (index: Int, count: Int) {
        let s = siblings(of: id)
        let idx = s.firstIndex { $0.id == id } ?? 0
        return (idx + 1, max(s.count, 1))
    }

    /// 从某条消息往下走，每次选最新的子消息，直到叶子。
    func latestLeaf(from id: UUID) -> UUID {
        var current = id
        while let next = children(of: current).last {
            current = next.id
        }
        return current
    }

    /// 在当前叶子后追加消息并设为新叶子。
    @discardableResult
    mutating func append(_ message: ChatMessage) -> ChatMessage {
        var m = message
        m.parentID = activeLeafID
        messages.append(m)
        activeLeafID = m.id
        updatedAt = Date()
        return m
    }

    /// 添加一个与 `siblingOf` 同父的新版本（重新生成 / 改写用户消息时使用），并切换过去。
    @discardableResult
    mutating func addSibling(_ message: ChatMessage, siblingOf id: UUID) -> ChatMessage? {
        guard let original = self.message(id) else { return nil }
        var m = message
        m.parentID = original.parentID
        messages.append(m)
        activeLeafID = m.id
        updatedAt = Date()
        return m
    }

    /// 切换到相邻版本（offset = -1 上一个，+1 下一个）。
    mutating func switchSibling(of id: UUID, offset: Int) {
        let s = siblings(of: id)
        guard let idx = s.firstIndex(where: { $0.id == id }) else { return }
        let target = idx + offset
        guard s.indices.contains(target) else { return }
        activeLeafID = latestLeaf(from: s[target].id)
        updatedAt = Date()
    }

    mutating func editMessage(_ id: UUID, content: String) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[idx].content = content
        messages[idx].editedAt = Date()
        // 选项是照着原来的回复想的，改了回复就作废
        messages[idx].suggestions = nil
        updatedAt = Date()
    }

    /// 「继续」写完一条回复：正文换成续写后的全文，统计换成续写这一次的，旧选项作废。
    /// 不算用户编辑，不产生新版本。
    mutating func continueMessage(_ id: UUID, content: String, stats: GenerationStats?) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[idx].content = content
        if let stats { messages[idx].stats = stats }
        messages[idx].suggestions = nil
        updatedAt = Date()
    }

    /// 写入（或清空）某条回复后的剧情选项。只改选项，不动回复正文和当前分支。
    mutating func setSuggestions(_ options: [String]?, for id: UUID) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[idx].suggestions = options
    }

    mutating func setHidden(_ id: UUID, hidden: Bool) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[idx].isHidden = hidden
        updatedAt = Date()
    }

    /// 删除一条消息及其所有后代。活动路径经过它时，回退到兄弟版本或父消息。
    mutating func deleteMessage(_ id: UUID) {
        guard let target = message(id) else { return }
        var toRemove: Set<UUID> = [id]
        var frontier = [id]
        while let current = frontier.popLast() {
            for child in messages where child.parentID == current {
                if toRemove.insert(child.id).inserted { frontier.append(child.id) }
            }
        }
        let pathIDs = Set(activePath().map(\.id))
        messages.removeAll { toRemove.contains($0.id) }
        if pathIDs.contains(id) {
            if let sibling = children(of: target.parentID).last {
                activeLeafID = latestLeaf(from: sibling.id)
            } else {
                activeLeafID = target.parentID
            }
        }
        updatedAt = Date()
    }

    /// 截取到某条消息为止的路径，作为新存档（分支剧情）。
    func forked(at id: UUID, title: String) -> ChatSession? {
        let path = activePath()
        let pathToTarget: [ChatMessage]
        if let idx = path.firstIndex(where: { $0.id == id }) {
            pathToTarget = Array(path[...idx])
        } else {
            // 不在活动路径上：沿父链回溯
            var chain: [ChatMessage] = []
            var cursor: UUID? = id
            while let cid = cursor, let m = message(cid) {
                chain.append(m)
                cursor = m.parentID
            }
            guard !chain.isEmpty else { return nil }
            pathToTarget = chain.reversed()
        }
        // 新存档使用新的消息 id，避免两个存档共享 id
        var idMap: [UUID: UUID] = [:]
        var copied: [ChatMessage] = []
        for m in pathToTarget {
            var c = m
            let newID = UUID()
            idMap[m.id] = newID
            c.id = newID
            c.parentID = m.parentID.flatMap { idMap[$0] }
            copied.append(c)
        }
        var session = ChatSession(
            title: title,
            characterIDs: characterIDs,
            messages: copied,
            activeLeafID: copied.last?.id,
            lorebookIDs: lorebookIDs,
            authorsNote: authorsNote,
            turnOrder: turnOrder,
            plotState: plotState,
            loreState: loreState,
            historyAnchor: 0,
            persona: persona
        )
        session.isSample = false
        return session
    }
}
