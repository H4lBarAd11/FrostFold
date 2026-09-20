import SwiftUI
import AppKit

/// Sage and caramel, taken from the palette used across these projects.
///
/// The light values are the canonical ones. That palette is light-only, so the
/// dark values here are derived — the same hues lifted until they hold against
/// a dark panel — rather than being part of the original system.
enum Palette {

    // Accents.
    /// #6E8B6E. The primary accent: controls, and the state of things.
    static let sage        = dynamic(light: 0x6E8B6E, dark: 0x9DBA9D)
    /// #4F6650. Contrast-safe for small text on a tint.
    static let sageDeep    = dynamic(light: 0x4F6650, dark: 0xB8D0B8)
    /// #EFF3EF. The wash behind a grouped section.
    static let sageTint    = dynamic(light: 0xEFF3EF, dark: 0x1E2620)

    /// #B5651D. The secondary accent: section headings, and the warm edge in
    /// the icon.
    static let caramel     = dynamic(light: 0xB5651D, dark: 0xE08B3C)
    /// #8C4C14. Contrast-safe for small text on a tint.
    static let caramelDeep = dynamic(light: 0x8C4C14, dark: 0xEFA664)
    static let caramelTint = dynamic(light: 0xFBF3E8, dark: 0x2A2018)

    // Ground. Ivory rather than flat white, as in the original.
    static let background  = dynamic(light: 0xF9F8EF, dark: 0x1C1C1A)
    static let surface     = dynamic(light: 0xFFFFFF, dark: 0x252524)
    static let ink         = dynamic(light: 0x404040, dark: 0xE8E6DE)
    static let inkSoft     = dynamic(light: 0x7A7A76, dark: 0x9C9C96)
    static let line        = dynamic(light: 0xD9D5C4, dark: 0x3A3A36)

    static var sageColor: Color        { Color(nsColor: sage) }
    static var sageDeepColor: Color    { Color(nsColor: sageDeep) }
    static var sageTintColor: Color    { Color(nsColor: sageTint) }
    static var caramelColor: Color     { Color(nsColor: caramel) }
    static var caramelDeepColor: Color { Color(nsColor: caramelDeep) }
    static var backgroundColor: Color  { Color(nsColor: background) }
    static var inkColor: Color         { Color(nsColor: ink) }
    static var inkSoftColor: Color     { Color(nsColor: inkSoft) }
    static var lineColor: Color        { Color(nsColor: line) }

    private static func dynamic(light: Int, dark: Int) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return rgb(isDark ? dark : light)
        }
    }

    private static func rgb(_ hex: Int) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green:   CGFloat((hex >> 8) & 0xFF) / 255,
                blue:    CGFloat(hex & 0xFF) / 255,
                alpha: 1)
    }
}
