import SwiftUI
import MoonlitCore

struct ChatView: View {
    @EnvironmentObject private var state: AppState
    let chatID: UUID
    @Binding var showInspector: Bool

    @State private var draft = ""
    @State private var editing: ChatMessage?
    @State private var editText = ""
    @FocusState private var composerFocused: Bool

    private var chat: ChatSession? { state.chat(chatID) }

    var body: some View {
        if let chat {
            let path = chat.activePath()
            VStack(spacing: 0) {
                messageList(chat: chat, path: path)
                Divider().overlay(Theme.hairline)
                composer(chat: chat)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle(chat.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar(chat: chat) }
            .sheet(item: $editing) { message in
                editSheet(message)
            }
        }
    }

    // MARK: - 消息列表

    private func messageList(chat: ChatSession, path: [ChatMessage]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if let first = state.participants(of: chat).first, path.count <= 1 {
                        ChatIntroCard(character: first, chat: chat)
                    }
                    ForEach(path) { message in
                        MessageRow(
                            chat: chat,
                            message: message,
                            isLast: message.id == path.last?.id,
                            onEdit: {
                                editText = message.content
                                editing = message
                            }
                        )
                        .id(message.id)
                    }
                    if let last = path.last, last.role == .assistant {
                        actionChoices(for: last)
                            .id("action-choices")
                    }
                    if let generation = state.generation, generation.chatID == chatID {
                        StreamingBubble(generation: generation)
                            .id("streaming")
                    }
                    Color.clear.frame(height: 4).id("bottom")
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: path.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: state.generation?.text.count ?? 0) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: state.suggestedActions[chatID]?.count ?? 0) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    @ViewBuilder
    private func actionChoices(for last: ChatMessage) -> some View {
        let actions = state.suggestedActionSourceIDs[chatID] == last.id
            ? (state.suggestedActions[chatID] ?? []) : []
        let loading = state.actionsLoadingChatID == chatID
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("下一步行动").font(.caption.weight(.semibold))
                if loading {
                    ProgressView().controlSize(.mini)
                    Text("生成选项中…").font(.caption2)
                }
                Spacer()
                Button {
                    state.refreshSuggestedActions(in: chatID)
                } label: {
                    Label(actions.isEmpty ? "生成选项" : "换一组", systemImage: "arrow.clockwise")
                        .font(.caption)
                }
                .disabled(state.isGenerating || loading)
                .accessibilityIdentifier("refreshActionChoices")
                Button {
                    composerFocused = true
                } label: {
                    Label("自由输入", systemImage: "pencil")
                        .font(.caption)
                }
                .accessibilityIdentifier("manualActionInput")
            }
            .foregroundStyle(Theme.textSecondary)
            ForEach(actions, id: \.self) { option in
                Button {
                    state.sendUserMessage(option, in: chatID)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.turn.down.right")
                        Text(option).multilineTextAlignment(.leading)
                        Spacer(minLength: 4)
                    }
                    .font(.subheadline)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surfaceRaised))
                }
                .buttonStyle(.plain)
                .disabled(state.isGenerating)
                .accessibilityIdentifier("actionChoice")
            }
        }
        .padding(12)
        .frame(maxWidth: 680, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).stroke(Theme.hairline))
        .accessibilityIdentifier("actionChoicesPanel")
    }

    // MARK: - 输入区

    private func composer(chat: ChatSession) -> some View {
        VStack(spacing: 8) {
            if chat.isGroup {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Text("让谁发言")
                            .font(.caption)
                            .foregroundStyle(Theme.textTertiary)
                        ForEach(state.participants(of: chat)) { c in
                            Button {
                                state.generateReply(chatID: chatID, speakerID: c.id)
                            } label: {
                                HStack(spacing: 6) {
                                    AvatarView(name: c.name, imageData: state.avatarData(for: c), size: 20, ring: false)
                                    Text(c.name).font(.caption.weight(.medium))
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Capsule().fill(Theme.surfaceRaised))
                            }
                            .buttonStyle(.plain)
                            .disabled(state.isGenerating)
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField("以 \(state.persona(for: chat).name) 的身份说点什么…", text: $draft, axis: .vertical)
                    .lineLimit(1...8)
                    .focused($composerFocused)
                    .accessibilityIdentifier("composer")
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.surfaceRaised))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.hairline))

                if state.generation?.chatID == chatID || (state.isGenerating && state.generation?.chatID == nil) {
                    Button {
                        state.stopGeneration()
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 16, weight: .bold))
                            .frame(width: 42, height: 42)
                            .background(Circle().fill(Theme.danger.opacity(0.85)))
                            .foregroundStyle(.white)
                    }
                    .keyboardShortcut(".", modifiers: .command)
                    .accessibilityLabel("停止生成")
                    .accessibilityIdentifier("stopButton")
                } else {
                    Button {
                        send(chat: chat)
                    } label: {
                        Image(systemName: draft.isBlank ? "sparkles" : "arrow.up")
                            .font(.system(size: 17, weight: .bold))
                            .frame(width: 42, height: 42)
                            .background(Circle().fill(Theme.amber))
                            .foregroundStyle(Theme.background)
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(state.isGenerating)
                    .accessibilityLabel(draft.isBlank ? "让角色继续" : "发送")
                    .accessibilityIdentifier("sendButton")
                }
            }
            StatsLine()
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .frame(maxWidth: 900)
        .frame(maxWidth: .infinity)
        .background(Theme.surface.opacity(0.6))
    }

    private func send(chat: ChatSession) {
        let text = draft
        if text.isBlank {
            // 空输入：让角色继续说（群聊按顺序选人）
            state.generateReply(chatID: chatID)
        } else {
            draft = ""
            state.sendUserMessage(text, in: chatID)
        }
    }

    // MARK: - 工具栏

    @ToolbarContentBuilder
    private func toolbar(chat: ChatSession) -> some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            EngineChip()
            Button {
                withAnimation { showInspector.toggle() }
            } label: {
                Image(systemName: "sidebar.right")
            }
            .accessibilityLabel("角色与设定面板")
            .accessibilityIdentifier("inspectorToggle")
        }
    }

    // MARK: - 编辑

    private func editSheet(_ message: ChatMessage) -> some View {
        NavigationStack {
            TextEditor(text: $editText)
                .scrollContentBackground(.hidden)
                .padding()
                .tavernBackground()
                .navigationTitle("编辑消息")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { editing = nil }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") {
                            state.editMessage(message.id, in: chatID, content: editText)
                            editing = nil
                        }
                    }
                }
        }
        .presentationDetents([.medium, .large])
    }
}

/// 单条消息。
struct MessageRow: View {
    @EnvironmentObject private var state: AppState
    let chat: ChatSession
    let message: ChatMessage
    let isLast: Bool
    let onEdit: () -> Void

    var body: some View {
        let isUser = message.role == .user
        let character = state.character(message.speakerID)
        let position = chat.siblingPosition(of: message.id)

        HStack(alignment: .top, spacing: 12) {
            if isUser {
                Spacer(minLength: 60)
            } else {
                AvatarView(name: message.speakerName, imageData: state.avatarData(for: character), size: 38)
            }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(message.speakerName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isUser ? Theme.amber : Theme.moon)
                    if message.isHidden {
                        Label("不进入上下文", systemImage: "eye.slash")
                            .font(.caption2)
                            .foregroundStyle(Theme.textTertiary)
                    }
                    if message.editedAt != nil {
                        Text("已编辑").font(.caption2).foregroundStyle(Theme.textTertiary)
                    }
                }
                MessageContentView(text: message.content, isUser: isUser)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("message-\(message.role.rawValue)")
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(isUser ? Theme.userBubble : Theme.characterBubble)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(isUser ? Theme.amber.opacity(0.18) : Theme.hairline)
                    )
                    .opacity(message.isHidden ? 0.5 : 1)

                HStack(spacing: 12) {
                    if position.count > 1 {
                        HStack(spacing: 4) {
                            Button { state.switchSibling(message.id, in: chat.id, offset: -1) } label: {
                                Image(systemName: "chevron.left")
                            }
                            .disabled(position.index <= 1 || state.isGenerating)
                            Text("\(position.index)/\(position.count)")
                                .font(.caption.monospacedDigit())
                            Button { state.switchSibling(message.id, in: chat.id, offset: 1) } label: {
                                Image(systemName: "chevron.right")
                            }
                            .disabled(position.index >= position.count || state.isGenerating)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.textSecondary)
                    }
                    if !isUser, isLast {
                        Button {
                            state.regenerate(messageID: message.id, in: chat.id)
                        } label: {
                            Label("重新生成", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.textSecondary)
                        .disabled(state.isGenerating)
                    }
                    if let stats = message.stats, stats.generatedTokens > 0 {
                        Text(statsText(stats))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                .font(.caption)
            }
            if !isUser { Spacer(minLength: 40) }
        }
        .contextMenu { menu(isUser: isUser) }
    }

    private func statsText(_ s: GenerationStats) -> String {
        if s.generationTokensPerSecond > 0 {
            return String(format: "%d tok · %.1f tok/s", s.generatedTokens, s.generationTokensPerSecond)
        }
        return "\(s.generatedTokens) tok"
    }

    @ViewBuilder
    private func menu(isUser: Bool) -> some View {
        Button {
            UIPasteboard.general.string = message.content
        } label: { Label("复制", systemImage: "doc.on.doc") }
        Button(action: onEdit) { Label("编辑", systemImage: "pencil") }
        if !isUser {
            Button {
                state.regenerate(messageID: message.id, in: chat.id)
            } label: { Label("重新生成（保留旧版本）", systemImage: "arrow.clockwise") }
            .disabled(state.isGenerating)
        }
        Button {
            state.forkChat(chat.id, at: message.id)
        } label: { Label("从这里分出新存档", systemImage: "arrow.triangle.branch") }
        Button {
            state.toggleHidden(message.id, in: chat.id)
        } label: {
            Label(message.isHidden ? "重新加入上下文" : "不让模型看到这条", systemImage: message.isHidden ? "eye" : "eye.slash")
        }
        Divider()
        Button(role: .destructive) {
            state.deleteMessage(message.id, in: chat.id)
        } label: { Label("删除（含之后的消息）", systemImage: "trash") }
        .disabled(state.isGenerating)
    }
}

/// 正在生成的回复。
struct StreamingBubble: View {
    @EnvironmentObject private var state: AppState
    let generation: GenerationState

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AvatarView(name: generation.speakerName, imageData: state.avatarData(for: state.character(generation.speakerID)), size: 38)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(generation.speakerName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.moon)
                    PhaseLabel(generation: generation)
                }
                Group {
                    if generation.text.isEmpty {
                        TypingDots()
                    } else if generation.purpose == .reply {
                        MessageContentView(text: generation.text + " ▍")
                    } else {
                        Text(generation.text).font(.footnote).foregroundStyle(Theme.textSecondary)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.characterBubble))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.amber.opacity(0.25)))
            }
            Spacer(minLength: 40)
        }
    }
}

struct PhaseLabel: View {
    let generation: GenerationState

    var body: some View {
        HStack(spacing: 4) {
            ProgressView().controlSize(.mini)
            if let p = generation.progress, generation.phase == .processingPrompt || generation.phase == .loadingModel {
                Text("\(generation.phase.rawValue) \(Int(p * 100))%")
            } else {
                Text(generation.purpose == .summary ? "正在整理记忆" : generation.phase.rawValue)
            }
        }
        .font(.caption2)
        .foregroundStyle(Theme.amber)
    }
}

struct TypingDots: View {
    @State private var phase = 0.0

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(Theme.moon.opacity(0.7))
                    .frame(width: 6, height: 6)
                    .opacity(0.35 + 0.65 * abs(sin(phase + Double(i) * 0.6)))
            }
        }
        .frame(height: 18)
        .onAppear {
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { phase = .pi }
        }
    }
}

/// 输入框下方的一行统计：全部来自最近一次真实生成。
struct StatsLine: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack(spacing: 14) {
            if let s = state.lastStats {
                Text(String(format: "首 token %.2f 秒", s.timeToFirstToken))
                if s.promptTokensPerSecond > 0, s.promptTokensEvaluated > 0 {
                    Text(String(format: "读取 %.0f tok/s", s.promptTokensPerSecond))
                }
                if s.generationTokensPerSecond > 0 {
                    Text(String(format: "生成 %.1f tok/s", s.generationTokensPerSecond))
                }
                if s.contextLength > 0 {
                    Text("上下文 \(s.promptTokens + s.generatedTokens)/\(s.contextLength)")
                }
                if let mem = s.peakMemoryMB {
                    Text(String(format: "内存 %.0f MB", mem))
                }
            } else {
                Text("⌘ Return 发送 · ⌘ . 停止 · 空输入时让角色继续")
            }
            Spacer()
            if state.thermalLabel != "正常" {
                Label(state.thermalLabel, systemImage: "thermometer.medium")
                    .foregroundStyle(Theme.amber)
            }
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(Theme.textTertiary)
        .lineLimit(1)
    }
}

/// 工具栏上的引擎标记：本地（离线）或云端。
struct EngineChip: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        if state.settings.providerMode == .local {
            Pill(text: state.modelState.isLoaded ? "本地 · 离线" : "本地", systemImage: "lock.shield", tint: Theme.success)
        } else {
            Pill(text: "云端", systemImage: "cloud", tint: Theme.amber)
        }
    }
}

/// 存档开头的角色卡片：场景与简介。
struct ChatIntroCard: View {
    @EnvironmentObject private var state: AppState
    let character: TavernCharacter
    let chat: ChatSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                AvatarView(name: character.name, imageData: state.avatarData(for: character), size: 54)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(chat.isGroup ? state.participants(of: chat).map(\.name).joined(separator: " · ") : character.name)
                            .font(Theme.titleFont(20))
                            .foregroundStyle(Theme.textPrimary)
                        if character.isSample || chat.isSample { SampleBadge() }
                    }
                    if !character.creatorNotes.isBlank {
                        Text(character.creatorNotes)
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(2)
                    }
                }
            }
            if !character.scenario.isBlank {
                Text(MacroContext(characterName: character.name, userName: state.persona(for: chat).name).expand(character.scenario))
                    .font(.callout)
                    .italic()
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.amberSoft))
    }
}
