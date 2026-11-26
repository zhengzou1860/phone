import SwiftUI

enum RestoreTheme {
    static let background = Color(hex: 0x080B12)
    static let card = Color(hex: 0x121722)
    static let cardStrong = Color(hex: 0x181F2C)
    static let stroke = Color.white.opacity(0.09)
    static let cyan = Color(hex: 0x65E6FF)
    static let violet = Color(hex: 0x9B8CFF)
    static let green = Color(hex: 0x69E3AE)
    static let secondary = Color(hex: 0x929CAF)
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

struct RestoreCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RestoreTheme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(RestoreTheme.stroke, lineWidth: 1)
            )
    }
}

struct BrandMark: View {
    var size: CGFloat = 42

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [RestoreTheme.cyan, RestoreTheme.violet],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: "sparkles")
                    .font(.system(size: size * 0.48, weight: .semibold))
                    .foregroundStyle(.black.opacity(0.82))
            )
            .shadow(color: RestoreTheme.cyan.opacity(0.22), radius: 16, y: 6)
    }
}

struct PrivacyPill: View {
    var body: some View {
        Label("仅在本机处理，不上传原片", systemImage: "lock.fill")
            .font(.footnote.weight(.medium))
            .foregroundStyle(RestoreTheme.green)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RestoreTheme.green.opacity(0.09), in: Capsule())
    }
}
