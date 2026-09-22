import SwiftUI
import AppKit

enum Theme {
    static let body = Font.system(size: 14)
    static let emphasis = Font.system(size: 14, weight: .medium)
    static let heading = Font.system(size: 22, weight: .semibold)
    static let accent = Color(red: 0.12, green: 0.43, blue: 0.74)
    static let canvas = adaptive(light: NSColor(srgbRed: 0.96, green: 0.975, blue: 0.99, alpha: 1), dark: NSColor(srgbRed: 0.08, green: 0.10, blue: 0.13, alpha: 1))
    static let surface = adaptive(light: NSColor.white.withAlphaComponent(0.72), dark: NSColor.white.withAlphaComponent(0.055))
    static let field = adaptive(light: NSColor.white.withAlphaComponent(0.90), dark: NSColor.black.withAlphaComponent(0.18))
    static let border = adaptive(light: NSColor(srgbRed: 0.68, green: 0.80, blue: 0.91, alpha: 0.55), dark: NSColor.white.withAlphaComponent(0.12))
    static let ink = adaptive(light: NSColor(srgbRed: 0.12, green: 0.20, blue: 0.29, alpha: 1), dark: NSColor(srgbRed: 0.86, green: 0.93, blue: 1, alpha: 1))
    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

/// Preserve native control behavior and keep unavailable actions neutral.
struct SecondaryActionAppearance: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content
            .font(Theme.emphasis)
            .buttonStyle(.glass)
            .controlSize(.large)
            .foregroundStyle(isEnabled ? Theme.accent : Color.secondary)
    }
}

struct FieldSurface: ViewModifier {
    func body(content: Content) -> some View {
        content.font(Theme.body).frame(maxWidth: .infinity).padding(.horizontal, 14).frame(height: 44)
            .background(Theme.field, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Theme.border, lineWidth: 0.7))
            .contentShape(RoundedRectangle(cornerRadius: 11))
    }
}
extension View {
    func secondaryActionStyle() -> some View { modifier(SecondaryActionAppearance()) }
    func fieldSurface() -> some View { modifier(FieldSurface()) }
    func contentSurface(radius: CGFloat = 20) -> some View {
        background(Theme.surface, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Theme.border, lineWidth: 0.65))
    }
}
