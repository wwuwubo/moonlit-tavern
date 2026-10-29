import SwiftUI
import MoonlitCore

/// 消息正文渲染：基础 Markdown + 角色扮演习惯（*动作* 斜体淡色，“对白”烛光色）。
struct MessageContentView: View {
    let text: String
    var isUser = false

    var body: some View {
        MarkdownBlocksView(blocks: MarkdownParser.blocks(text))
            .textSelection(.enabled)
    }

    static func styled(_ source: String) -> AttributedString {
        MarkdownBlocksView.styled(source)
    }
}

/// 一组 Markdown 块。折叠段（状态栏等）里再套一组，所以单独成一个视图类型，可以递归。
struct MarkdownBlocksView: View {
    let blocks: [MarkdownBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let s):
            Text(Self.styled(s))
                .fixedSize(horizontal: false, vertical: true)
        case .heading(let level, let s):
            Text(Self.styled(s))
                .font(level <= 2 ? Theme.titleFont(19) : .headline)
        case .listItem(_, let marker, let s):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker).foregroundStyle(Theme.amber)
                Text(Self.styled(s)).fixedSize(horizontal: false, vertical: true)
            }
        case .quote(let s):
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1).fill(Theme.amber.opacity(0.6)).frame(width: 3)
                Text(Self.styled(s)).foregroundStyle(Theme.textSecondary)
            }
        case .code(_, let s):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(s)
                    .font(.system(.footnote, design: .monospaced))
                    .padding(10)
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.35)))
        case .divider:
            Divider().overlay(Theme.hairline)
        case .details(let summary, let inner):
            DisclosureGroup {
                MarkdownBlocksView(blocks: inner)
                    .padding(.top, 6)
            } label: {
                Text(summary)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Theme.amber)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.22)))
        }
    }

    /// 行内样式。
    static func styled(_ source: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        var attributed = (try? AttributedString(markdown: source, options: options)) ?? AttributedString(source)
        attributed.foregroundColor = Theme.textPrimary

        // *动作描写*：斜体，月光色
        for run in attributed.runs {
            if let intent = run.inlinePresentationIntent, intent.contains(.emphasized) {
                attributed[run.range].foregroundColor = Theme.moon.opacity(0.78)
            }
        }
        // 对白高亮：“…” 「…」 "…"
        let plain = String(attributed.characters)
        let pairs: [(Character, Character)] = [("“", "”"), ("「", "」"), ("\"", "\"")]
        for (open, close) in pairs {
            var searchStart = plain.startIndex
            while let o = plain[searchStart...].firstIndex(of: open) {
                let afterOpen = plain.index(after: o)
                guard afterOpen < plain.endIndex, let c = plain[afterOpen...].firstIndex(of: close) else { break }
                let lower = plain.distance(from: plain.startIndex, to: o)
                let upper = plain.distance(from: plain.startIndex, to: c) + 1
                let start = attributed.characters.index(attributed.startIndex, offsetBy: lower)
                let end = attributed.characters.index(attributed.startIndex, offsetBy: upper)
                attributed[start..<end].foregroundColor = Color(red: 0.95, green: 0.82, blue: 0.62)
                searchStart = plain.index(after: c)
                if searchStart >= plain.endIndex { break }
            }
        }
        return attributed
    }
}
