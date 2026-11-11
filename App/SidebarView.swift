import SwiftUI
import TermCore

/// The drawer: navigation, saved sessions and the active gateway.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var searching = false
    @FocusState private var searchFocused: Bool

    private var sessions: [SessionSummary] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        return needle.isEmpty ? model.sessions : model.sessions.filter { $0.title.localizedCaseInsensitiveContains(needle) }
    }

    var body: some View {
        let palette = model.palette
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                SparkMark(size: 20, color: palette.accent)
                Text("TermAI").font(.system(size: 17, weight: .semibold)).foregroundStyle(palette.text)
                Spacer(minLength: 0)
                IconButton(systemName: "sidebar.left", label: "Close", color: palette.text) {
                    model.showSidebar = false
                }
            }
            .padding(.leading, 18)
            .padding(.trailing, 6)
            .frame(height: 48)

            VStack(spacing: 2) {
                NavRow(icon: "plus", title: "New session", isActive: false, palette: palette) {
                    model.startNewSession()
                    model.showSidebar = false
                }
                NavRow(icon: "magnifyingglass", title: "Search", isActive: searching, palette: palette) {
                    searching.toggle()
                    searchFocused = searching
                    if !searching { query = "" }
                }
                NavRow(icon: "folder", title: "Files", isActive: false, palette: palette) { open(.files) }
                NavRow(icon: "terminal", title: "Terminal", isActive: false, palette: palette) { open(.terminal) }
                NavRow(icon: "briefcase", title: "Customize", isActive: false, palette: palette) { open(.settings) }
            }
            .padding(.horizontal, 8)

            if searching {
                TextField("", text: $query, prompt: Text("Search sessions").foregroundStyle(palette.dim))
                    .font(palette.label)
                    .foregroundStyle(palette.text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($searchFocused)
                    .padding(.horizontal, 12)
                    .frame(height: 38)
                    .card(palette, fill: palette.background, radius: 10)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
            }

            Text("Recents")
                .font(palette.caption.weight(.medium))
                .foregroundStyle(palette.dim)
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 6)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(sessions) { summary in
                        SessionRow(summary: summary, palette: palette)
                    }
                    if sessions.isEmpty {
                        Text(model.sessions.isEmpty ? "Sessions you start will show up here." : "No matching sessions.")
                            .font(palette.label)
                            .foregroundStyle(palette.dim)
                            .padding(.horizontal, 12)
                            .padding(.top, 4)
                    }
                }
                .padding(.horizontal, 8)
            }

            Rectangle().fill(palette.border).frame(height: 1)
            footer(palette)
        }
        .frame(width: 300)
        .frame(maxHeight: .infinity)
        .background(palette.sidebar.ignoresSafeArea())
        .overlay(alignment: .trailing) {
            Rectangle().fill(palette.border).frame(width: 1).ignoresSafeArea()
        }
        .gesture(DragGesture(minimumDistance: 24).onEnded { value in
            if value.translation.width < -60 { model.showSidebar = false }
        })
    }

    private func open(_ panel: Panel) {
        model.showSidebar = false
        model.panel = panel
    }

    private func footer(_ palette: Palette) -> some View {
        HStack(spacing: 4) {
            Menu {
                Section("Gateway") {
                    ForEach(model.profiles) { profile in
                        Toggle(isOn: Binding(get: { model.activeProfile?.id == profile.id }, set: { _ in model.select(profile: profile) })) {
                            Text(profile.name)
                            Text(profile.baseURL)
                        }
                    }
                }
                Button {
                    open(.connection(nil))
                } label: {
                    Label("Add connection", systemImage: "plus")
                }
            } label: {
                HStack(spacing: 8) {
                    SparkMark(size: 18, color: palette.accent)
                    Text(model.activeProfile?.name ?? "No connection")
                        .font(palette.labelBold)
                        .foregroundStyle(palette.text)
                        .lineLimit(1)
                    Text("· Gateway").font(palette.caption).foregroundStyle(palette.dim).lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(palette.dim)
                }
                .frame(height: 40)
                .contentShape(Rectangle())
            }
            Spacer(minLength: 0)
            IconButton(systemName: "gearshape", label: "Settings", color: palette.dim) { open(.settings) }
        }
        .padding(.leading, 18)
        .padding(.trailing, 6)
        .frame(height: 54)
    }
}

private struct NavRow: View {
    let icon: String
    let title: String
    let isActive: Bool
    let palette: Palette
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 16)).frame(width: 22)
                Text(title).font(palette.prose)
                Spacer(minLength: 0)
            }
            .foregroundStyle(palette.text)
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(isActive ? palette.surface : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct SessionRow: View {
    @Environment(AppModel.self) private var model
    let summary: SessionSummary
    let palette: Palette

    var body: some View {
        let isCurrent = summary.id == model.session.id
        Button {
            model.openSession(summary.id)
            model.showSidebar = false
        } label: {
            HStack(spacing: 8) {
                Text(summary.title)
                    .font(palette.label)
                    .foregroundStyle(palette.text)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(summary.updatedAt.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))
                    .font(palette.caption)
                    .foregroundStyle(palette.dim)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(isCurrent ? palette.surface : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                model.deleteSession(summary.id)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}
