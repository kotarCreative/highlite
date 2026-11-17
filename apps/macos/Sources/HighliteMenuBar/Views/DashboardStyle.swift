import AppKit
import SwiftUI

/// A semantic color with separate light and dark values.
///
/// Storing the raw sRGB values keeps the palette testable while the dynamic
/// `NSColor` lets AppKit resolve the right appearance at draw time.
struct DashboardPaletteColor {
    let light: UInt32
    let dark: UInt32

    var color: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(highliteHex: isDark ? dark : light)
        })
    }
}

/// Semantic tokens mirroring `crates/highlite-relay/src/ui-theme.css`.
///
/// The highlighter accents stay vivid in both appearances, so text placed on
/// them uses `actionInk` rather than a light foreground. Status colors remain
/// semantic and are not reused as decoration.
enum DashboardPalette {
    static let canvas = DashboardPaletteColor(light: 0xFFFDF5, dark: 0x1B1519)
    static let surface = DashboardPaletteColor(light: 0xFFFFFF, dark: 0x241D22)
    static let surfaceMuted = DashboardPaletteColor(light: 0xFFFBF0, dark: 0x2A2228)
    static let ink = DashboardPaletteColor(light: 0x30232D, dark: 0xF7EFE8)
    static let muted = DashboardPaletteColor(light: 0x75636C, dark: 0xC4B2BC)
    static let line = DashboardPaletteColor(light: 0xEADFDA, dark: 0x40333B)
    static let lineStrong = DashboardPaletteColor(light: 0xC9B7BD, dark: 0x5B4A54)
    static let primary = DashboardPaletteColor(light: 0xA92261, dark: 0xFF81BD)
    static let primaryHover = DashboardPaletteColor(light: 0x86194D, dark: 0xFF9DCC)
    static let primarySoft = DashboardPaletteColor(light: 0xFFF0F6, dark: 0x3A2230)
    static let primaryBorder = DashboardPaletteColor(light: 0xF5B8D3, dark: 0x7A3B5D)
    static let highlightYellow = DashboardPaletteColor(light: 0xEFFF3D, dark: 0xEFFF3D)
    static let highlightOrange = DashboardPaletteColor(light: 0xFFAD60, dark: 0xFFAD60)
    static let highlightPink = DashboardPaletteColor(light: 0xFF81BD, dark: 0xFF81BD)
    static let action = DashboardPaletteColor(light: 0xEFFF3D, dark: 0xEFFF3D)
    static let actionHover = DashboardPaletteColor(light: 0xE0EF2A, dark: 0xD7E62B)
    static let actionInk = DashboardPaletteColor(light: 0x30232D, dark: 0x30232D)
    static let success = DashboardPaletteColor(light: 0x087443, dark: 0x5BD39A)
    static let successSoft = DashboardPaletteColor(light: 0xE9F7EF, dark: 0x173528)
    static let danger = DashboardPaletteColor(light: 0xB4232D, dark: 0xFF7B81)
    static let dangerSoft = DashboardPaletteColor(light: 0xFFF0F0, dark: 0x3A1E20)
    static let warning = DashboardPaletteColor(light: 0x9A5700, dark: 0xFFC46B)
    static let warningSoft = DashboardPaletteColor(light: 0xFFF5E5, dark: 0x382A16)
    static let neutralSoft = DashboardPaletteColor(light: 0xF3EEE8, dark: 0x332B30)
    static let shadow = DashboardPaletteColor(light: 0x30232D, dark: 0x000000)
}

enum DashboardTheme {
    static let canvas = DashboardPalette.canvas.color
    static let surface = DashboardPalette.surface.color
    static let surfaceMuted = DashboardPalette.surfaceMuted.color
    static let ink = DashboardPalette.ink.color
    static let muted = DashboardPalette.muted.color
    static let line = DashboardPalette.line.color
    static let lineStrong = DashboardPalette.lineStrong.color
    static let primary = DashboardPalette.primary.color
    static let primaryHover = DashboardPalette.primaryHover.color
    static let primarySoft = DashboardPalette.primarySoft.color
    static let primaryBorder = DashboardPalette.primaryBorder.color
    static let highlightYellow = DashboardPalette.highlightYellow.color
    static let highlightOrange = DashboardPalette.highlightOrange.color
    static let highlightPink = DashboardPalette.highlightPink.color
    static let action = DashboardPalette.action.color
    static let actionHover = DashboardPalette.actionHover.color
    static let actionInk = DashboardPalette.actionInk.color
    static let success = DashboardPalette.success.color
    static let successSoft = DashboardPalette.successSoft.color
    static let danger = DashboardPalette.danger.color
    static let dangerSoft = DashboardPalette.dangerSoft.color
    static let warning = DashboardPalette.warning.color
    static let warningSoft = DashboardPalette.warningSoft.color
    static let neutralSoft = DashboardPalette.neutralSoft.color
    static let shadow = DashboardPalette.shadow.color
}

/// The marker action: yellow paint with dark ink and a crisp offset edge.
///
/// A custom style is required because native prominent buttons assume a dark
/// tint and would choose white text on the highlighter yellow.
struct HighlitePrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .foregroundStyle(DashboardTheme.actionInk)
            .background(
                RoundedRectangle(cornerRadius: DashboardStyle.controlCornerRadius)
                    .fill(configuration.isPressed ? DashboardTheme.actionHover : DashboardTheme.action)
            )
            .overlay {
                RoundedRectangle(cornerRadius: DashboardStyle.controlCornerRadius)
                    .strokeBorder(DashboardTheme.actionInk.opacity(0.85), lineWidth: 1)
            }
            .shadow(color: DashboardTheme.actionInk.opacity(0.18), radius: 0, x: 2, y: 2)
            .opacity(isEnabled ? 1 : 0.55)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
    }
}

/// Shared spacing, surface, and type conventions for the dashboard.
enum DashboardStyle {
    static let pagePadding: CGFloat = 18
    static let cardPadding: CGFloat = 14
    static let sectionSpacing: CGFloat = 14
    static let controlSpacing: CGFloat = 10
    static let headerVerticalPadding: CGFloat = 10

    static let cardCornerRadius: CGFloat = 10
    static let controlCornerRadius: CGFloat = 7
    static let codeCornerRadius: CGFloat = 8
    static let codeFontSize: CGFloat = 11

    /// Keeps a copy action from changing width when its label switches to a
    /// shorter confirmation. Longer localized labels can still grow.
    static let copyButtonMinimumWidth: CGFloat = 168
    static let emptyStateMinimumHeight: CGFloat = 120
}

private extension NSColor {
    convenience init(highliteHex hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
