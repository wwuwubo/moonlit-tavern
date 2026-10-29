import Foundation

/// 聊天消息的基础 Markdown 分块：段落、标题、列表、引用、代码块、分隔线。
/// 行内样式（粗体、斜体、行内代码）交给界面层的 AttributedString 处理。
public enum MarkdownBlock: Equatable, Sendable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case listItem(ordered: Bool, marker: String, text: String)
    case quote(String)
    case code(language: String, text: String)
    case divider
    /// 可折叠的一段（来自 HTML 的 <details><summary>…</summary>…</details>，常见于角色卡要求输出的状态栏）
    case details(summary: String, blocks: [MarkdownBlock])
}

public enum MarkdownParser {
    /// 先拆出 <details> 折叠段，其余 HTML 标签去掉（<br>、<p> 换成换行），再按 Markdown 分块。
    /// 只影响显示；保存的原文和送进模型的内容不变。
    public static func blocks(_ text: String) -> [MarkdownBlock] {
        var result: [MarkdownBlock] = []
        for segment in HTMLLite.split(text) {
            switch segment {
            case .text(let s):
                result += markdownBlocks(HTMLLite.stripTags(s))
            case .details(let summary, let body):
                let title = HTMLLite.stripTags(summary).trimmed
                result.append(.details(summary: title.isEmpty ? "详情" : title, blocks: blocks(body)))
            }
        }
        return result
    }

    static func markdownBlocks(_ text: String) -> [MarkdownBlock] {
        var result: [MarkdownBlock] = []
        var paragraph: [String] = []
        var codeLines: [String] = []
        var codeLanguage = ""
        var inCode = false

        func flushParagraph() {
            if !paragraph.isEmpty {
                result.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph = []
            }
        }

        for line in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if inCode {
                    result.append(.code(language: codeLanguage, text: codeLines.joined(separator: "\n")))
                    codeLines = []
                    inCode = false
                } else {
                    flushParagraph()
                    codeLanguage = String(trimmed.dropFirst(3)).trimmed
                    inCode = true
                }
                continue
            }
            if inCode { codeLines.append(line); continue }

            if trimmed.isEmpty { flushParagraph(); continue }

            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph(); result.append(.divider); continue
            }
            if trimmed.hasPrefix("#") {
                let hashes = trimmed.prefix { $0 == "#" }.count
                let rest = trimmed.dropFirst(hashes)
                if hashes <= 6, rest.first == " " {
                    flushParagraph()
                    result.append(.heading(level: hashes, text: rest.trimmed))
                    continue
                }
            }
            if trimmed.hasPrefix("> ") || trimmed == ">" {
                flushParagraph()
                result.append(.quote(String(trimmed.dropFirst(1)).trimmed))
                continue
            }
            if let first = trimmed.first, "-+".contains(first), trimmed.dropFirst().first == " " {
                flushParagraph()
                result.append(.listItem(ordered: false, marker: "•", text: String(trimmed.dropFirst(2))))
                continue
            }
            // 「* 」开头的列表；注意 *动作描写* 不是列表
            if trimmed.hasPrefix("* "), !trimmed.dropFirst(2).contains("*") {
                flushParagraph()
                result.append(.listItem(ordered: false, marker: "•", text: String(trimmed.dropFirst(2))))
                continue
            }
            if let dot = trimmed.firstIndex(of: "."), dot != trimmed.startIndex,
               trimmed[..<dot].allSatisfy(\.isNumber), trimmed[trimmed.index(after: dot)...].first == " " {
                flushParagraph()
                result.append(.listItem(ordered: true, marker: String(trimmed[...dot]),
                                        text: String(trimmed[trimmed.index(dot, offsetBy: 2)...])))
                continue
            }
            paragraph.append(line)
        }
        if inCode {
            result.append(.code(language: codeLanguage, text: codeLines.joined(separator: "\n")))
        }
        flushParagraph()
        return result
    }
}


/// 消息里的少量 HTML：角色卡常让模型输出 <details> 状态栏、<p>、<br> 等。
/// 不做完整解析，只处理折叠段和去标签，代码块里的内容不动。
public enum HTMLLite {
    public enum Segment: Equatable {
        case text(String)
        case details(summary: String, body: String)
    }

    /// 拆出顶层的 <details> 段。没有闭合的 <details>（生成中或模型漏写）一直算到结尾。
    public static func split(_ text: String) -> [Segment] {
        var segments: [Segment] = []
        var rest = Substring(text)
        while let open = findTag("<details", in: rest) {
            guard let openEnd = rest[open.upperBound...].firstIndex(of: ">") else { break }
            let before = rest[..<open.lowerBound]
            if !before.isEmpty { segments.append(.text(String(before))) }
            let contentStart = rest.index(after: openEnd)
            var depth = 1
            var cursor = contentStart
            var contentEnd = rest.endIndex
            var afterClose = rest.endIndex
            while cursor < rest.endIndex {
                let nextOpen = findTag("<details", in: rest[cursor...])
                guard let nextClose = rest[cursor...].range(of: "</details", options: .caseInsensitive) else { break }
                if let nextOpen, nextOpen.lowerBound < nextClose.lowerBound {
                    depth += 1
                    cursor = nextOpen.upperBound
                    continue
                }
                depth -= 1
                let closeEnd = rest[nextClose.upperBound...].firstIndex(of: ">").map { rest.index(after: $0) } ?? nextClose.upperBound
                if depth == 0 {
                    contentEnd = nextClose.lowerBound
                    afterClose = closeEnd
                    break
                }
                cursor = closeEnd
            }
            let inner = rest[contentStart..<contentEnd]
            segments.append(splitSummary(inner))
            rest = rest[afterClose...]
        }
        if !rest.isEmpty { segments.append(.text(String(rest))) }
        return segments
    }

    private static func splitSummary(_ inner: Substring) -> Segment {
        guard let open = findTag("<summary", in: inner),
              let openEnd = inner[open.upperBound...].firstIndex(of: ">") else {
            return .details(summary: "", body: String(inner))
        }
        let summaryStart = inner.index(after: openEnd)
        guard let close = inner[summaryStart...].range(of: "</summary", options: .caseInsensitive) else {
            return .details(summary: "", body: String(inner))
        }
        let closeEnd = inner[close.upperBound...].firstIndex(of: ">").map { inner.index(after: $0) } ?? close.upperBound
        let body = String(inner[..<open.lowerBound]) + String(inner[closeEnd...])
        return .details(summary: String(inner[summaryStart..<close.lowerBound]), body: body)
    }

    /// 找 `<name` 后面紧跟 `>` 或空白的位置，避免把 <detailsXYZ> 之类当成标签。
    private static func findTag(_ name: String, in text: Substring) -> Range<Substring.Index>? {
        var searchStart = text.startIndex
        while let r = text[searchStart...].range(of: name, options: .caseInsensitive) {
            if r.upperBound == text.endIndex { return nil }
            let next = text[r.upperBound]
            if next == ">" || next == "/" || next.isWhitespace { return r }
            searchStart = r.upperBound
        }
        return nil
    }

    private static let lineBreak = try! NSRegularExpression(pattern: #"(?i)<br\s*/?>|</?p(\s[^<>]*)?>|</?div(\s[^<>]*)?>"#)
    private static let anyTag = try! NSRegularExpression(pattern: #"</?[A-Za-z][A-Za-z0-9_:-]*(\s[^<>]*)?/?>"#)
    private static let manyNewlines = try! NSRegularExpression(pattern: #"\n{3,}"#)

    /// 去掉 HTML 标签：<br>、<p>、<div> 换成换行，其余标签直接去掉，标签之间的文字保留。
    /// ``` 代码块里的内容不动；尖括号里不是英文标签名的（比如「<系统提示>」）也不动。
    public static func stripTags(_ text: String) -> String {
        guard text.contains("<") else { return text }
        let parts = text.components(separatedBy: "```")
        var out: [String] = []
        for (i, part) in parts.enumerated() {
            if i % 2 == 1 { out.append(part); continue }
            var s = part
            s = lineBreak.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "\n")
            s = anyTag.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
            s = manyNewlines.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "\n\n")
            out.append(s)
        }
        return out.joined(separator: "```")
    }
}
