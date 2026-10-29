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

    /// 弹出前的准备，由 AppState 注入：停下剧情选项、卸载本地模型，给系统选择器腾出内存。
    static var prepare: (@MainActor () async -> Void)?

    private let onPick: ([URL]) -> Void
    private let onCancel: () -> Void

    private init(onPick: @escaping ([URL]) -> Void, onCancel: @escaping () -> Void) {
        self.onPick = onPick
        self.onCancel = onCancel
    }

    /// 选择一个文件。默认原地打开（asCopy 为 false）：拿到原文件地址和临时访问授权，由调用方读取。
    /// 拷贝模式需要系统把文件写进本 App 的容器；真机上出现过选择器整页空白的情况，怀疑与此有关，所以默认不用。
    static func open(_ types: [UTType], asCopy: Bool = false, onPick: @escaping (URL) -> Void) {
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
        Task { @MainActor in
            await prepare?()
            // 从菜单里触发时，菜单还在收起；稍等再弹出，避免两次呈现撞在一起被 UIKit 拒绝
            try? await Task.sleep(nanoseconds: 350_000_000)
            // 上一层（导入页等）的收起动画还没走完时再等等，最多 2 秒：撞上转场时选择器可能只弹出一个空壳
            var waited = 0
            while waited < 20, let top = topViewController(),
                  top.transitionCoordinator != nil || top.presentedViewController?.isBeingDismissed == true {
                try? await Task.sleep(nanoseconds: 100_000_000)
                waited += 1
            }
            if waited > 0 { EngineLog.shared.append("文档选择器：等上一层收起 \(waited * 100) 毫秒") }
            guard let top = topViewController() else {
                EngineLog.shared.append("文档选择器：找不到可用于弹出的界面")
                active = nil
                return
            }
            let host = String(describing: type(of: top)).split(separator: "<").first.map(String.init) ?? "?"
            EngineLog.shared.append("文档选择器：弹出（\(host)，\(PickerDiagnostics.opened())）")
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
        EngineLog.shared.append("文档选择器：选中 \(urls.map(\.lastPathComponent).joined(separator: "、"))\(PickerDiagnostics.closed())")
        onPick(urls)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        Self.active = nil
        EngineLog.shared.append("文档选择器：已取消\(PickerDiagnostics.closed())")
        onCancel()
    }
}

/// 记下系统选择器从弹出到关闭之间的情况，写进诊断日志：弹出时的内存、开了多久、期间有没有内存警告。
/// 两种选择器不会同时打开，共用一份记录。
@MainActor
enum PickerDiagnostics {
    private static var openedAt: Date?
    private static var memoryWarned = false

    /// 选择器弹出时调用，返回当时的内存读数。
    static func opened() -> String {
        openedAt = Date()
        memoryWarned = false
        return memorySummary
    }

    static func noteMemoryWarning() {
        if openedAt != nil { memoryWarned = true }
    }

    /// 选择器关闭时调用，返回「（打开 N 秒，期间收到内存警告）」；没有对应的弹出记录时返回空串。
    static func closed() -> String {
        guard let start = openedAt else { return "" }
        openedAt = nil
        var text = "打开 \(Int(Date().timeIntervalSince(start).rounded())) 秒"
        if memoryWarned { text += "，期间收到内存警告" }
        return "（\(text)）"
    }

    static var memorySummary: String {
        let footprint = Int(DeviceMetrics.footprintMB() ?? -1)
        let available = Int(DeviceMetrics.availableMemoryMB())
        return "进程 \(footprint) MB，还可用 \(available) MB"
    }
}

extension View {
    /// 与 fileImporter 用法相同：绑定值变为 true 时弹出系统文档选择器。
    func documentImporter(isPresented: Binding<Bool>,
                          types: [UTType],
                          asCopy: Bool = false,
                          onPick: @escaping (URL) -> Void) -> some View {
        onChange(of: isPresented.wrappedValue) { _, show in
            guard show else { return }
            isPresented.wrappedValue = false
            DocumentPicker.open(types, asCopy: asCopy, onPick: onPick)
        }
    }
}
