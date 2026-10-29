import Foundation

/// 正在生成的文字。
///
/// 单独成一个可观察对象，只有流式气泡和自动滚动在看它：
/// 放在 AppState 的 generation 里时，每来一个 token，侧栏、右侧面板、整个消息列表都跟着重绘，
/// 生成时界面一顿一顿的。显示也按固定节奏刷新（约每秒 16 次），不跟着 token 一个一个跳。
@MainActor
final class StreamingText: ObservableObject {
    /// 界面上显示的部分
    @Published private(set) var shown = ""
    /// 已经收到的全部文字，定稿和保存用这个
    private(set) var text = ""
    private var flushScheduled = false
    private var epoch = 0

    func append(_ delta: String) {
        guard !delta.isEmpty else { return }
        text += delta
        guard !flushScheduled else { return }
        flushScheduled = true
        let scheduled = epoch
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            guard let self, self.epoch == scheduled else { return }
            self.flushScheduled = false
            self.shown = self.text
        }
    }

    func reset() {
        epoch += 1
        flushScheduled = false
        text = ""
        if !shown.isEmpty { shown = "" }
    }
}
