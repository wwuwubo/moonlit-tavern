import SwiftUI
import MoonlitCore

struct RootView: View {
    @EnvironmentObject private var state: AppState
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showInspector = true
    @State private var showSettings = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(showSettings: $showSettings)
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 360)
        } detail: {
            Group {
                if let chatID = state.selectedChatID, state.chat(chatID) != nil {
                    ChatView(chatID: chatID, showInspector: $showInspector)
                        .id(chatID)
                        .inspector(isPresented: $showInspector) {
                            InspectorView(chatID: chatID)
                                .inspectorColumnWidth(min: 300, ideal: 360, max: 460)
                        }
                } else {
                    EmptyTavernView(showSettings: $showSettings)
                }
            }
            .tavernBackground()
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .overlay(alignment: .top) {
            BannerView()
        }
    }
}

/// 顶部提示条：几秒后自动消失。
struct BannerView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        if let banner = state.banner {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon(banner.kind))
                    .foregroundStyle(color(banner.kind))
                Text(banner.text)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button {
                    state.banner = nil
                } label: {
                    Image(systemName: "xmark").font(.caption.weight(.bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: 560)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(color(banner.kind).opacity(0.35)))
            .padding(.top, 8)
            .padding(.horizontal, 16)
            .transition(.move(edge: .top).combined(with: .opacity))
            .task(id: banner.id) {
                try? await Task.sleep(nanoseconds: banner.kind == .error ? 8_000_000_000 : 4_500_000_000)
                if state.banner?.id == banner.id {
                    withAnimation { state.banner = nil }
                }
            }
        }
    }

    private func icon(_ kind: Banner.Kind) -> String {
        switch kind {
        case .info: return "info.circle"
        case .warning: return "exclamationmark.triangle"
        case .error: return "xmark.octagon"
        case .success: return "checkmark.circle"
        }
    }

    private func color(_ kind: Banner.Kind) -> Color {
        switch kind {
        case .info: return Theme.moon
        case .warning: return Theme.amber
        case .error: return Theme.danger
        case .success: return Theme.success
        }
    }
}

struct EmptyTavernView: View {
    @Binding var showSettings: Bool

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "moon.stars")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(Theme.amber)
            Text("月下酒馆")
                .font(Theme.titleFont(30))
                .foregroundStyle(Theme.textPrimary)
            Text("在左侧选一位角色开始对话，或者导入一张角色卡。")
                .foregroundStyle(Theme.textSecondary)
            Button("模型与设置") { showSettings = true }
                .buttonStyle(.bordered)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
