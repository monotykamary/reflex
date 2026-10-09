import SwiftUI

// Reflex's design system: "Meniscus" — the screen edge as a sliver of liquid
// glass where agents live as beads and everything surfaces from the edge.
// See docs/design.md for the rationale behind each token.

// MARK: Motion

/// Motion follows Emil Kowalski's rules: ease-out for anything the user
/// triggers, nothing longer than ~300 ms, no bounce in UI chrome, exits faster
/// than entrances, and nothing at all for keyboard actions repeated all day.
enum Motion {
    /// Ease-out quint — entrances and state changes the user caused.
    static let enter = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.24)
    /// Exits are quicker and quieter than entrances.
    static let exit = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.16)
    /// Interruptible spring for layout that moves under the pointer.
    static let spring = Animation.spring(duration: 0.3, bounce: 0)
    /// Tiny feedback (press, select).
    static let micro = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.12)
    /// Something arrived: one soft bump, the only place a little bounce is earned.
    static let arrive = Animation.spring(duration: 0.35, bounce: 0.35)
    /// Hover intent before the rail opens (avoids flicker when passing by).
    static let hoverIntent: Duration = .milliseconds(220)
    /// Stagger between list items revealed together (only on first reveal).
    static let stagger: Double = 0.028

    /// The animation to use, or none when the user prefers reduced motion.
    static func pick(_ a: Animation, reduce: Bool) -> Animation? { reduce ? .linear(duration: 0.12) : a }
}

extension AnyTransition {
    /// Rise into place with a breath of blur — never from nothing (scale 0.96).
    static func surface(reduce: Bool = false) -> AnyTransition {
        if reduce { return .opacity }
        return .asymmetric(
            insertion: .modifier(active: SurfaceFX(opacity: 0, scale: 0.96, y: 6, blur: 4),
                                 identity: SurfaceFX(opacity: 1, scale: 1, y: 0, blur: 0)),
            removal: .modifier(active: SurfaceFX(opacity: 0, scale: 0.98, y: 0, blur: 2),
                               identity: SurfaceFX(opacity: 1, scale: 1, y: 0, blur: 0)))
    }

    /// Text that changes in place swaps through a short blur instead of a cut.
    static var blurSwap: AnyTransition {
        .asymmetric(insertion: .modifier(active: SurfaceFX(opacity: 0, scale: 1, y: 3, blur: 3),
                                         identity: SurfaceFX(opacity: 1, scale: 1, y: 0, blur: 0)),
                    removal: .modifier(active: SurfaceFX(opacity: 0, scale: 1, y: -3, blur: 3),
                                       identity: SurfaceFX(opacity: 1, scale: 1, y: 0, blur: 0)))
    }
}

struct SurfaceFX: ViewModifier {
    var opacity: Double
    var scale: CGFloat
    var y: CGFloat
    var blur: CGFloat
    func body(content: Content) -> some View {
        content.opacity(opacity).scaleEffect(scale).offset(y: y).blur(radius: blur)
    }
}

/// A short horizontal shake for "that did not work".
struct Shake: GeometryEffect {
    var travel: CGFloat = 5
    var shakes: CGFloat = 3
    var animatableData: CGFloat
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: travel * sin(animatableData * .pi * shakes * 2), y: 0))
    }
}

/// Pressing anything gives immediate, physical feedback (scale 0.97).
struct Pressable: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Motion.micro, value: configuration.isPressed)
    }
}

// MARK: Color & type

enum Tone {
    static let working = Color(red: 0.36, green: 0.55, blue: 1.0)
    static let blocked = Color(red: 1.0, green: 0.69, blue: 0.13)
    static let done = Color(red: 0.25, green: 0.82, blue: 0.53)
    static let idle = Color.secondary.opacity(0.55)
    static let route = Color(red: 0.62, green: 0.48, blue: 1.0)

    static func of(_ status: String) -> Color {
        switch status {
        case "working": return working
        case "blocked": return blocked
        case "done": return done
        default: return idle
        }
    }

    static func ofItem(_ kind: String) -> Color {
        switch kind {
        case "ask": return blocked
        case "ready", "reply": return done
        case "route": return route
        default: return idle
        }
    }
}

enum Type {
    static let title = Font.system(size: 13, weight: .semibold)
    static let body = Font.system(size: 13)
    static let meta = Font.system(size: 11.5)
    static let mono = Font.system(size: 11.5, design: .monospaced)
    static let count = Font.system(size: 11, weight: .bold, design: .rounded)
    static let field = Font.system(size: 19, weight: .regular)
}

// MARK: Shared pieces

/// An agent as a bead of light. Working beads breathe; a blocked bead wears a
/// ring; a bead that just received something bumps once.
struct Bead: View {
    var status: String
    var size: CGFloat = 8
    var pulse: Int = 0
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var breathe = false

    var body: some View {
        let tone = Tone.of(status)
        ZStack {
            Circle().fill(tone)
                .shadow(color: tone.opacity(status == "idle" || status == "unknown" ? 0 : 0.7), radius: 4)
            if status == "blocked" {
                Circle().strokeBorder(tone.opacity(0.55), lineWidth: 1.2).scaleEffect(1.9)
            }
        }
        .frame(width: size, height: size)
        .opacity(status == "working" && breathe && !reduce ? 0.55 : 1)
        .animation(status == "working" && !reduce ? .easeInOut(duration: 1.4).repeatForever(autoreverses: true) : .default, value: breathe)
        .keyframeAnimator(initialValue: CGFloat(1), trigger: pulse) { v, scale in
            v.scaleEffect(scale)
        } keyframes: { _ in
            if reduce {
                LinearKeyframe(1, duration: 0.01)
            } else {
                SpringKeyframe(1.6, duration: 0.14, spring: .snappy)
                SpringKeyframe(1, duration: 0.32, spring: .bouncy)
            }
        }
        .onAppear { breathe = true }
    }
}

/// A keycap showing which key answers an option.
struct KeyCap: View {
    var key: String
    var tint: Color = .accentColor
    var body: some View {
        Text(key)
            .font(Type.count)
            .frame(width: 18, height: 18)
            .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(tint.opacity(0.28), lineWidth: 0.5))
    }
}

/// A ring that drains over `duration` — the visible undo window.
struct CountdownRing: View {
    var duration: Double
    var tint: Color = .accentColor
    @State private var left: CGFloat = 1
    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.18), lineWidth: 2)
            Circle().trim(from: 0, to: left)
                .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 16, height: 16)
        .onAppear { withAnimation(.linear(duration: max(duration, 0.01))) { left = 0 } }
    }
}

/// A hairline that drains left to right over `duration`.
struct CountdownLine: View {
    var duration: Double
    var tint: Color = .accentColor
    @State private var left: CGFloat = 1
    var body: some View {
        GeometryReader { g in
            Capsule().fill(tint.opacity(0.85)).frame(width: g.size.width * left)
        }
        .frame(height: 2)
        .onAppear { withAnimation(.linear(duration: max(duration, 0.01))) { left = 0 } }
    }
}

/// An indeterminate shimmer along an edge while Jev thinks.
struct ThinkingLine: View {
    @State private var x: CGFloat = -0.4
    @Environment(\.accessibilityReduceMotion) private var reduce
    var body: some View {
        GeometryReader { g in
            LinearGradient(colors: [.clear, Tone.route.opacity(0.9), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: g.size.width * 0.4)
                .offset(x: g.size.width * x)
        }
        .frame(height: 2)
        .clipped()
        .onAppear {
            guard !reduce else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: false)) { x = 1 }
        }
    }
}
