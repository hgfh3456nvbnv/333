import Foundation

/// Colour palette as 0xRRGGBB values so the core stays UI-framework free.
public struct Theme: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var isDark: Bool
    public var background: UInt32
    /// The session drawer.
    public var sidebar: UInt32
    /// Raised surfaces: the message box, cards and the user's messages.
    public var surface: UInt32
    public var border: UInt32
    public var text: UInt32
    public var dim: UInt32
    public var accent: UInt32
    public var error: UInt32
    public var success: UInt32
    public var codeBackground: UInt32
    /// Phosphor-style glow behind text.
    public var glow: Bool

    public static let minimalDark = Theme(
        id: "dark", name: "Dark", isDark: true,
        background: 0x1C1C1B, sidebar: 0x212120, surface: 0x2C2C2A, border: 0x3C3B38,
        text: 0xEEECE5, dim: 0x9C9A92, accent: 0xD97757,
        error: 0xE5675F, success: 0x78B98A, codeBackground: 0x242423, glow: false)

    public static let crtGreen = Theme(
        id: "crt-green", name: "CRT Green", isDark: true,
        background: 0x020A04, sidebar: 0x041007, surface: 0x06180B, border: 0x124A22,
        text: 0x4AF07A, dim: 0x24914A, accent: 0xB6FFC8,
        error: 0xFF6B5E, success: 0x4AF07A, codeBackground: 0x041208, glow: true)

    public static let crtAmber = Theme(
        id: "crt-amber", name: "CRT Amber", isDark: true,
        background: 0x0B0700, sidebar: 0x120C02, surface: 0x1A1103, border: 0x4D340A,
        text: 0xFFB43C, dim: 0xA06A14, accent: 0xFFE2A8,
        error: 0xFF6B5E, success: 0xFFB43C, codeBackground: 0x140D02, glow: true)

    public static let light = Theme(
        id: "light", name: "Light", isDark: false,
        background: 0xFAF9F5, sidebar: 0xF3F1EA, surface: 0xFFFFFF, border: 0xDEDCD1,
        text: 0x1F1E1D, dim: 0x76746C, accent: 0xC96442,
        error: 0xB93A32, success: 0x2F7D4F, codeBackground: 0xF0EEE6, glow: false)

    public static let all: [Theme] = [.minimalDark, .light, .crtGreen, .crtAmber]

    public static func named(_ id: String) -> Theme {
        all.first { $0.id == id } ?? .minimalDark
    }
}
