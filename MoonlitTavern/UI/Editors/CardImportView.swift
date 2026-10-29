import SwiftUI
import UIKit
import UniformTypeIdentifiers
import MoonlitCore

/// 导入角色卡：粘贴、App 文件夹、系统文件选择器三条路。
/// 前两条完全不经过系统文件选择器，选择器在某些设备上出问题时也能导入。
struct CardImportView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var jsonText = ""
    @State private var folderFiles: [URL] = []

    var body: some View {
        NavigationStack {
            Form {
                pasteSection
                folderSection
                pickerSection
            }
            .scrollContentBackground(.hidden)
            .tavernBackground()
            .navigationTitle("导入角色卡")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .onAppear { folderFiles = state.cardFolderFiles() }
        }
    }

    // MARK: 粘贴

    private var pasteSection: some View {
        Section {
            HStack {
                Button {
                    readClipboard()
                } label: {
                    Label("读取剪贴板", systemImage: "doc.on.clipboard")
                }
                .accessibilityIdentifier("readCardClipboardButton")
                Spacer()
                Button {
                    importPasted()
                } label: {
                    Label("导入", systemImage: "square.and.arrow.down")
                        .fontWeight(.semibold)
                }
                .disabled(jsonText.trimmed.isEmpty)
                .accessibilityIdentifier("confirmPasteCardImport")
            }
            .buttonStyle(.borderless)
            TextEditor(text: $jsonText)
                .font(.system(.footnote, design: .monospaced))
                .frame(minHeight: 110, maxHeight: 220)
                .scrollContentBackground(.hidden)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.background.opacity(0.7)))
                .accessibilityIdentifier("cardJSONEditor")
        } header: {
            Text("粘贴 JSON")
        } footer: {
            Text("把角色卡 JSON 的全部文字粘贴进来，兼容 V1 / V2 / V3。剪贴板里如果是 PNG 角色卡图片（在「文件」里长按 › 拷贝），点「读取剪贴板」会直接导入。")
        }
    }

    private func readClipboard() {
        let pasteboard = UIPasteboard.general
        if let text = pasteboard.string, !text.trimmed.isEmpty {
            jsonText = text
            return
        }
        if let png = pasteboard.data(forPasteboardType: UTType.png.identifier) {
            if state.importCharacterCard(data: png, fileName: "剪贴板图片") != nil { dismiss() }
            return
        }
        state.show(.error, "剪贴板里没有文字，也没有 PNG 图片")
    }

    private func importPasted() {
        if state.importCharacterCard(jsonText: jsonText) != nil { dismiss() }
    }

    // MARK: App 文件夹

    private var folderSection: some View {
        Section {
            if folderFiles.isEmpty {
                Text("文件夹里还没有 PNG 或 JSON 文件")
                    .font(.footnote)
                    .foregroundStyle(Theme.textTertiary)
            }
            ForEach(folderFiles, id: \.self) { url in
                Button {
                    if state.importCharacterCard(from: url) != nil { dismiss() }
                } label: {
                    HStack {
                        Image(systemName: url.pathExtension.lowercased() == "png" ? "photo" : "curlybraces")
                            .foregroundStyle(Theme.amber)
                            .frame(width: 22)
                        Text(url.lastPathComponent)
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        Spacer()
                        Image(systemName: "square.and.arrow.down")
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                .accessibilityIdentifier("folder-card-\(url.lastPathComponent)")
            }
            Button {
                folderFiles = state.cardFolderFiles()
            } label: {
                Label("刷新列表", systemImage: "arrow.clockwise")
            }
            .accessibilityIdentifier("refreshCardFolder")
        } header: {
            Text("从 App 文件夹导入")
        } footer: {
            Text("在「文件」App 里把角色卡移动到「我的 iPad › 月下酒馆 › 角色卡」，回到这里点「刷新列表」，再点文件名导入。这条路不经过系统文件选择器。")
        }
    }

    // MARK: 系统文件选择器

    private var pickerSection: some View {
        Section {
            Button {
                // 先收起这个页面，再从主界面弹出系统选择器：不在弹出的页面上再叠一层
                let appState = state
                dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    DocumentPicker.open([.png, .json, .image, .data]) { url in
                        _ = appState.importCharacterCard(from: url)
                    }
                }
            } label: {
                Label("从「文件」中选择…", systemImage: "folder")
            }
            .accessibilityIdentifier("pickCardFileButton")
            Button {
                let appState = state
                dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    appState.openAlternateImporter()
                }
            } label: {
                Label("备用：换一种方式打开「文件」", systemImage: "folder.badge.questionmark")
            }
            .accessibilityIdentifier("pickCardFileButtonAlt")
        } header: {
            Text("从「文件」中选择")
        } footer: {
            Text("两个按钮用的是系统选择器的两种打开方式，点一下文件就会导入。如果都打不开或一片空白，用上面两种方式；也可以在「文件」App 里长按角色卡 › 共享 › 月下酒馆。")
        }
    }
}
