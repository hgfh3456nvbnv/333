import SwiftUI
import TermCore

@main
struct TermAIApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ChatView()
                .environment(model)
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255)
    }
}

/// SwiftUI colours and fonts for the active theme.
struct Palette {
    let theme: Theme
    /// Size of code and terminal text. Prose is set a little larger.
    let fontSize: Double

    var background: Color { Color(hex: theme.background) }
    var sidebar: Color { Color(hex: theme.sidebar) }
    var surface: Color { Color(hex: theme.surface) }
    var border: Color { Color(hex: theme.border) }
    var text: Color { Color(hex: theme.text) }
    var dim: Color { Color(hex: theme.dim) }
    var accent: Color { Color(hex: theme.accent) }
    var error: Color { Color(hex: theme.error) }
    var success: Color { Color(hex: theme.success) }
    var code: Color { Color(hex: theme.codeBackground) }
    /// Foreground for content drawn on the accent colour.
    var onAccent: Color { theme.glow ? background : .white }

    var prose: Font { .system(size: fontSize + 3) }
    var proseBold: Font { .system(size: fontSize + 3, weight: .semibold) }
    var label: Font { .system(size: fontSize + 1) }
    var labelBold: Font { .system(size: fontSize + 1, weight: .semibold) }
    var caption: Font { .system(size: max(fontSize - 1, 10)) }
    var mono: Font { .system(size: fontSize, design: .monospaced) }
    var monoBold: Font { .system(size: fontSize, weight: .semibold, design: .monospaced) }
    var monoSmall: Font { .system(size: max(fontSize - 1, 9), design: .monospaced) }
    /// The serif used for the greeting.
    var display: Font { .system(size: 30, design: .serif) }

    func heading(_ level: Int) -> Font {
        let step: Double = level <= 1 ? 8 : (level == 2 ? 6 : 4)
        return .system(size: fontSize + step, weight: .semibold)
    }
}
