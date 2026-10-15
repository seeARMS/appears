import AppKit
import SwiftUI

/// Appears' tokens (brand/README.md): shadcn's zinc scale, hairline borders, small radii, a black
/// primary and one blue accent, used sparingly. The app uses the system font.
enum Theme {
    static let background = Color(light: 0xFFFFFF, dark: 0x09090B)
    static let card = Color(light: 0xFFFFFF, dark: 0x18181B)
    static let muted = Color(light: 0xF4F4F5, dark: 0x27272A)
    static let border = Color(light: 0xE4E4E7, dark: 0x27272A)
    static let mutedForeground = Color(light: 0x71717A, dark: 0xA1A1AA)
    static let foreground = Color(light: 0x09090B, dark: 0xFAFAFA)
    static let primary = Color(light: 0x18181B, dark: 0xFAFAFA)
    static let primaryForeground = Color(light: 0xFAFAFA, dark: 0x18181B)
    static let accent = Color(light: 0x2563EB, dark: 0x3B82F6)
    /// Keys sit on the muted row background, so in dark mode they need a lighter edge.
    static let kbdBorder = Color(light: 0xE4E4E7, dark: 0x3F3F46)

    static let radius: CGFloat = 8
    static let controlRadius: CGFloat = 6
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1
            )
        })
    }
}

/// shadcn's default button: black (white in dark mode), 6 px radius.
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.primaryForeground)
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: Theme.controlRadius).fill(Theme.primary))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// shadcn's outline button.
struct OutlineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.foreground)
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: Theme.controlRadius).fill(configuration.isPressed ? Theme.muted : Theme.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius).strokeBorder(Theme.border))
    }
}

/// A keyboard key, like shadcn's `Kbd`.
struct Kbd: View {
    let key: String

    var body: some View {
        Text(key)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.mutedForeground)
            .padding(.horizontal, 5)
            .frame(minWidth: 20, minHeight: 18)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.kbdBorder))
    }
}

/// A small pill, like shadcn's secondary `Badge`.
struct Badge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.mutedForeground)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill(Theme.muted))
    }
}

/// The mark: a zinc-950 tile, a white ring, and a blue dot rising at its top.
struct Mark: View {
    var size: CGFloat = 40

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.25, style: .continuous).fill(Color(light: 0x18181B, dark: 0x27272A))
            Circle()
                .stroke(Color(light: 0xFAFAFA, dark: 0xFAFAFA), lineWidth: size * 0.069)
                .frame(width: size * 0.44, height: size * 0.44)
                .offset(y: size * 0.069)
            Circle()
                .fill(Theme.accent)
                .frame(width: size * 0.2, height: size * 0.2)
                .offset(y: -size * 0.25)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
