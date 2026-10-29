import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 直接使用 UIKit 的文档选择器，替代 SwiftUI 的 fileImporter / fileExporter。
///
/// 原因：fileImporter 在部分真机上点「打开」后会卡住，回调不触发（模拟器正常）；
/// 同一个视图上同时挂 fileImporter 和 fileExporter 时也会互相干扰。
/// 选择器由当前最上层的控制器直接弹出，不经过 SwiftUI 的呈现机制。
@MainActor
final class DocumentPicker: NSObject, UIDocumentPickerDelegate {
    /// 选择器弹出期间保持代理存活（UIKit 对 delegate 是弱引用）
    private static var active: DocumentPicker?

    private let onPick: ([URL]) -> Void
    private let onCancel: () -> Void

    private init(onPick: @escaping ([URL]) -> Void, onCancel: @escaping () -> Void) {
        self.onPick = onPick
        self.onCancel = onCancel
    }

    /// 选择一个文件。
    /// - asCopy 为 true：系统先把文件拷贝到本 App 的临时目录再交回，读取不受 iCloud 下载状态和访问授权影响，适合小文件；
    ///   模型这类几 GB 的文件用 false，直接拿原文件地址，由调用方自己复制并显示进度。
    static func open(_ types: [UTType], asCopy: Bool = true, onPick: @escaping (URL) -> Void) {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: asCopy)
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        present(picker, onPick: { urls in
            if let url = urls.first { onPick(url) }
        }, onCancel: {})
    }

    /// 导出：数据先写进临时文件，再交给系统的「存储到」面板。
    static func export(_ data: Data, fileName: String, onDone: @escaping (Result<URL, Error>) -> Void) {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("Export-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(fileName)
            try data.write(to: url, options: .atomic)
            let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
            present(picker, onPick: { urls in
                try? fm.removeItem(at: dir)
                onDone(.success(urls.first ?? url))
            }, onCancel: {
                try? fm.removeItem(at: dir)
            })
        } catch {
            try? fm.removeItem(at: dir)
            onDone(.failure(error))
        }
    }

    private static func present(_ picker: UIDocumentPickerViewController,
                                onPick: @escaping ([URL]) -> Void,
                                onCancel: @escaping () -> Void) {
        let delegate = DocumentPicker(onPick: onPick, onCancel: onCancel)
        picker.delegate = delegate
        active = delegate
        // 从菜单里触发时，菜单还在收起；稍等再弹出，避免两次呈现撞在一起被 UIKit 拒绝
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard let top = topViewController() else {
                EngineLog.shared.append("文档选择器：找不到可用于弹出的界面")
                active = nil
                return
            }
            top.present(picker, animated: true)
        }
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let ordered = scenes.filter { $0.activationState == .foregroundActive } + scenes
        let windows = ordered.flatMap(\.windows)
        guard let root = (windows.first { $0.isKeyWindow } ?? windows.first)?.rootViewController else { return nil }
        var top = root
        while let next = top.presentedViewController, !next.isBeingDismissed {
            top = next
        }
        return top
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        Self.active = nil
        onPick(urls)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        Self.active = nil
        onCancel()
    }
}

extension View {
    /// 与 fileImporter 用法相同：绑定值变为 true 时弹出系统文档选择器。
    func documentImporter(isPresented: Binding<Bool>,
                          types: [UTType],
                          asCopy: Bool = true,
                          onPick: @escaping (URL) -> Void) -> some View {
        onChange(of: isPresented.wrappedValue) { _, show in
            guard show else { return }
            isPresented.wrappedValue = false
            DocumentPicker.open(types, asCopy: asCopy, onPick: onPick)
        }
    }
}
