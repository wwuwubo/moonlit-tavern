import Foundation

/// 把逐 token 吐出的字节拼成合法 UTF-8 文本。
/// 一个汉字常被拆成多个 token，单独解码会出现乱码，这里把不完整的尾巴留到下一次。
public struct UTF8Accumulator: Sendable {
    private var pending: [UInt8] = []

    public init() {}

    public mutating func append(_ bytes: [UInt8]) -> String {
        pending += bytes
        let validLength = Self.longestValidPrefix(pending)
        guard validLength > 0 else {
            // 长度超过 4 仍无法解码，说明是非法序列：丢掉首字节，避免卡死
            if pending.count > 4 { pending.removeFirst() }
            return ""
        }
        let text = String(decoding: pending[0..<validLength], as: UTF8.self)
        pending.removeFirst(validLength)
        return text
    }

    public mutating func flush() -> String {
        defer { pending = [] }
        return pending.isEmpty ? "" : String(decoding: pending, as: UTF8.self)
    }

    /// 末尾不完整的多字节序列不计入。
    static func longestValidPrefix(_ bytes: [UInt8]) -> Int {
        var i = 0
        var lastComplete = 0
        while i < bytes.count {
            let b = bytes[i]
            let length: Int
            if b < 0x80 { length = 1 }
            else if b & 0xE0 == 0xC0 { length = 2 }
            else if b & 0xF0 == 0xE0 { length = 3 }
            else if b & 0xF8 == 0xF0 { length = 4 }
            else { // 非法首字节：当作单字节吞掉（解码时会变成替换字符）
                i += 1; lastComplete = i; continue
            }
            if i + length > bytes.count { break }
            var ok = true
            for j in 1..<length where bytes[i + j] & 0xC0 != 0x80 { ok = false }
            i += ok ? length : 1
            lastComplete = i
        }
        return lastComplete
    }
}

/// 流式输出过滤：
/// - 遇到停止词立刻截断（停止词本身不显示）
/// - 可能是停止词开头的部分先扣住，确认不是再放出
/// - 隐藏开头的 <think>…</think> 思考段
///
/// 防止「吞回复」的几条规则：
/// - 只有出现在输出最开头的 <think> 才算思考段；正文中间冒出来的思考标签只删标签，内容照常显示
/// - 思考段到生成结束都没闭合（模型把正文写进了思考段，或用完了长度上限）：把这部分当正文放出来
/// - 孤立的 </think> 只删标签，不删它前面的正文
public struct StreamingTextFilter: Sendable {
    public private(set) var visibleText = ""
    public private(set) var stopped = false
    public private(set) var matchedStop: String?
    /// 被当作思考段隐藏的字符数（诊断用）
    public private(set) var hiddenThinkingCount = 0
    /// 思考段直到结束都没闭合，内容已作为正文放出
    public private(set) var unclosedThinking = false

    private enum ThinkState: Sendable { case undecided, inThink, done }

    private let stops: [String]
    private let hideThinking: Bool
    private var held = ""
    private var thinkState: ThinkState
    private var thinkBuffer = ""
    private var raw = ""

    /// - startsInsideThinking: 提示词末尾已经打开了 <think>（模板替模型开了头），输出从思考段里开始。
    public init(stopSequences: [String], hideThinking: Bool = true, startsInsideThinking: Bool = false) {
        self.stops = stopSequences.filter { !$0.isEmpty }
        self.hideThinking = hideThinking
        if !hideThinking {
            thinkState = .done
        } else {
            thinkState = startsInsideThinking ? .inThink : .undecided
        }
    }

    /// 原始输出的字符数（诊断用）
    public var rawCount: Int { raw.count }

    /// 输入新文本，返回本次可以显示的增量。
    public mutating func feed(_ piece: String) -> String {
        guard !stopped, !piece.isEmpty else { return "" }
        raw += piece
        var output = ""
        var incoming = piece
        while !incoming.isEmpty && !stopped {
            switch thinkState {
            case .undecided:
                let pending = held + incoming
                held = ""
                incoming = ""
                let trimmed = pending.drop(while: { $0.isWhitespace })
                if trimmed.hasPrefix("<think>") {
                    thinkState = .inThink
                    incoming = String(trimmed.dropFirst("<think>".count))
                } else if trimmed.isEmpty || "<think>".hasPrefix(trimmed) {
                    held = pending // 还判断不了是不是思考段，先扣住
                } else {
                    thinkState = .done
                    incoming = pending
                }
            case .inThink:
                let pending = thinkBuffer + incoming
                incoming = ""
                if let end = pending.range(of: "</think>") {
                    hiddenThinkingCount += pending.distance(from: pending.startIndex, to: end.lowerBound)
                    thinkBuffer = ""
                    thinkState = .done
                    incoming = String(pending[end.upperBound...].drop(while: { $0.isWhitespace }))
                } else {
                    thinkBuffer = pending
                }
            case .done:
                output += processVisible(held + incoming, final: false)
                incoming = ""
            }
        }
        visibleText += output
        return output
    }

    /// 生成结束时放出被扣住的文本。
    public mutating func finish() -> String {
        guard !stopped else {
            held = ""
            thinkBuffer = ""
            return ""
        }
        var output = ""
        switch thinkState {
        case .undecided:
            thinkState = .done
            output = processVisible(held, final: true)
        case .inThink:
            thinkState = .done
            let content = thinkBuffer
            thinkBuffer = ""
            if !content.trimmed.isEmpty { unclosedThinking = true }
            output = processVisible(content, final: true)
        case .done:
            output = processVisible(held, final: true)
        }
        visibleText += output
        return output
    }

    /// 处理确定要显示的文本：去掉零散的思考标签、检查停止词、扣住可能是停止词开头的尾巴。
    private mutating func processVisible(_ text: String, final: Bool) -> String {
        held = ""
        let cleaned = hideThinking ? Self.removingThinkTags(text) : text
        let (emit, stop) = scanForStops(cleaned)
        if stop || final { return emit }
        var guards = stops
        if hideThinking { guards += ["<think>", "</think>"] }
        let tail = Self.partialSuffix(of: emit, matching: guards)
        held = tail
        return String(emit.dropLast(tail.count))
    }

    static func removingThinkTags(_ text: String) -> String {
        guard text.contains("think>") else { return text }
        return text.replacingOccurrences(of: "<think>", with: "").replacingOccurrences(of: "</think>", with: "")
    }

    private mutating func scanForStops(_ text: String) -> (String, Bool) {
        var earliest: (Range<String.Index>, String)?
        for stop in stops {
            if let r = text.range(of: stop), earliest == nil || r.lowerBound < earliest!.0.lowerBound {
                earliest = (r, stop)
            }
        }
        if let (range, stop) = earliest {
            stopped = true
            matchedStop = stop
            return (String(text[..<range.lowerBound]), true)
        }
        return (text, false)
    }

    /// 文本末尾与任一模式开头重合的最长部分。
    static func partialSuffix(of text: String, matching patterns: [String]) -> String {
        var best = ""
        for pattern in patterns {
            let maxLen = min(pattern.count - 1, text.count)
            guard maxLen > 0 else { continue }
            for len in stride(from: maxLen, through: 1, by: -1) {
                let suffix = String(text.suffix(len))
                if pattern.hasPrefix(suffix) {
                    if len > best.count { best = suffix }
                    break
                }
            }
        }
        return best
    }
}

public enum ResponseSanitizer {
    /// 生成结束后的清理：去掉思考段、开头重复的名字前缀、首尾空白。
    public static func clean(_ text: String, speakerName: String) -> String {
        var s = text.strippingThinkBlocks().trimmed
        for prefix in ["\(speakerName)：", "\(speakerName):", "**\(speakerName)**：", "**\(speakerName):**"] where s.hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count)).trimmed
        }
        // 动作描写没写完就停了（常见于达到回复长度上限）：
        // 结尾孤零零的星号去掉；开了头没收尾的动作补上收尾星号，界面才能按动作描写显示
        if s.hasSuffix("*"), s.filter({ $0 == "*" }).count % 2 == 1 {
            s = String(s.dropLast()).trimmed
        }
        if s.filter({ $0 == "*" }).count % 2 == 1,
           let last = s.lastIndex(of: "*"),
           let next = s.index(last, offsetBy: 1, limitedBy: s.endIndex), next < s.endIndex,
           !s[next].isWhitespace {
            s += "*"
        }
        return s
    }
}

/// 一次回复的定稿结果：要保存的正文和诊断信息。
public struct ReplyOutcome: Sendable, Equatable {
    /// 要保存的正文。为空表示确实没有可保存的内容。
    public var content: String
    /// 流式显示出来的字符数
    public var visibleCount: Int
    /// 清理后的字符数
    public var cleanedCount: Int
    /// 清理后为空，改用了只去掉标签的原文
    public var usedFallback: Bool

    /// 一行诊断记录，写进「诊断日志」
    public func logLine(stopReason: String, saved: Bool, error: String?) -> String {
        var line = "回复定稿：显示 \(visibleCount) 字，清理后 \(cleanedCount) 字，停止原因 \(stopReason)"
        if usedFallback { line += "，清理后为空，已改存原文" }
        if let error { line += "，生成出错：\(error)" }
        line += saved ? "，已保存 \(content.count) 字" : "，未保存"
        return line
    }
}

public enum ReplyFinalizer {
    /// 生成结束（或中途出错、被停止）后，决定保存什么。
    /// 规则：已经显示给用户的正文不能因为清理而整段消失。
    public static func finalize(visible: String, speakerName: String) -> ReplyOutcome {
        let cleaned = ResponseSanitizer.clean(visible, speakerName: speakerName)
        if !cleaned.isEmpty {
            return ReplyOutcome(content: cleaned, visibleCount: visible.count, cleanedCount: cleaned.count, usedFallback: false)
        }
        let fallback = StreamingTextFilter.removingThinkTags(visible).trimmed
        let meaningful = fallback.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
        return ReplyOutcome(
            content: meaningful ? fallback : "",
            visibleCount: visible.count,
            cleanedCount: 0,
            usedFallback: meaningful
        )
    }
}
