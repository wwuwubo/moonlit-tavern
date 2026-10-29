import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// GGUF 模型文件。Info.plist 中声明为导入类型。
    static let gguf = UTType(importedAs: "com.ggml.gguf", conformingTo: .data)
}

/// 通用的导出文档：把内存中的数据交给系统「存储到文件」。
struct ExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data, .json, .png] }
    static var writableContentTypes: [UTType] { [.data, .json, .png] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// 一次导出任务：数据、类型、默认文件名。
struct PendingExport: Identifiable {
    let id = UUID()
    var document: ExportDocument
    var contentType: UTType
    var fileName: String
}

extension View {
    /// 统一的导出入口：绑定一个可选的 PendingExport，非空即弹出系统「存储到」面板。
    func exporter(_ pending: Binding<PendingExport?>, onDone: @escaping (Result<URL, Error>) -> Void = { _ in }) -> some View {
        onChange(of: pending.wrappedValue?.id) { _, id in
            guard id != nil, let job = pending.wrappedValue else { return }
            pending.wrappedValue = nil
            DocumentPicker.export(job.document.data, fileName: job.fileName, onDone: onDone)
        }
    }
}

extension String {
    /// 文件名里不能出现的字符替换掉。
    var safeFileName: String {
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let cleaned = components(separatedBy: invalid).joined(separator: "_").trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "未命名" : cleaned
    }
}
