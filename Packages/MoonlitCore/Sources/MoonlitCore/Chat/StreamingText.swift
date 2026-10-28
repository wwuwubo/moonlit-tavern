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
/// - 隐藏 <think>…</think> 思考段
public struct StreamingTextFilter: Sendable {
    public private(set) var visibleText = ""
    public private(set) var stopped = false
    public private(set) var matchedStop: String?

    private let stops: [String]
    private let hideThinking: Bool
    private var held = ""
    private var inThink = false
    private var raw = ""

    public init(stopSequences: [String], hideThinking: Bool = true) {
        self.stops = stopSequences.filter { !$0.isEmpty }
        self.hideThinking = hideThinking
    }

    /// 输入新文本，返回本次可以显示的增量。
    public mutating func feed(_ piece: String) -> String {
        guard !stopped, !piece.isEmpty else { return "" }
        raw += piece
        var buffer = held + piece
        held = ""
        var output = ""

        while !buffer.isEmpty {
            if hideThinking && inThink {
                if let end = buffer.range(of: "</think>") {
                    buffer = String(buffer[end.upperBound...])
                    inThink = false
                    continue
                }
                // 保留可能的半个结束标签
                held = Self.partialSuffix(of: buffer, matching: ["</think>"])
                buffer = ""
                break
            }
            if hideThinking, let start = buffer.range(of: "<think>") {
                let before = String(buffer[..<start.lowerBound])
                let (emit, stop) = scanForStops(before)
                output += emit
                if stop { buffer = ""; break }
                buffer = String(buffer[start.upperBound...])
                inThink = true
                continue
            }
            let (emit, stop) = scanForStops(buffer)
            if stop {
                output += emit
                buffer = ""
                break
            }
            // 扣住可能是停止词（或 <think>）开头的尾巴
            var guards = stops
            if hideThinking { guards.append("<think>") }
            let tail = Self.partialSuffix(of: emit, matching: guards)
            output += String(emit.dropLast(tail.count))
            held = tail
            buffer = ""
        }
        visibleText += output
        return output
    }

    /// 生成结束时放出被扣住的文本。
    public mutating func finish() -> String {
        guard !stopped, !inThink else { held = ""; return "" }
        let rest = held
        held = ""
        visibleText += rest
        return rest
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
