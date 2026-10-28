import SwiftUI

/// 视觉基调：深夜酒馆。墨蓝底色，烛光琥珀作强调色，月光银作次要色。
enum Theme {
    static let background = Color(red: 0.055, green: 0.059, blue: 0.082)        // #0E0F15
    static let surface = Color(red: 0.086, green: 0.090, blue: 0.122)           // #16171F
    static let surfaceRaised = Color(red: 0.118, green: 0.122, blue: 0.161)     // #1E1F29
    static let hairline = Color.white.opacity(0.08)
    static let amber = Color(red: 0.886, green: 0.702, blue: 0.420)             // #E2B36B 烛光
    static let amberSoft = Color(red: 0.886, green: 0.702, blue: 0.420).opacity(0.14)
    static let moon = Color(red: 0.788, green: 0.800, blue: 0.839)              // #C9CCD6 月光
    static let textPrimary = Color(red: 0.925, green: 0.918, blue: 0.894)
    static let textSecondary = Color(red: 0.925, green: 0.918, blue: 0.894).opacity(0.62)
    static let textTertiary = Color(red: 0.925, green: 0.918, blue: 0.894).opacity(0.38)
    static let danger = Color(red: 0.898, green: 0.408, blue: 0.392)
    static let success = Color(red: 0.494, green: 0.773, blue: 0.588)
    static let userBubble = Color(red: 0.886, green: 0.702, blue: 0.420).opacity(0.13)
    static let characterBubble = Color(red: 0.129, green: 0.133, blue: 0.180)

    static func titleFont(_ size: CGFloat) -> Font {
        .system(size: size, weight: .semibold, design: .serif)
    }
}

/// 圆形头像：有图显示图，没图显示首字。
struct AvatarView: View {
    let name: String
    let imageData: Data?
    var size: CGFloat = 40
    var ring: Bool = true

    var body: some View {
        ZStack {
            if let data = imageData, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                // 先铺一层不透明底色，群聊头像叠放时不会互相透出来
                Theme.surfaceRaised
                LinearGradient(
                    colors: [Theme.surfaceRaised, Theme.amber.opacity(0.35)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Text(String(name.prefix(1)))
                    .font(Theme.titleFont(size * 0.42))
                    .foregroundStyle(Theme.textPrimary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(Theme.amber.opacity(ring ? 0.45 : 0), lineWidth: 1))
        .accessibilityLabel(Text(name))
    }
}

/// 「示例」徽章：演示数据必须明确标注。
struct SampleBadge: View {
    /// 放在琥珀色高亮背景上时改用深色
    var onAccent = false

    var body: some View {
        Text("示例")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(onAccent ? Theme.background.opacity(0.14) : Theme.moon.opacity(0.16)))
            .foregroundStyle(onAccent ? Theme.background.opacity(0.8) : Theme.moon)
    }
}

/// 深色输入框：替代系统 roundedBorder（深色模式下是纯黑方块，和卡片底色不协调）。
struct MoonFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.background.opacity(0.7)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Theme.hairline, lineWidth: 1))
    }
}

extension TextFieldStyle where Self == MoonFieldStyle {
    static var moon: MoonFieldStyle { MoonFieldStyle() }
}

struct Pill: View {
    let text: String
    var systemImage: String? = nil
    var tint: Color = Theme.moon

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(tint.opacity(0.14)))
        .foregroundStyle(tint)
    }
}

struct SectionCard<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.surfaceRaised))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.hairline))
    }
}

/// 多行文本输入框，带标题和占位提示。
struct LabeledEditor: View {
    let title: String
    @Binding var text: String
    var placeholder: String = ""
    var minHeight: CGFloat = 80

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $text)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: minHeight)
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.hairline))
        }
    }
}

extension View {
    /// 统一的深色页面背景。
    func tavernBackground() -> some View {
        self.background(Theme.background.ignoresSafeArea())
    }
}
