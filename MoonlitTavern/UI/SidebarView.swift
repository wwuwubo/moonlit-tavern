import SwiftUI
import UniformTypeIdentifiers
import MoonlitCore

struct SidebarView: View {
    @EnvironmentObject private var state: AppState
    @Binding var showSettings: Bool

    @State private var editingCharacter: TavernCharacter?
    @State private var showCardImporter = false
    @State private var showGroupCreator = false
    @State private var showLorebooks = false
    @State private var search = ""
    @State private var renamingChat: ChatSession?
    @State private var renameText = ""
    @State private var pendingDelete: TavernCharacter?

    private var filteredCharacters: [TavernCharacter] {
        let q = search.trimmed
        guard !q.isEmpty else { return state.characters }
        return state.characters.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.tags.contains { $0.localizedCaseInsensitiveContains(q) } }
    }

    var body: some View {
        List(selection: Binding(get: { state.selectedChatID }, set: { state.selectedChatID = $0 })) {
            Section {
                ModelStatusRow()
                    .listRowBackground(Color.clear)
            }

            if !state.groupChats.isEmpty {
                Section("群聊") {
                    ForEach(state.groupChats) { chat in
                        ChatRow(chat: chat)
                            .tag(chat.id)
                            .contextMenu { chatMenu(chat) }
                    }
                }
            }

            Section("角色") {
                ForEach(filteredCharacters) { character in
                    CharacterSection(
                        character: character,
                        onEdit: { editingCharacter = character },
                        onDelete: { pendingDelete = character },
                        chatMenu: { AnyView(chatMenu($0)) }
                    )
                }
                if state.characters.isEmpty {
                    Text("还没有角色。点右上角「+」新建或导入角色卡。")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Theme.surface)
        .searchable(text: $search, prompt: "搜索角色或标签")
        .navigationTitle("月下酒馆")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("设置")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { editingCharacter = TavernCharacter(name: "") } label: {
                        Label("新建角色", systemImage: "person.badge.plus")
                    }
                    Button { showCardImporter = true } label: {
                        Label("导入角色卡（PNG / JSON）", systemImage: "square.and.arrow.down")
                    }
                    Button { showGroupCreator = true } label: {
                        Label("新建群聊", systemImage: "person.3")
                    }
                    Divider()
                    Button { showLorebooks = true } label: {
                        Label("世界书", systemImage: "book.closed")
                    }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .fileImporter(isPresented: $showCardImporter, allowedContentTypes: [.png, .json, .image, .data], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                for url in urls { state.importCharacterCard(from: url) }
            }
        }
        .sheet(item: $editingCharacter) { character in
            CharacterEditorView(character: character)
        }
        .sheet(isPresented: $showGroupCreator) {
            GroupChatCreatorView()
        }
        .sheet(isPresented: $showLorebooks) {
            NavigationStack { LorebookListView() }
        }
        .alert("重命名存档", isPresented: Binding(get: { renamingChat != nil }, set: { if !$0 { renamingChat = nil } })) {
            TextField("存档名称", text: $renameText)
            Button("取消", role: .cancel) { renamingChat = nil }
            Button("保存") {
                if let chat = renamingChat {
                    state.updateChat(chat.id) { $0.title = renameText.trimmed.isEmpty ? chat.title : renameText.trimmed }
                }
                renamingChat = nil
            }
        }
        .confirmationDialog(
            "删除角色「\(pendingDelete?.name ?? "")」？",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("删除角色及其单人存档", role: .destructive) {
                if let c = pendingDelete { state.deleteCharacter(c) }
                pendingDelete = nil
            }
        } message: {
            Text("群聊存档会保留，只移除这个角色。此操作无法撤销，建议先在设置里备份。")
        }
    }

    @ViewBuilder
    private func chatMenu(_ chat: ChatSession) -> some View {
        Button {
            renameText = chat.title
            renamingChat = chat
        } label: { Label("重命名", systemImage: "pencil") }
        Button(role: .destructive) {
            state.deleteChat(chat.id)
        } label: { Label("删除存档", systemImage: "trash") }
    }
}

/// 一个角色及其存档。点角色行会打开最近的存档（没有就新建）。
private struct CharacterSection: View {
    @EnvironmentObject private var state: AppState
    let character: TavernCharacter
    let onEdit: () -> Void
    let onDelete: () -> Void
    let chatMenu: (ChatSession) -> AnyView

    @State private var expanded = true

    var body: some View {
        let chats = state.chats(for: character)
        DisclosureGroup(isExpanded: $expanded) {
            ForEach(chats) { chat in
                ChatRow(chat: chat, compact: true)
                    .tag(chat.id)
                    .contextMenu { chatMenu(chat) }
            }
            Button {
                state.newChat(characterIDs: [character.id])
            } label: {
                Label("新存档", systemImage: "plus.bubble")
                    .font(.footnote)
            }
            .foregroundStyle(Theme.amber)
        } label: {
            HStack(spacing: 10) {
                AvatarView(name: character.name, imageData: state.avatarData(for: character), size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(character.displayName)
                            .font(.body.weight(.medium))
                            .foregroundStyle(Theme.textPrimary)
                        if character.isSample { SampleBadge() }
                    }
                    if !character.tags.isEmpty {
                        Text(character.tags.prefix(3).joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if let latest = chats.first {
                    state.selectedChatID = latest.id
                } else {
                    state.newChat(characterIDs: [character.id])
                }
            }
            .contextMenu {
                Button(action: onEdit) { Label("编辑角色", systemImage: "pencil") }
                Button { state.newChat(characterIDs: [character.id]) } label: { Label("新存档", systemImage: "plus.bubble") }
                Button(role: .destructive, action: onDelete) { Label("删除角色", systemImage: "trash") }
            }
        }
    }
}

struct ChatRow: View {
    @EnvironmentObject private var state: AppState
    let chat: ChatSession
    var compact = false

    var body: some View {
        HStack(spacing: 10) {
            if !compact {
                ZStack {
                    ForEach(Array(state.participants(of: chat).prefix(3).enumerated()), id: \.offset) { index, c in
                        AvatarView(name: c.name, imageData: state.avatarData(for: c), size: 26)
                            .offset(x: CGFloat(index) * 10)
                    }
                }
                .frame(width: 50, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(chat.title)
                        .font(compact ? .subheadline : .body)
                        .lineLimit(1)
                        .foregroundStyle(Theme.textPrimary)
                    if chat.isSample { SampleBadge() }
                }
                if let last = chat.activePath().last {
                    Text(last.content.replacingOccurrences(of: "\n", with: " "))
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// 侧栏顶部的模型状态。
struct ModelStatusRow: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: state.settings.providerMode == .local ? "cpu" : "cloud")
                .foregroundStyle(Theme.amber)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            if case .loading(let p) = state.modelState {
                ProgressView(value: p).frame(width: 44)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surfaceRaised))
    }

    private var title: String {
        if state.settings.providerMode == .cloud {
            return state.settings.cloud.model.isBlank ? "云端模式（未配置）" : state.settings.cloud.model
        }
        return state.settings.local.selectedModelFile ?? "未选择本地模型"
    }

    private var subtitle: String {
        if state.settings.providerMode == .cloud { return "云端 · 聊天内容会发送到所配置的服务" }
        switch state.modelState {
        case .unloaded: return "离线 · 未加载（发送消息时自动加载）"
        case .loading: return "正在加载…"
        case .loaded(let info): return "离线 · 已加载 · 上下文 \(info.contextLength)"
        case .failed(let message): return "加载失败：\(message)"
        }
    }
}
