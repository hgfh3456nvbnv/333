import SwiftUI
import TermCore
import UIKit
import UniformTypeIdentifiers

/// The message box with its menus, plus whatever needs an answer first: an approval or command suggestions.
struct Composer: View {
    @Environment(AppModel.self) private var model
    var inputFocused: FocusState<Bool>.Binding
    @State private var importing = false

    var body: some View {
        @Bindable var model = model
        let palette = model.palette

        VStack(spacing: 8) {
            if let approval = model.pendingApproval {
                ApprovalCard(approval: approval, palette: palette)
            } else if !model.suggestions.isEmpty {
                SuggestionList(palette: palette)
            }

            VStack(alignment: .leading, spacing: 10) {
                // Return starts a new line, as in any chat app; the arrow sends.
                TextField("", text: $model.input, prompt: Text(model.placeholder).foregroundStyle(palette.dim), axis: .vertical)
                    .lineLimit(1...8)
                    .font(palette.prose)
                    .foregroundStyle(palette.text)
                    .tint(palette.accent)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused(inputFocused)

                HStack(spacing: 10) {
                    addMenu(palette)
                    Spacer(minLength: 8)
                    modelButton(palette)
                    sendButton(palette)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)
            .card(palette, radius: 22)

            HStack(spacing: 12) {
                HostMenu(palette: palette)
                Spacer(minLength: 8)
                PermissionMenu(palette: palette)
            }
            .padding(.horizontal, 6)
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .background(palette.background)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                for path in model.importFiles(urls) { model.attach(path: path) }
            }
        }
    }

    private func addMenu(_ palette: Palette) -> some View {
        Menu {
            Button {
                model.panel = .files
            } label: {
                Label("Add workspace file", systemImage: "paperclip")
            }
            Button {
                importing = true
            } label: {
                Label("Import from Files", systemImage: "square.and.arrow.down")
            }
            Button {
                if let text = UIPasteboard.general.string { model.input += text }
            } label: {
                Label("Paste", systemImage: "doc.on.clipboard")
            }
            Divider()
            Button {
                model.input = "/"
                inputFocused.wrappedValue = true
            } label: {
                Label("Commands", systemImage: "command")
            }
            Button {
                model.panel = .settings
            } label: {
                Label("Manage connections", systemImage: "square.grid.2x2")
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(palette.text)
                .frame(width: 32, height: 32)
                .card(palette, fill: palette.code, radius: 9)
        }
        .accessibilityLabel("Add")
    }

    private func modelButton(_ palette: Palette) -> some View {
        Button {
            model.panel = .models
        } label: {
            HStack(spacing: 4) {
                Text(model.modelLabel)
                    .font(palette.label)
                    .foregroundStyle(palette.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(palette.dim)
            }
            .frame(height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Model: \(model.modelLabel)")
    }

    private func sendButton(_ palette: Palette) -> some View {
        let canSend = !model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let isActive = model.isRunning || canSend
        return Button {
            if model.isRunning {
                model.cancel()
            } else {
                model.submit()
            }
        } label: {
            Image(systemName: model.isRunning ? "stop.fill" : "arrow.up")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isActive ? palette.onAccent : palette.dim)
                .frame(width: 32, height: 32)
                .background(isActive ? palette.accent : palette.border, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isActive)
        .accessibilityLabel(model.isRunning ? "Stop" : "Send")
    }
}

// MARK: Menus under the message box

/// Where commands run: one of the SSH hosts, or nowhere but the device.
private struct HostMenu: View {
    @Environment(AppModel.self) private var model
    let palette: Palette

    var body: some View {
        Menu {
            Section("Environment") {
                ForEach(model.hosts) { host in
                    Toggle(isOn: Binding(get: { model.activeHost?.id == host.id }, set: { _ in model.selectHost(host.id) })) {
                        Text(host.name)
                        Text(host.address)
                    }
                }
                Toggle(isOn: Binding(get: { model.activeHost == nil }, set: { _ in model.selectHost(nil) })) {
                    Text("On device")
                    Text("Workspace files and web requests only")
                }
            }
            Button {
                model.panel = .settings
            } label: {
                Label("Manage SSH hosts", systemImage: "gearshape")
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: model.activeHost == nil ? "iphone" : "server.rack")
                Text(model.activeHost?.name ?? "On device").lineLimit(1)
            }
            .font(palette.label)
            .foregroundStyle(palette.dim)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Environment")
    }
}

private struct PermissionMenu: View {
    @Environment(AppModel.self) private var model
    let palette: Palette

    var body: some View {
        let current = model.settings.approvalMode
        Menu {
            Section("Permissions") {
                ForEach(ApprovalMode.allCases, id: \.self) { mode in
                    Toggle(isOn: Binding(get: { current == mode }, set: { _ in model.setApprovalMode(mode) })) {
                        Text(mode.title)
                        Text(mode.summary)
                    }
                }
            }
        } label: {
            Text(current.title)
                .font(palette.label)
                .foregroundStyle(current == .auto ? palette.accent : palette.dim)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(palette.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .accessibilityLabel("Permissions: \(current.title)")
    }
}

// MARK: Above the message box

private struct SuggestionList: View {
    @Environment(AppModel.self) private var model
    let palette: Palette

    var body: some View {
        let commands = model.suggestions
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(commands, id: \.name) { command in
                    Button {
                        model.input = "/\(command.name) "
                    } label: {
                        HStack(spacing: 10) {
                            Text("/\(command.name)").font(palette.mono).foregroundStyle(palette.accent)
                            Text(command.help).font(palette.label).foregroundStyle(palette.dim).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 38)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        // Five rows at most; the rest scroll.
        .frame(height: CGFloat(min(commands.count, 5)) * 38)
        .padding(.vertical, 4)
        .card(palette, radius: 14)
    }
}

private struct ApprovalCard: View {
    @Environment(AppModel.self) private var model
    let approval: PendingApproval
    let palette: Palette

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Allow this action?").font(palette.labelBold).foregroundStyle(palette.text)
            Text(approval.summary)
                .font(palette.monoSmall)
                .foregroundStyle(palette.text)
                .lineLimit(6)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(palette.code, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            HStack(spacing: 8) {
                choice("Deny", filled: false) { model.resolveApproval(.deny) }
                choice("Always allow", filled: false) { model.allowAlways() }
                choice("Allow", filled: true) { model.resolveApproval(.allow) }
            }
        }
        .padding(14)
        .card(palette, radius: 16)
    }

    private func choice(_ label: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(palette.labelBold)
                .foregroundStyle(filled ? palette.onAccent : palette.text)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .background(filled ? palette.accent : palette.code, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(filled ? palette.accent : palette.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
