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
}

public enum MarkdownParser {
    public static func blocks(_ text: String) -> [MarkdownBlock] {
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
