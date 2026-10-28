import SwiftUI
import UniformTypeIdentifiers
import MoonlitCore

/// 世界书列表：新建、导入（SillyTavern 世界书 / V2 character_book / 角色卡 PNG）、导出、删除。
struct LorebookListView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var showImporter = false
    @State private var pendingExport: PendingExport?

    var body: some View {
        List {
            ForEach(state.lorebooks) { book in
                NavigationLink {
                    LorebookEditorView(book: Binding(
                        get: { state.lorebooks.first { $0.id == book.id } ?? book },
                        set: { state.saveLorebook($0) }
                    ), onSave: nil)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(book.name)
                                if book.isSample { SampleBadge() }
                            }
                            Text("\(book.entries.count) 条 · 扫描深度 \(book.scanDepth)")
                                .font(.caption)
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }
                }
                .contextMenu {
                    Button { export(book) } label: { Label("导出为 SillyTavern 世界书", systemImage: "square.and.arrow.up") }
                    Button(role: .destructive) { state.deleteLorebook(book.id) } label: { Label("删除", systemImage: "trash") }
                }
            }
            .onDelete { offsets in
                let ids = offsets.map { state.lorebooks[$0].id }
                ids.forEach { state.deleteLorebook($0) }
            }
        }
        .navigationTitle("世界书")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { showImporter = true } label: { Image(systemName: "square.and.arrow.down") }
                    .accessibilityLabel("导入世界书")
                Button {
                    state.saveLorebook(Lorebook(name: "新世界书"))
                } label: { Image(systemName: "plus") }
                    .accessibilityLabel("新建世界书")
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json, .png, .data]) { result in
            if case .success(let url) = result { state.importLorebook(from: url) }
        }
        .exporter($pendingExport) { result in
            if case .failure(let error) = result { state.show(.error, "导出失败：\(error.localizedDescription)") }
        }
    }

    private func export(_ book: Lorebook) {
        do {
            let data = try WorldInfoFormats.sillyTavernWorldData(book)
            pendingExport = PendingExport(document: ExportDocument(data: data), contentType: .json, fileName: book.name.safeFileName + ".json")
        } catch {
            state.show(.error, "导出失败：\(error.localizedDescription)")
        }
    }
}

struct LorebookEditorView: View {
    @Binding var book: Lorebook
    var onSave: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var editingEntry: LoreEntry?
    @State private var filter: LoreCategory?

    var body: some View {
        List {
            Section("基本设置") {
                TextField("名称", text: $book.name)
                TextField("说明", text: $book.description, axis: .vertical)
                Stepper("扫描最近 \(book.scanDepth) 条消息", value: $book.scanDepth, in: 1...50)
                Stepper(book.tokenBudget == 0 ? "预算：使用全局设置" : "预算：\(book.tokenBudget) token",
                        value: $book.tokenBudget, in: 0...4000, step: 100)
                Toggle("递归激活（条目内容可触发其他条目）", isOn: $book.recursiveScanning)
            }
            Section {
                Picker("分类", selection: $filter) {
                    Text("全部").tag(LoreCategory?.none)
                    ForEach(LoreCategory.allCases, id: \.self) { Text($0.rawValue).tag(LoreCategory?.some($0)) }
                }
                .pickerStyle(.menu)
                ForEach(book.entries.filter { filter == nil || $0.category == filter }) { entry in
                    Button {
                        editingEntry = entry
                    } label: {
                        EntryRow(entry: entry)
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            book.entries.removeAll { $0.id == entry.id }
                        } label: { Label("删除", systemImage: "trash") }
                    }
                }
                Button {
                    let next = (book.entries.map(\.uid).max() ?? -1) + 1
                    let entry = LoreEntry(uid: next, category: filter ?? .other)
                    book.entries.append(entry)
                    editingEntry = entry
                } label: { Label("添加条目", systemImage: "plus") }
            } header: {
                Text("条目（\(book.entries.count)）")
            } footer: {
                Text("激活顺序：常驻 → 粘滞 → 关键词（再校验次要关键词）→ 概率 → 递归。同组只留优先级最高的一条；超出预算时按优先级从低到高舍弃。注入时同一位置按插入顺序从小到大排列。")
            }
        }
        .navigationTitle(book.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") {
                    onSave?()
                    dismiss()
                }
            }
        }
        .sheet(item: $editingEntry) { entry in
            NavigationStack {
                LoreEntryEditorView(entry: entry) { updated in
                    if let i = book.entries.firstIndex(where: { $0.id == updated.id }) {
                        book.entries[i] = updated
                    }
                }
            }
        }
    }
}

private struct EntryRow: View {
    let entry: LoreEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(entry.title).foregroundStyle(entry.enabled ? Theme.textPrimary : Theme.textTertiary)
                Text(entry.category.rawValue).font(.caption2).foregroundStyle(Theme.moon)
                if entry.constant { Pill(text: "常驻") }
                if !entry.conditions.isEmpty { Pill(text: "条件", tint: Theme.amber) }
                if !entry.enabled { Pill(text: "已停用", tint: Theme.danger) }
            }
            if !entry.keys.isEmpty {
                Text(entry.keys.joined(separator: "、"))
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
        }
    }
}

struct LoreEntryEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State var entry: LoreEntry
    let onSave: (LoreEntry) -> Void

    @State private var keysText = ""
    @State private var secondaryText = ""
    @State private var filterText = ""

    init(entry: LoreEntry, onSave: @escaping (LoreEntry) -> Void) {
        _entry = State(initialValue: entry)
        self.onSave = onSave
        _keysText = State(initialValue: entry.keys.joined(separator: ", "))
        _secondaryText = State(initialValue: entry.secondaryKeys.joined(separator: ", "))
        _filterText = State(initialValue: entry.characterFilter.joined(separator: ", "))
    }

    var body: some View {
        Form {
            Section("内容") {
                TextField("标题 / 备注", text: $entry.comment)
                Picker("分类", selection: $entry.category) {
                    ForEach(LoreCategory.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                TextField("设定内容", text: $entry.content, axis: .vertical)
                    .lineLimit(4...14)
                Toggle("启用", isOn: $entry.enabled)
            }
            Section {
                Toggle("常驻（始终注入）", isOn: $entry.constant)
                TextField("主关键词（逗号分隔，支持 /正则/）", text: $keysText)
                Toggle("需要次要关键词", isOn: $entry.selective)
                if entry.selective {
                    TextField("次要关键词", text: $secondaryText)
                    Picker("次要关键词逻辑", selection: $entry.selectiveLogic) {
                        Text("任意一个命中").tag(SelectiveLogic.andAny)
                        Text("全部命中").tag(SelectiveLogic.andAll)
                        Text("一个都不命中").tag(SelectiveLogic.notAny)
                        Text("没有全部命中").tag(SelectiveLogic.notAll)
                    }
                }
                Toggle("区分大小写", isOn: $entry.caseSensitive)
                Toggle("整词匹配（对英文有效）", isOn: $entry.matchWholeWords)
            } header: { Text("触发") }

            Section {
                ForEach(entry.conditions.indices, id: \.self) { i in
                    HStack {
                        TextField("状态名", text: $entry.conditions[i].key)
                        Picker("", selection: $entry.conditions[i].op) {
                            Text("等于").tag(StateCondition.Operator.equals)
                            Text("不等于").tag(StateCondition.Operator.notEquals)
                            Text("存在").tag(StateCondition.Operator.exists)
                            Text("不存在").tag(StateCondition.Operator.notExists)
                            Text("≥").tag(StateCondition.Operator.greaterOrEqual)
                            Text("≤").tag(StateCondition.Operator.lessOrEqual)
                        }
                        .labelsHidden()
                        TextField("值", text: $entry.conditions[i].value)
                    }
                }
                .onDelete { entry.conditions.remove(atOffsets: $0) }
                Button("添加条件") { entry.conditions.append(StateCondition(key: "", op: .equals)) }
            } header: {
                Text("剧情状态条件")
            } footer: {
                Text("与右侧面板「剧情状态」对照。全部满足时条目才可能被激活。")
            }

            Section("位置与优先级") {
                Picker("注入位置", selection: $entry.position) {
                    Text("角色设定之前").tag(LorePosition.beforeCharacter)
                    Text("角色设定之后").tag(LorePosition.afterCharacter)
                    Text("聊天记录中（按深度）").tag(LorePosition.atDepth)
                }
                if entry.position == .atDepth {
                    Stepper("深度：倒数第 \(entry.depth) 条之前", value: $entry.depth, in: 0...30)
                }
                Stepper("插入顺序 \(entry.insertionOrder)", value: $entry.insertionOrder, in: 0...1000, step: 10)
                Stepper("优先级 \(entry.priority)", value: $entry.priority, in: 0...1000, step: 5)
                Stepper("激活概率 \(entry.probability)%", value: $entry.probability, in: 0...100, step: 5)
                TextField("互斥组（同组只取一条）", text: $entry.group)
            }

            Section("时效与递归") {
                Stepper("粘滞 \(entry.sticky) 回合", value: $entry.sticky, in: 0...50)
                Stepper("冷却 \(entry.cooldown) 回合", value: $entry.cooldown, in: 0...50)
                Stepper("至少 \(entry.delay) 条消息后才可激活", value: $entry.delay, in: 0...200)
                Toggle("不被递归激活", isOn: $entry.excludeRecursion)
                Toggle("内容不触发递归", isOn: $entry.preventRecursion)
            }

            Section {
                TextField("角色名（逗号分隔，留空为全部）", text: $filterText)
                Toggle("排除这些角色（而不是仅限）", isOn: $entry.characterFilterExclude)
            } header: { Text("角色过滤（群聊）") }
        }
        .navigationTitle(entry.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    entry.keys = Self.split(keysText)
                    entry.secondaryKeys = Self.split(secondaryText)
                    entry.characterFilter = Self.split(filterText)
                    entry.conditions = entry.conditions.filter { !$0.key.isBlank }
                    onSave(entry)
                    dismiss()
                }
            }
        }
    }

    static func split(_ text: String) -> [String] {
        text.split(whereSeparator: { ",，、".contains($0) }).map { $0.trimmed }.filter { !$0.isEmpty }
    }
}
