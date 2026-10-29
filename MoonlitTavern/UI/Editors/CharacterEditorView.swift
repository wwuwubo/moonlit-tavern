import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import MoonlitCore

/// 角色编辑：字段与 Character Card V2/V3 一一对应，另有「背景」「说话风格」两项。
struct CharacterEditorView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var draft: TavernCharacter
    @State private var photoItem: PhotosPickerItem?
    @State private var pendingAvatar: Data?
    @State private var tagsText: String
    @State private var pendingExport: PendingExport?
    @State private var editingBook = false
    @State private var showAvatarFile = false

    private let isNew: Bool

    init(character: TavernCharacter) {
        _draft = State(initialValue: character)
        _tagsText = State(initialValue: character.tags.joined(separator: ", "))
        isNew = character.name.isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    header
                    SectionCard(title: "基本信息") {
                        TextField("名字（必填）", text: $draft.name)
                            .textFieldStyle(.moon)
                        TextField("昵称 / 显示名（可选）", text: $draft.nickname)
                            .textFieldStyle(.moon)
                        TextField("标签，用逗号分隔", text: $tagsText)
                            .textFieldStyle(.moon)
                        LabeledEditor(title: "人物简介 / 核心设定（description）", text: $draft.description,
                                      placeholder: "外貌、身份、处境……这是模型了解角色的主要依据", minHeight: 120)
                    }
                    SectionCard(title: "性格与表达") {
                        LabeledEditor(title: "性格（personality）", text: $draft.personality, placeholder: "例如：嘴硬心软、爱开玩笑")
                        LabeledEditor(title: "背景故事", text: $draft.background, placeholder: "过去发生过什么")
                        LabeledEditor(title: "说话风格", text: $draft.speakingStyle, placeholder: "口头禅、句子长短、称呼习惯")
                    }
                    SectionCard(title: "场景与开场") {
                        LabeledEditor(title: "场景（scenario）", text: $draft.scenario, placeholder: "故事从哪里开始")
                        LabeledEditor(title: "开场白（first message）", text: $draft.firstMessage, placeholder: "角色的第一句话", minHeight: 100)
                        ForEach(draft.alternateGreetings.indices, id: \.self) { i in
                            HStack(alignment: .top) {
                                LabeledEditor(title: "备选开场白 \(i + 1)", text: $draft.alternateGreetings[i])
                                Button(role: .destructive) {
                                    draft.alternateGreetings.remove(at: i)
                                } label: { Image(systemName: "minus.circle") }
                                .padding(.top, 24)
                            }
                        }
                        Button {
                            draft.alternateGreetings.append("")
                        } label: { Label("添加备选开场白", systemImage: "plus") }
                        .font(.caption)
                    }
                    SectionCard(title: "示例对话（example dialogue）", subtitle: "用 <START> 分隔多段；{{char}} 代表角色，{{user}} 代表你") {
                        LabeledEditor(title: "示例", text: $draft.exampleDialogue,
                                      placeholder: "<START>\n{{user}}: 你好\n{{char}}: ……", minHeight: 140)
                    }
                    SectionCard(title: "提示词（高级）", subtitle: "留空则使用全局系统提示词") {
                        LabeledEditor(title: "系统提示词（system prompt）", text: $draft.systemPrompt,
                                      placeholder: "可用 {{original}} 引用全局提示词")
                        LabeledEditor(title: "历史后指令（post-history instructions）", text: $draft.postHistoryInstructions,
                                      placeholder: "放在聊天记录之后，对模型影响最强")
                    }
                    SectionCard(title: "其他") {
                        LabeledEditor(title: "作者备注（creator notes，不发给模型）", text: $draft.creatorNotes, minHeight: 60)
                        TextField("作者", text: $draft.creator).textFieldStyle(.moon)
                        TextField("版本", text: $draft.characterVersion).textFieldStyle(.moon)
                        VStack(alignment: .leading) {
                            Text("群聊积极度 \(Int(draft.talkativeness * 100))%").font(.caption)
                            Slider(value: $draft.talkativeness, in: 0...1)
                        }
                    }
                    SectionCard(title: "角色自带世界书", subtitle: "随角色卡一起导入导出") {
                        if let book = draft.characterBook {
                            Text("\(book.name) · \(book.entries.count) 条").font(.subheadline)
                            HStack {
                                Button("编辑") { editingBook = true }.buttonStyle(.bordered)
                                Button("移除", role: .destructive) { draft.characterBook = nil }.buttonStyle(.bordered)
                            }
                        } else {
                            Button("创建") {
                                draft.characterBook = Lorebook(name: "\(draft.name.isEmpty ? "角色" : draft.name) 的世界书")
                                editingBook = true
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    if !isNew {
                        SectionCard(title: "导出") {
                            HStack {
                                Button { exportPNG() } label: { Label("PNG 角色卡", systemImage: "photo") }
                                    .buttonStyle(.bordered)
                                Button { exportJSON() } label: { Label("JSON（V2）", systemImage: "curlybraces") }
                                    .buttonStyle(.bordered)
                            }
                            Text("PNG 同时写入 V2 和 V3 数据，SillyTavern 等客户端可直接导入。")
                                .font(.caption)
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            .tavernBackground()
            .navigationTitle(isNew ? "新建角色" : "编辑角色")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.accessibilityIdentifier("editorCancel") }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(draft.name.isBlank)
                }
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        pendingAvatar = data
                    }
                }
            }
            .documentImporter(isPresented: $showAvatarFile, types: [.image]) { url in
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                pendingAvatar = try? Data(contentsOf: url)
            }
            .sheet(isPresented: $editingBook) {
                NavigationStack {
                    LorebookEditorView(book: Binding(
                        get: { draft.characterBook ?? Lorebook(name: "世界书") },
                        set: { draft.characterBook = $0 }
                    ), onSave: nil)
                }
            }
            .exporter($pendingExport) { result in
                if case .failure(let error) = result { state.show(.error, "导出失败：\(error.localizedDescription)") }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            AvatarView(name: draft.name.isEmpty ? "?" : draft.name,
                       imageData: pendingAvatar ?? state.avatarData(for: draft), size: 92)
            VStack(alignment: .leading, spacing: 8) {
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label("从相册选择头像", systemImage: "photo.on.rectangle")
                }
                Button { showAvatarFile = true } label: {
                    Label("从文件选择", systemImage: "folder")
                }
                if draft.isSample { SampleBadge() }
            }
            Spacer()
        }
    }

    private func save() {
        draft.name = draft.name.trimmed
        draft.tags = tagsText.split(whereSeparator: { ",，".contains($0) }).map { $0.trimmed }.filter { !$0.isEmpty }
        draft.alternateGreetings = draft.alternateGreetings.filter { !$0.isBlank }
        state.saveCharacter(draft)
        if let data = pendingAvatar {
            state.setAvatar(data, for: draft.id)
        }
        if isNew {
            state.newChat(characterIDs: [draft.id])
        }
        dismiss()
    }

    private func exportPNG() {
        do {
            let data = try state.exportCardPNG(draft)
            pendingExport = PendingExport(document: ExportDocument(data: data), contentType: .png, fileName: draft.name.safeFileName + ".png")
        } catch {
            state.show(.error, "导出失败：\(error.localizedDescription)")
        }
    }

    private func exportJSON() {
        do {
            let data = try state.exportCardJSON(draft)
            pendingExport = PendingExport(document: ExportDocument(data: data), contentType: .json, fileName: draft.name.safeFileName + ".json")
        } catch {
            state.show(.error, "导出失败：\(error.localizedDescription)")
        }
    }
}

/// 新建群聊：选择两个或更多角色。
struct GroupChatCreatorView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var selected: [UUID] = []
    @State private var title = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("群聊名称（可选）", text: $title)
                }
                Section("选择角色（按选择顺序决定默认发言顺序）") {
                    ForEach(state.characters) { c in
                        Button {
                            if let i = selected.firstIndex(of: c.id) { selected.remove(at: i) } else { selected.append(c.id) }
                        } label: {
                            HStack {
                                AvatarView(name: c.name, imageData: state.avatarData(for: c), size: 32)
                                Text(c.name).foregroundStyle(Theme.textPrimary)
                                if c.isSample { SampleBadge() }
                                Spacer()
                                if let i = selected.firstIndex(of: c.id) {
                                    Text("\(i + 1)")
                                        .font(.caption.weight(.bold))
                                        .frame(width: 22, height: 22)
                                        .background(Circle().fill(Theme.amber))
                                        .foregroundStyle(Theme.background)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("新建群聊")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("创建") {
                        state.newChat(characterIDs: selected, title: title.isBlank ? nil : title.trimmed)
                        dismiss()
                    }
                    .disabled(selected.count < 2)
                }
            }
        }
    }
}
