import Foundation

/// 群聊发言顺序。
public enum GroupDirector {
    /// 选出下一位发言的角色。
    /// - natural：最近一条消息里被点名的角色优先（不会连续让同一个角色发言），否则轮到最久没说话的角色。
    /// - roundRobin：按参与者顺序轮流。
    /// - weightedRandom：按积极度（talkativeness）加权随机，排除刚发过言的角色。
    /// - manual：返回 nil，由用户选择。
    public static func nextSpeaker(
        in session: ChatSession,
        characters: [TavernCharacter],
        strategy: TurnOrderStrategy? = nil,
        random: () -> Double = { Double.random(in: 0..<1) }
    ) -> TavernCharacter? {
        let participants = session.characterIDs.compactMap { id in characters.first { $0.id == id } }
        guard !participants.isEmpty else { return nil }
        if participants.count == 1 { return participants[0] }

        let path = session.activePath()
        let lastAssistant = path.last { $0.role == .assistant }
        let lastSpeakerID = lastAssistant?.speakerID

        switch strategy ?? session.turnOrder {
        case .manual:
            return nil

        case .roundRobin:
            guard let last = lastSpeakerID, let idx = participants.firstIndex(where: { $0.id == last }) else {
                return participants[0]
            }
            return participants[(idx + 1) % participants.count]

        case .weightedRandom:
            let pool = participants.filter { $0.id != lastSpeakerID }
            let weights = pool.map { max($0.talkativeness, 0.05) }
            let total = weights.reduce(0, +)
            var r = random() * total
            for (character, w) in zip(pool, weights) {
                if r < w { return character }
                r -= w
            }
            return pool.last

        case .natural:
            if let last = path.last {
                let mentioned = participants.filter { c in
                    c.id != lastSpeakerID && (last.content.contains(c.name) || (!c.nickname.isBlank && last.content.contains(c.nickname)))
                }
                if let first = mentioned.min(by: { a, b in
                    (last.content.range(of: a.name)?.lowerBound ?? last.content.endIndex) <
                    (last.content.range(of: b.name)?.lowerBound ?? last.content.endIndex)
                }) {
                    return first
                }
            }
            // 最久没发言的角色
            var lastSpokeAt: [UUID: Int] = [:]
            for (i, m) in path.enumerated() where m.role == .assistant {
                if let id = m.speakerID { lastSpokeAt[id] = i }
            }
            return participants
                .filter { $0.id != lastSpeakerID }
                .min { (lastSpokeAt[$0.id] ?? -1) < (lastSpokeAt[$1.id] ?? -1) }
                ?? participants[0]
        }
    }
}
