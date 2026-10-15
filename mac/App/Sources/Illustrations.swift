import SwiftUI

/// Onboarding's illustrations: small looping scenes that show what you get, drawn in the
/// app's tokens. Each is a pure function of time, so it loops cleanly, and shows a still,
/// finished frame when Reduce Motion is on.
struct Illustration: View {
    enum Scene {
        /// An email being written, and the things you already have rising up beside it.
        case moment
        /// A window being read, and the menu bar icon lighting up.
        case notice
        /// Photos, PDFs, notes and screenshots gathering into one place.
        case gather
        /// The menu bar icon getting its dot, and the panel dropping down.
        case ready
    }

    let scene: Scene
    /// A fixed moment to draw instead of animating (snapshots).
    var time: Double? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            let t = time ?? (reduceMotion ? Self.stillFrame(scene) : context.date.timeIntervalSinceReferenceDate)
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.muted)
                switch scene {
                case .moment: MomentScene(t: t.truncatingRemainder(dividingBy: 8))
                case .notice: NoticeScene(t: t.truncatingRemainder(dividingBy: 5.5))
                case .gather: GatherScene(t: t.truncatingRemainder(dividingBy: 6))
                case .ready: ReadyScene(t: t.truncatingRemainder(dividingBy: 6))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .frame(height: 220)
        .accessibilityHidden(true)
    }

    /// The moment each scene looks finished, for Reduce Motion.
    static func stillFrame(_ scene: Scene) -> Double {
        switch scene {
        case .moment: 5.5
        case .notice: 4.0
        case .gather: 4.5
        case .ready: 4.0
        }
    }
}

// MARK: - Timing

/// 0 before `start`, 1 after `start + duration`, eased in between.
private func progress(_ t: Double, _ start: Double, _ duration: Double) -> Double {
    let x = min(max((t - start) / duration, 0), 1)
    return x * x * (3 - 2 * x)
}

/// Fades in at `start` and out again before the loop ends.
private func presence(_ t: Double, in start: Double, out end: Double, fade: Double = 0.35) -> Double {
    progress(t, start, fade) * (1 - progress(t, end, fade))
}

// MARK: - Shared pieces

private struct MenuBarStrip: View {
    var found: Double
    var scale: CGFloat = 1

    var body: some View {
        HStack(spacing: 10 * scale) {
            ForEach(0..<4, id: \.self) { i in
                Capsule().fill(Theme.mutedForeground.opacity(0.35)).frame(width: [22, 14, 16, 18][i] * scale, height: 4 * scale)
            }
            Spacer()
            MenuGlyph(found: found).frame(width: 16 * scale, height: 16 * scale)
            Capsule().fill(Theme.mutedForeground.opacity(0.35)).frame(width: 26 * scale, height: 4 * scale)
        }
        .padding(.horizontal, 12 * scale)
        .frame(height: 22 * scale)
        .background(Theme.card.opacity(0.9))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }
}

/// The menu bar icon, with its "found" mark fading in.
struct MenuGlyph: View {
    var found: Double

    var body: some View {
        GeometryReader { geo in
            let s = geo.size.width
            ZStack {
                Circle().stroke(Theme.foreground, lineWidth: s * 0.11).frame(width: s * 0.72, height: s * 0.72).offset(y: s * 0.08)
                Circle().fill(Theme.accent)
                    .frame(width: s * 0.36, height: s * 0.36)
                    .offset(y: -s * 0.3)
                    .scaleEffect(0.4 + 0.6 * found)
                    .opacity(found)
            }
            .frame(width: s, height: s)
        }
    }
}

private enum Thumb {
    case photo, pdf, note, screenshot

    @ViewBuilder
    func view(size: CGFloat) -> some View {
        switch self {
        case .photo:
            RoundedRectangle(cornerRadius: size * 0.16).fill(Color(red: 0.55, green: 0.42, blue: 0.31))
                .overlay(RoundedRectangle(cornerRadius: 2).fill(Color(red: 0.97, green: 0.95, blue: 0.9)).padding(size * 0.2).rotationEffect(.degrees(-4)))
        case .pdf:
            RoundedRectangle(cornerRadius: size * 0.16).fill(Theme.card)
                .overlay(VStack(alignment: .leading, spacing: size * 0.08) {
                    ForEach(0..<4, id: \.self) { i in Capsule().fill(Theme.border).frame(width: size * (i % 2 == 0 ? 0.6 : 0.42), height: max(2, size * 0.06)) }
                })
                .overlay(RoundedRectangle(cornerRadius: size * 0.16).strokeBorder(Theme.border))
        case .note:
            RoundedRectangle(cornerRadius: size * 0.16).fill(Color(red: 1, green: 0.96, blue: 0.76))
                .overlay(VStack(alignment: .leading, spacing: size * 0.08) {
                    ForEach(0..<3, id: \.self) { i in Capsule().fill(Color(red: 0.85, green: 0.76, blue: 0.4)).frame(width: size * (i == 1 ? 0.4 : 0.58), height: max(2, size * 0.06)) }
                })
        case .screenshot:
            RoundedRectangle(cornerRadius: size * 0.16).fill(Color(red: 0.86, green: 0.91, blue: 1))
                .overlay(alignment: .top) { Rectangle().fill(Color(red: 0.62, green: 0.72, blue: 0.95)).frame(height: size * 0.18) }
                .clipShape(RoundedRectangle(cornerRadius: size * 0.16))
        }
    }
}

// MARK: - Scenes

/// Writing to Dana; a beat later the quote photo, the permit and the measurements rise into
/// a panel under the menu bar icon.
private struct MomentScene: View {
    let t: Double

    var body: some View {
        let typed = progress(t, 0.4, 2.4)
        let shown = presence(t, in: 2.9, out: 7.2)
        VStack(spacing: 0) {
            MenuBarStrip(found: presence(t, in: 2.7, out: 7.2))
            HStack(alignment: .top, spacing: 14) {
                // The email being written.
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 4) {
                        ForEach(0..<3, id: \.self) { _ in Circle().fill(Theme.border).frame(width: 7, height: 7) }
                    }
                    Text("To: Dana Ruiz").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.foreground)
                    Text("Re: Kitchen").font(.system(size: 11)).foregroundStyle(Theme.mutedForeground)
                    Rectangle().fill(Theme.border).frame(height: 1)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(0..<5, id: \.self) { i in
                            let line = progress(typed * 5, Double(i), 1)
                            Capsule().fill(Theme.mutedForeground.opacity(0.35))
                                .frame(width: [180, 150, 172, 120, 60][i] * line, height: 5)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(14)
                .frame(width: 230, height: 168, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))

                // What Appears brings back.
                VStack(alignment: .leading, spacing: 6) {
                    Text("Related").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.foreground)
                        .padding(.horizontal, 4)
                    ForEach(Array(zip([Thumb.photo, .pdf, .note], ["Quote photo", "Permit · page 3", "Measurements"]).enumerated()), id: \.offset) { i, row in
                        let rise = progress(t, 3.0 + Double(i) * 0.35, 0.5)
                        HStack(spacing: 8) {
                            row.0.view(size: 26).frame(width: 26, height: 26)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(row.1).font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.foreground)
                                Capsule().fill(Theme.mutedForeground.opacity(0.3)).frame(width: 54, height: 4)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(i == 0 ? Theme.muted : Color.clear))
                        .opacity(rise)
                        .offset(y: (1 - rise) * 14)
                    }
                }
                .padding(8)
                .frame(width: 178, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card).shadow(color: .black.opacity(0.08), radius: 10, y: 4))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
                .opacity(shown)
                .offset(y: (1 - shown) * -8)
            }
            .padding(.top, 14)
            Spacer(minLength: 0)
        }
    }
}

/// A highlight reads down the window; the menu bar icon notices.
private struct NoticeScene: View {
    let t: Double

    var body: some View {
        let read = progress(t, 0.5, 2.4)
        let found = presence(t, in: 3.0, out: 5.1)
        VStack(spacing: 0) {
            MenuBarStrip(found: found)
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 4) {
                        ForEach(0..<3, id: \.self) { _ in Circle().fill(Theme.border).frame(width: 7, height: 7) }
                    }
                    ForEach(0..<6, id: \.self) { i in
                        Capsule().fill(Theme.mutedForeground.opacity(0.35)).frame(width: [260, 220, 248, 190, 236, 120][i], height: 6)
                    }
                    Spacer(minLength: 0)
                }
                .padding(16)
                // The reading highlight.
                RoundedRectangle(cornerRadius: 4)
                    .fill(Theme.accent.opacity(0.14))
                    .frame(width: 272, height: 14)
                    .offset(x: 10, y: 33 + read * 75)
                    .opacity(presence(t, in: 0.4, out: 3.1))
            }
            .frame(width: 300, height: 150, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
            .padding(.top, 18)
            Spacer(minLength: 0)
        }
    }
}

/// Your stuff drifts in from all sides and settles into one stack.
private struct GatherScene: View {
    let t: Double
    private let tiles: [(Thumb, CGPoint)] = [
        (.photo, CGPoint(x: -185, y: -48)), (.pdf, CGPoint(x: 180, y: -44)), (.note, CGPoint(x: -168, y: 52)),
        (.screenshot, CGPoint(x: 176, y: 50)), (.pdf, CGPoint(x: -96, y: -66)), (.photo, CGPoint(x: 100, y: 64)),
    ]

    var body: some View {
        let settle = presence(t, in: 0.0, out: 5.6, fade: 0.4)
        ZStack {
            // The stack they land on.
            ForEach(0..<3, id: \.self) { i in
                RoundedRectangle(cornerRadius: 10)
                    .fill(Theme.card)
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
                    .frame(width: 92, height: 92)
                    .offset(x: CGFloat(i) * 5, y: CGFloat(-i) * 5)
            }
            Image(systemName: "checkmark")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .offset(x: 10, y: -10)
                .opacity(progress(t, 3.6, 0.4) * (1 - progress(t, 5.4, 0.3)))
            // A count that climbs as things land: what you'll be able to find.
            Text("\(Int(progress(t, 0.6, 3.2) * 1_248).formatted()) things to find")
                .font(.system(size: 11.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Theme.mutedForeground)
                .offset(x: 5, y: 66)
                .opacity(settle)
            ForEach(Array(tiles.enumerated()), id: \.offset) { i, tile in
                let move = progress(t, 0.5 + Double(i) * 0.38, 1.1)
                tile.0.view(size: 38)
                    .frame(width: 38, height: 38)
                    .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
                    .scaleEffect(1 - 0.45 * move)
                    .offset(x: tile.1.x * (1 - move) + 10, y: tile.1.y * (1 - move) - 10)
                    .opacity((1 - progress(t, 1.4 + Double(i) * 0.38, 0.4)) * settle)
            }
        }
    }
}

/// The icon gets its dot, and the panel drops down with something useful.
private struct ReadyScene: View {
    let t: Double

    var body: some View {
        let found = presence(t, in: 0.9, out: 5.5)
        let drop = presence(t, in: 1.7, out: 5.4)
        VStack(spacing: 0) {
            MenuBarStrip(found: found, scale: 1.5)
            HStack(alignment: .top) {
                // Whatever you're working on, behind.
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 4) {
                        ForEach(0..<3, id: \.self) { _ in Circle().fill(Theme.border).frame(width: 7, height: 7) }
                    }
                    ForEach(0..<4, id: \.self) { i in
                        Capsule().fill(Theme.mutedForeground.opacity(0.25)).frame(width: [170, 130, 150, 90][i], height: 5)
                    }
                }
                .padding(14)
                .frame(width: 200, height: 120, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card.opacity(0.7)))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
                .padding(.leading, 30)
                .padding(.top, 14)
                Spacer()
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(zip([Thumb.photo, .note], ["Quote photo", "Measurements"]).enumerated()), id: \.offset) { i, row in
                        HStack(spacing: 8) {
                            row.0.view(size: 30).frame(width: 30, height: 30)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(row.1).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.foreground)
                                Capsule().fill(Theme.mutedForeground.opacity(0.3)).frame(width: 64, height: 4)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(i == 0 ? Theme.muted : Color.clear))
                    }
                }
                .padding(8)
                .frame(width: 200)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card).shadow(color: .black.opacity(0.1), radius: 12, y: 5))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
                .opacity(drop)
                .offset(y: (1 - drop) * -12)
                .padding(.trailing, 30)
            }
            .padding(.top, 8)
            Spacer(minLength: 0)
        }
    }
}
