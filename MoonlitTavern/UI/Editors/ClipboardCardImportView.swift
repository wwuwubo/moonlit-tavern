import SwiftUI
import UIKit

/// 通过粘贴文本导入 JSON 角色卡。该路径不使用系统文档选择器。
struct ClipboardCardImportView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var jsonText = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("将角色卡 JSON 文本粘贴到下方。可以点“读取剪贴板”，也可以长按输入框选择“粘贴”。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Button("读取剪贴板") {
                        jsonText = UIPasteboard.general.string ?? ""
                        if jsonText.isEmpty {
                            state.show(.error, "剪贴板中没有可读取的文本")
                        }
                    }
                    .accessibilityIdentifier("readCardClipboardButton")

                    TextEditor(text: $jsonText)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 220)
                        .accessibilityIdentifier("cardJSONEditor")
                } header: {
                    Text("JSON 角色卡")
                } footer: {
                    Text("兼容角色卡 V1、V2、V3。导入失败时会显示原因，输入的内容不会被清除。")
                }
            }
            .navigationTitle("粘贴 JSON 角色卡")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("导入") {
                        if state.importCharacterCard(jsonText: jsonText) != nil {
                            dismiss()
                        }
                    }
                    .disabled(jsonText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("confirmPasteCardImport")
                }
            }
        }
    }
}
