import SwiftUI
import UniformTypeIdentifiers

@main
struct MoonlitTavernApp: App {
    @StateObject private var state = AppState()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
                .environmentObject(state.models)
                .preferredColorScheme(.dark)
                .tint(Theme.amber)
                // 备用的系统文件选择器：SwiftUI 自带的单选版本，点一下文件就返回
                .fileImporter(isPresented: $state.showAlternateImporter,
                              allowedContentTypes: [.json, .png, .image, .data],
                              allowsMultipleSelection: false) { result in
                    switch result {
                    case .success(let urls):
                        if let url = urls.first { state.importOpenedFile(url, source: "备用选择器：选中") }
                    case .failure(let error):
                        EngineLog.shared.append("备用选择器：失败：\(error)")
                        state.show(.error, "选择文件失败：\(error.localizedDescription)")
                    }
                }
                .onChange(of: state.showAlternateImporter) { _, shown in
                    EngineLog.shared.append(shown ? "备用选择器：弹出" : "备用选择器：已关闭")
                }
                // iPad 分屏时，从「文件」把角色卡拖进来
                .onDrop(of: [.png, .json], isTargeted: nil) { providers in
                    state.importDropped(providers)
                }
                // 在「文件」里长按 › 共享 › 月下酒馆
                .onOpenURL { url in
                    state.importOpenedFile(url, source: "从其他 App 打开")
                }
        }
        .onChange(of: scenePhase) { _, phase in
            state.handleScenePhase(phase)
        }
    }
}
