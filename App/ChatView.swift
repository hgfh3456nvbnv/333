import SwiftUI
import TermCore

/// The main screen: top bar, transcript and message box, with the session drawer sliding over it.
struct ChatView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var inputFocused: Bool

    var body: some View {
        @Bindable var model = model
        let palette = model.palette

        ZStack(alignment: .leading) {
            VStack(spacing: 0) {
                TopBar()
                if model.session.transcript.isEmpty {
                    EmptyState()
                } else {
                    TranscriptView()
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Composer(inputFocused: $inputFocused)
            }
            .background(palette.background.ignoresSafeArea())

            if model.showSidebar {
                Color.black.opacity(0.45)
                    .ignoresSafeArea()
                    .onTapGesture { model.showSidebar = false }
                    .transition(.opacity)
                SidebarView()
                    .transition(.move(edge: .leading))
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.showSidebar)
        .onChange(of: model.showSidebar) {
            if model.showSidebar { inputFocused = false }
        }
        .preferredColorScheme(model.theme.isDark ? .dark : .light)
        .tint(palette.accent)
        .sheet(item: $model.panel) { panel in
            PanelView(panel: panel)
        }
        .sheet(item: $model.shareItem) { item in
            ShareSheet(text: item.text)
        }
    }
}

private struct PanelView: View {
    @Environment(AppModel.self) private var model
    let panel: Panel

    var body: some View {
        Group {
            switch panel {
            case .settings:
                SettingsView()
            case .connection(let profileID):
                NavigationStack {
                    ConnectionEditor(model: model, profileID: profileID, isModal: true)
                }
            case .models:
                ModelPicker()
            case .files:
                FilesPanel()
            case .terminal:
                TerminalPanel()
            }
        }
        .tint(model.palette.accent)
        .preferredColorScheme(model.theme.isDark ? .dark : .light)
    }
}

// MARK: Top bar

private struct TopBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let palette = model.palette
        HStack(spacing: 0) {
            IconButton(systemName: "sidebar.left", label: "Sessions", color: palette.text) {
                model.showSidebar = true
            }
            Text(model.session.isEmpty ? "New session" : model.session.title)
                .font(palette.label)
                .foregroundStyle(palette.dim)
                .lineLimit(1)
                .padding(.leading, 2)
            Spacer(minLength: 8)
            IconButton(systemName: "terminal", label: "Terminal", color: palette.text) {
                model.panel = .terminal
            }
            IconButton(systemName: "folder", label: "Files", color: palette.text) {
                model.panel = .files
            }
            IconButton(systemName: "square.and.pencil", label: "New session", color: palette.text) {
                model.startNewSession()
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 44)
    }
}

// MARK: Empty state

private struct EmptyState: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let palette = model.palette
        VStack(spacing: 20) {
            Spacer(minLength: 0)
            HStack(spacing: 12) {
                SparkMark(size: 30, color: palette.accent)
                Text(model.profiles.isEmpty ? "Welcome" : "Ready when you are")
                    .font(palette.display)
                    .foregroundStyle(palette.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            if model.profiles.isEmpty {
                Text("Connect any OpenAI-compatible endpoint with your own base URL, API key and models.")
                    .font(palette.label)
                    .foregroundStyle(palette.dim)
                    .multilineTextAlignment(.center)
                Button {
                    model.panel = .connection(nil)
                } label: {
                    Text("Add connection")
                        .font(palette.labelBold)
                        .foregroundStyle(palette.onAccent)
                        .padding(.horizontal, 20)
                        .frame(height: 42)
                        .background(palette.accent, in: Capsule())
                }
                .buttonStyle(.plain)
            } else {
                QuickActions(palette: palette)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Shortcuts to the two side panels, shown while the session is still empty.
private struct QuickActions: View {
    @Environment(AppModel.self) private var model
    let palette: Palette

    var body: some View {
        VStack(spacing: 0) {
            row("folder", "Workspace files") { model.panel = .files }
            Rectangle().fill(palette.border).frame(height: 1)
            row("terminal", model.activeHost.map { "Terminal on \($0.name)" } ?? "Terminal") { model.panel = .terminal }
        }
        .card(palette, fill: palette.background)
        .frame(maxWidth: 300)
    }

    private func row(_ icon: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).frame(width: 22)
                Text(title)
                Spacer(minLength: 0)
            }
            .font(palette.label)
            .foregroundStyle(palette.text)
            .padding(.horizontal, 14)
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
