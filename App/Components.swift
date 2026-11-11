import SwiftUI
import UIKit

/// The app's mark: a twelve-point burst.
struct SparkMark: View {
    var size: CGFloat = 28
    let color: Color

    var body: some View {
        ZStack {
            ForEach(0..<6, id: \.self) { index in
                Capsule()
                    .fill(color)
                    .frame(width: size * 0.12, height: size)
                    .rotationEffect(.degrees(Double(index) * 30))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A borderless icon button with a comfortable touch target.
struct IconButton: View {
    let systemName: String
    let label: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 17))
                .foregroundStyle(color)
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

extension View {
    /// Rounded fill with a hairline border.
    func card(_ palette: Palette, fill: Color? = nil, radius: CGFloat = 12) -> some View {
        background(fill ?? palette.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(palette.border, lineWidth: 1))
    }

    /// Theme colours for a `Form` or `List`.
    func themedList(_ palette: Palette) -> some View {
        scrollContentBackground(.hidden)
            .background(palette.background.ignoresSafeArea())
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let text: String

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [text], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
