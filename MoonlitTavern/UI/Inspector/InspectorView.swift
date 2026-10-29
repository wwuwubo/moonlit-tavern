import SwiftUI
import MoonlitCore

/// 右侧面板：角色资料、世界书、长期记忆、生成参数、上下文用量。
struct InspectorView: View {
    @EnvironmentObject private var state: AppState
    let chatID: UUID

    enum Tab: String, CaseIterable, Identifiable {
        case character = "角色"
        case lore = "世界书"
        case memory = "记忆"
        case params = "参数"
        case context = "上下文"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .character

    var body: some View {
        VStack(spacing: 0) {
            Picker("面板", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(12)
            .accessibilityIdentifier("inspectorTabs")

            ScrollView {
                Group {
                    switch tab {
                    case .character: CharacterPanel(chatID: chatID)
                    case .lore: LorePanel(chatID: chatID)
                    case .memory: MemoryPanel(chatID: chatID)
                    case .params: ParamsPanel(chatID: chatID)
                    case .context: ContextPanel(chatID: chatID)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 24)
            }
        }
        .background(Theme.surface)
    }
}

// MARK: - 角色

private struct CharacterPanel: View {
    @EnvironmentObject private var state: AppState
    let chatID: UUID
    @State private var editing: TavernCharacter?

    var body: some View {
        let chat = state.chat(chatID)
        let participants = chat.map { state.participants(of: $0) } ?? []
        VStack(spacing: 12) {
            ForEach(participants) { c in
                SectionCard(title: c.name, subtitle: c.tags.isEmpty ? nil : c.tags.joined(separator: " · ")) {
                    HStack(alignment: .top, spacing: 12) {
                        AvatarView(name: c.name, imageData: state.avatarData(for: c), size: 64)
                        VStack(alignment: .leading, spacing: 6) {
                            if !c.personality.isBlank { infoLine("性格", c.personality) }
                            if !c.speakingStyle.isBlank { infoLine("说话风格", c.speakingStyle) }
                        }
                    }
                    if !c.description.isBlank {
                        Text(c.description)
                            .font(.callout)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(8)
                    }
                    HStack {
                        Button("编辑角色") { editing = c }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("editCharacterButton")
                        if c.isSample { SampleBadge() }
                        Spacer()
                        if let book = c.characterBook {
                            Pill(text: "自带世界书 \(book.entries.count) 条", systemImage: "book.closed")
                        }
                    }
                }
            }
            if let chat {
                PersonaCard(chat: chat)
                if chat.isGroup { TurnOrderCard(chat: chat) }
            }
        }
        .sheet(item: $editing) { CharacterEditorView(character: $0) }
    }

    private func infoLine(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(Theme.textTertiary)
            Text(text).font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(3)
        }
    }
}

private struct PersonaCard: View {
    @EnvironmentObject private var state: AppState
    let chat: ChatSession

    var body: some View {
        SectionCard(title: "我的身份", subtitle: chat.persona == nil ? "使用全局设置" : "此存档专用") {
            let persona = state.persona(for: chat)
            TextField("名字", text: Binding(
                get: { persona.name },
                set: { value in state.updateChat(chat.id) { $0.persona = UserPersona(name: value, description: persona.description) } }
            ))
            .textFieldStyle(.moon)
            TextField("身份描述（可选）", text: Binding(
                get: { persona.description },
                set: { value in state.updateChat(chat.id) { $0.persona = UserPersona(name: persona.name, description: value) } }
            ), axis: .vertical)
            .lineLimit(2...5)
            .textFieldStyle(.moon)
            if chat.persona != nil {
                Button("恢复为全局身份") { state.updateChat(chat.id) { $0.persona = nil } }
                    .font(.caption)
            }
        }
    }
}

private struct TurnOrderCard: View {
    @EnvironmentObject private var state: AppState
    let chat: ChatSession

    var body: some View {
        SectionCard(title: "群聊发言顺序", subtitle: "发送消息后由谁回应") {
            Picker("顺序", selection: Binding(
                get: { chat.turnOrder },
                set: { value in state.updateChat(chat.id) { $0.turnOrder = value } }
            )) {
                Text("自然（被点名者优先）").tag(TurnOrderStrategy.natural)
                Text("轮流").tag(TurnOrderStrategy.roundRobin)
                Text("按积极度随机").tag(TurnOrderStrategy.weightedRandom)
                Text("手动指定").tag(TurnOrderStrategy.manual)
            }
            .pickerStyle(.menu)
        }
    }
}

// MARK: - 世界书

private struct LorePanel: View {
    @EnvironmentObject private var state: AppState
    let chatID: UUID
    @State private var newStateKey = ""
    @State private var newStateValue = ""
    @State private var showLibrary = false

    var body: some View {
        let chat = state.chat(chatID)
        VStack(spacing: 12) {
            SectionCard(title: "本存档使用的世界书", subtitle: "角色自带的世界书会自动生效") {
                if state.lorebooks.isEmpty {
                    Text("还没有世界书").font(.caption).foregroundStyle(Theme.textSecondary)
                }
                ForEach(state.lorebooks) { book in
                    Toggle(isOn: Binding(
                        get: { chat?.lorebookIDs.contains(book.id) ?? false },
                        set: { on in
                            state.updateChat(chatID) { c in
                                if on { if !c.lorebookIDs.contains(book.id) { c.lorebookIDs.append(book.id) } }
                                else { c.lorebookIDs.removeAll { $0 == book.id } }
                            }
                        }
                    )) {
                        HStack {
                            Text(book.name).font(.subheadline)
                            if book.isSample { SampleBadge() }
                            Spacer()
                            Text("\(book.entries.count) 条").font(.caption).foregroundStyle(Theme.textTertiary)
                        }
                    }
                }
                Button("管理世界书") { showLibrary = true }
                    .font(.caption)
            }

            SectionCard(title: "剧情状态", subtitle: "可作为世界书的触发条件，也会写进提示词") {
                if let chat {
                    ForEach(chat.plotState.sorted(by: { $0.key < $1.key }), id: \.key) { pair in
                        let key = pair.key
                        let value = pair.value
                        HStack {
                            Text(key).font(.subheadline.weight(.medium))
                            Spacer()
                            TextField("值", text: Binding(
                                get: { value },
                                set: { v in state.updateChat(chatID) { $0.plotState[key] = v } }
                            ))
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 140)
                            Button(role: .destructive) {
                                state.updateChat(chatID) { $0.plotState[key] = nil }
                            } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.danger)
                        }
                    }
                }
                HStack {
                    TextField("名称，如 月相", text: $newStateKey).textFieldStyle(.moon)
                    TextField("值，如 满月", text: $newStateValue).textFieldStyle(.moon)
                    Button {
                        let k = newStateKey.trimmed
                        guard !k.isEmpty else { return }
                        state.updateChat(chatID) { $0.plotState[k] = newStateValue.trimmed }
                        newStateKey = ""; newStateValue = ""
                    } label: { Image(systemName: "plus.circle.fill") }
                }
            }

            SectionCard(title: "上一轮激活的条目", subtitle: "发送消息后更新") {
                if let plan = state.lastPlans[chatID] {
                    if plan.loreIncluded.isEmpty {
                        Text("没有条目被激活").font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                    ForEach(Array(plan.loreIncluded.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).font(.subheadline)
                                Text("\(item.book) · \(item.reason)").font(.caption2).foregroundStyle(Theme.textTertiary)
                            }
                            Spacer()
                            Text("\(item.tokens) tok").font(.caption.monospacedDigit()).foregroundStyle(Theme.textSecondary)
                        }
                    }
                    ForEach(Array(plan.loreDropped.enumerated()), id: \.offset) { _, item in
                        Text("未注入：\(item.title)（\(item.reason)）").font(.caption).foregroundStyle(Theme.amber)
                    }
                } else {
                    Button("预览当前会激活的条目") { Task { await state.previewPlan(chatID: chatID) } }
                        .font(.caption)
                }
            }

            if let chat {
                AuthorsNoteCard(chat: chat)
            }
        }
        .sheet(isPresented: $showLibrary) { NavigationStack { LorebookListView() } }
    }
}

private struct AuthorsNoteCard: View {
    @EnvironmentObject private var state: AppState
    let chat: ChatSession

    var body: some View {
        SectionCard(title: "作者注释", subtitle: "插在聊天记录靠后的位置，用来引导剧情走向") {
            Toggle("启用", isOn: Binding(
                get: { chat.authorsNote.enabled },
                set: { v in state.updateChat(chat.id) { $0.authorsNote.enabled = v } }
            ))
            TextField("例如：接下来让气氛逐渐紧张", text: Binding(
                get: { chat.authorsNote.text },
                set: { v in state.updateChat(chat.id) { $0.authorsNote.text = v } }
            ), axis: .vertical)
            .lineLimit(2...6)
            .textFieldStyle(.moon)
            Stepper("插入深度：倒数第 \(chat.authorsNote.depth) 条之前", value: Binding(
                get: { chat.authorsNote.depth },
                set: { v in state.updateChat(chat.id) { $0.authorsNote.depth = v } }
            ), in: 0...20)
            .font(.caption)
        }
    }
}

// MARK: - 记忆

private struct MemoryPanel: View {
    @EnvironmentObject private var state: AppState
    let chatID: UUID
    @State private var newKind: MemoryKind = .fact
    @State private var newText = ""
    @State private var editingItem: MemoryItem?

    var body: some View {
        let memory = state.memory(for: chatID)
        let used = Set(state.lastPlans[chatID]?.memoryIDs ?? [])
        VStack(spacing: 12) {
            SectionCard(title: "长期记忆", subtitle: "旧消息掉出上下文后，会自动整理成摘要、事件和关系") {
                HStack {
                    Button {
                        Task { await state.summarizeNow(chatID: chatID) }
                    } label: { Label("立即整理旧消息", systemImage: "wand.and.stars") }
                    .buttonStyle(.bordered)
                    .disabled(state.isGenerating)
                    Spacer()
                    Toggle("自动", isOn: $state.settings.memory.autoSummarize)
                        .fixedSize()
                }
                Text("已整理 \(memory.summarizedMessageIDs.count) 条消息 · 记忆 \(memory.items.count) 条")
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
            }

            ForEach(MemoryKind.allCases, id: \.self) { kind in
                let items = memory.items.filter { $0.kind == kind }
                if !items.isEmpty {
                    SectionCard(title: kind.rawValue) {
                        ForEach(items) { item in
                            memoryRow(item, used: used.contains(item.id))
                        }
                    }
                }
            }

            SectionCard(title: "手动添加") {
                Picker("类型", selection: $newKind) {
                    ForEach(MemoryKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                TextField("例如：旅人答应过艾琳，绝不在满月夜打开窗户", text: $newText, axis: .vertical)
                    .lineLimit(2...5)
                    .textFieldStyle(.moon)
                Button("添加") {
                    let text = newText.trimmed
                    guard !text.isEmpty else { return }
                    let index = state.chat(chatID)?.activePath().count ?? 0
                    state.updateMemory(chatID) {
                        $0.items.append(MemoryItem(kind: newKind, content: text, importance: 4, source: .manual, messageIndex: index))
                    }
                    newText = ""
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .sheet(item: $editingItem) { item in
            MemoryEditor(chatID: chatID, item: item)
        }
    }

    private func memoryRow(_ item: MemoryItem, used: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.promptLine)
                    .font(.callout)
                    .foregroundStyle(item.enabled ? Theme.textPrimary : Theme.textTertiary)
                HStack(spacing: 6) {
                    if item.pinned { Pill(text: "常驻", systemImage: "pin.fill") }
                    if used { Pill(text: "上轮已使用", tint: Theme.success) }
                    Text(item.source == .automatic ? "自动" : "手动").font(.caption2).foregroundStyle(Theme.textTertiary)
                    Text("重要度 \(item.importance)").font(.caption2).foregroundStyle(Theme.textTertiary)
                }
            }
            Spacer()
            Menu {
                Button("编辑") { editingItem = item }
                Button(item.pinned ? "取消常驻" : "设为常驻") {
                    state.updateMemory(chatID) { m in
                        if let i = m.items.firstIndex(where: { $0.id == item.id }) { m.items[i].pinned.toggle() }
                    }
                }
                Button(item.enabled ? "停用" : "启用") {
                    state.updateMemory(chatID) { m in
                        if let i = m.items.firstIndex(where: { $0.id == item.id }) { m.items[i].enabled.toggle() }
                    }
                }
                Button("删除", role: .destructive) {
                    state.updateMemory(chatID) { m in m.items.removeAll { $0.id == item.id } }
                }
            } label: {
                Image(systemName: "ellipsis.circle").foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct MemoryEditor: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let chatID: UUID
    @State var item: MemoryItem

    var body: some View {
        NavigationStack {
            Form {
                Picker("类型", selection: $item.kind) {
                    ForEach(MemoryKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                if item.kind == .relationship {
                    TextField("主体（如 艾琳）", text: $item.subject)
                    TextField("对象（如 旅人）", text: $item.object)
                }
                Section("内容") {
                    TextField("内容", text: $item.content, axis: .vertical).lineLimit(3...10)
                }
                Section("检索关键词（逗号分隔，可留空）") {
                    TextField("关键词", text: Binding(
                        get: { item.keywords.joined(separator: ", ") },
                        set: { item.keywords = $0.split(whereSeparator: { ",，".contains($0) }).map { $0.trimmed }.filter { !$0.isEmpty } }
                    ))
                }
                Stepper("重要度 \(item.importance)", value: $item.importance, in: 1...5)
                Toggle("常驻（每次都注入）", isOn: $item.pinned)
                Toggle("启用", isOn: $item.enabled)
            }
            .navigationTitle("编辑记忆")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        var updated = item
                        updated.updatedAt = Date()
                        state.updateMemory(chatID) { m in
                            if let i = m.items.firstIndex(where: { $0.id == updated.id }) { m.items[i] = updated }
                        }
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - 参数

private struct ParamsPanel: View {
    @EnvironmentObject private var state: AppState
    let chatID: UUID

    var body: some View {
        VStack(spacing: 12) {
            SectionCard(title: "回复长度") {
                Picker("长度", selection: $state.settings.replyLength) {
                    ForEach(ReplyLength.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                if state.settings.replyLength == .custom {
                    Stepper("最多 \(state.settings.sampling.maxNewTokens) token", value: $state.settings.sampling.maxNewTokens, in: 32...2048, step: 32)
                } else {
                    Text("最多 \(state.settings.effectiveMaxNewTokens) token").font(.caption).foregroundStyle(Theme.textTertiary)
                }
            }
            SectionCard(title: "采样", subtitle: "温度越高越有创意，也越容易跑题") {
                slider("温度 Temperature", value: $state.settings.sampling.temperature, range: 0...2, step: 0.05)
                slider("Top-P", value: $state.settings.sampling.topP, range: 0.05...1, step: 0.01)
                slider("Min-P", value: $state.settings.sampling.minP, range: 0...0.5, step: 0.01)
                Stepper("Top-K：\(state.settings.sampling.topK)", value: $state.settings.sampling.topK, in: 0...200, step: 5)
                slider("重复惩罚", value: $state.settings.sampling.repeatPenalty, range: 1...1.5, step: 0.01)
                slider("存在惩罚 Presence", value: $state.settings.sampling.presencePenalty, range: 0...2, step: 0.05)
                Button("恢复默认") { state.settings.sampling = SamplingParams() }
                    .font(.caption)
            }
            SectionCard(title: "剧情选项", subtitle: "角色回复后，替你想几个下一步的选择") {
                Toggle("回复后自动给出选项", isOn: $state.settings.suggestions.enabled)
                Stepper("每次 \(state.settings.suggestions.count) 个", value: $state.settings.suggestions.count, in: 2...4)
                Text("关掉自动生成后，仍可在回复下方点「给我几个选项」。本地模型每次多花几秒，云端模式会多一次请求。")
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
            SectionCard(title: "提示词") {
                Toggle("放入示例对话（有剩余空间时）", isOn: $state.settings.includeExampleDialogue)
                Stepper("世界书预算 \(state.settings.loreTokenBudget) token", value: $state.settings.loreTokenBudget, in: 100...4000, step: 100)
                Stepper("记忆预算 \(state.settings.memory.tokenBudget) token", value: $state.settings.memory.tokenBudget, in: 100...3000, step: 100)
            }
        }
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                Text(String(format: "%.2f", value.wrappedValue)).font(.caption.monospacedDigit()).foregroundStyle(Theme.textSecondary)
            }
            Slider(value: value, in: range, step: step)
        }
    }
}

// MARK: - 上下文

private struct ContextPanel: View {
    @EnvironmentObject private var state: AppState
    let chatID: UUID
    @State private var showPrompt = false

    var body: some View {
        VStack(spacing: 12) {
            if let plan = state.lastPlans[chatID] {
                let r = plan.report
                SectionCard(title: "上下文用量", subtitle: "\(plan.engine) · 共 \(r.contextLength) token") {
                    UsageBar(report: r)
                    Group {
                        row("系统与角色设定", r.systemTokens)
                        row("世界书", r.loreTokens)
                        row("长期记忆", r.memoryTokens)
                        row("示例对话（\(r.exampleBlocksIncluded)/\(r.exampleBlocksTotal) 段）", r.exampleTokens)
                        row("深度注入（作者注释等）", r.injectionTokens)
                        row("聊天记录（\(r.includedHistoryCount) 条）", r.historyTokens)
                        row("预留给回复", r.reservedForReply)
                    }
                    if r.truncatedHistoryCount > 0 {
                        Text("最早的 \(r.truncatedHistoryCount) 条消息已移出上下文，由长期记忆接替。")
                            .font(.caption)
                            .foregroundStyle(Theme.amber)
                    }
                    if r.overflow {
                        Text("固定设定已超出可用空间。").font(.caption).foregroundStyle(Theme.danger)
                    }
                }
                Button {
                    showPrompt = true
                } label: { Label("查看完整提示词", systemImage: "text.alignleft") }
                .buttonStyle(.bordered)
                .sheet(isPresented: $showPrompt) { PromptPreviewView(plan: plan) }
            } else {
                Text("还没有组装过提示词。").foregroundStyle(Theme.textSecondary)
            }
            Button {
                Task { await state.previewPlan(chatID: chatID) }
            } label: { Label("重新计算", systemImage: "arrow.triangle.2.circlepath") }
            .font(.caption)
        }
        .task { if state.lastPlans[chatID] == nil { await state.previewPlan(chatID: chatID) } }
    }

    private func row(_ title: String, _ tokens: Int) -> some View {
        HStack {
            Text(title).font(.caption)
            Spacer()
            Text("\(tokens)").font(.caption.monospacedDigit()).foregroundStyle(Theme.textSecondary)
        }
    }
}

private struct UsageBar: View {
    let report: PromptReport

    var body: some View {
        let total = max(Double(report.contextLength), 1)
        let parts: [(Double, Color)] = [
            (Double(report.systemTokens), Theme.moon),
            (Double(report.loreTokens), Theme.amber),
            (Double(report.memoryTokens), Theme.success),
            (Double(report.exampleTokens + report.injectionTokens), Color.purple.opacity(0.7)),
            (Double(report.historyTokens), Color.blue.opacity(0.7)),
            (Double(report.reservedForReply), Color.white.opacity(0.25))
        ]
        GeometryReader { geo in
            HStack(spacing: 1) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    Rectangle().fill(part.1).frame(width: max(0, geo.size.width * part.0 / total))
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: 10)
        .clipShape(Capsule())
        .background(Capsule().fill(Theme.surface))
    }
}

struct PromptPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    let plan: PlanSnapshot

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(plan.promptPreview.enumerated()), id: \.offset) { _, m in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(m.role.rawValue.uppercased())
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(Theme.amber)
                            Text(m.content)
                                .font(.system(.footnote, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                    if !plan.prefill.isEmpty {
                        Text("ASSISTANT（预填）：\(plan.prefill)")
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .padding()
            }
            .tavernBackground()
            .navigationTitle("完整提示词")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}
