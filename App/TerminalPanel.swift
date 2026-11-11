import SwiftUI
import TermCore

/// A terminal on the selected SSH host for running commands by hand. Nothing here reaches the chat.
struct TerminalPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var model = model
        let palette = model.palette

        NavigationStack {
            VStack(spacing: 0) {
                GeometryReader { geometry in
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 12) {
                                banner(palette)
                                ForEach(model.terminalItems) { item in
                                    TerminalEntry(item: item, palette: palette)
                                }
                                Color.clear.frame(height: 1).id("bottom")
                            }
                            .padding(14)
                            // A short log starts at the top, like a fresh terminal.
                            .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .topLeading)
                        }
                        .defaultScrollAnchor(.bottom)
                        .scrollDismissesKeyboard(.interactively)
                        .onChange(of: model.terminalItems.count) {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                }

                Rectangle().fill(palette.border).frame(height: 1)
                HStack(spacing: 10) {
                    Text("$").font(palette.monoBold).foregroundStyle(palette.accent)
                    TextField("", text: $model.terminalInput, prompt: Text("command").foregroundStyle(palette.dim))
                        .font(palette.mono)
                        .foregroundStyle(palette.text)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .focused($focused)
                        .onSubmit(run)
                        .disabled(model.activeHost == nil)
                    Button {
                        if model.isRunning {
                            model.cancel()
                        } else {
                            run()
                        }
                    } label: {
                        Image(systemName: model.isRunning ? "stop.fill" : "return")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(palette.text)
                            .frame(width: 36, height: 32)
                            .card(palette, fill: palette.code, radius: 8)
                    }
                    .buttonStyle(.plain)
                    .disabled(model.activeHost == nil)
                    .accessibilityLabel(model.isRunning ? "Stop" : "Run")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .background(palette.background.ignoresSafeArea())
            .navigationTitle("Terminal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        model.clearTerminal()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel("Clear")
                    .disabled(model.terminalItems.isEmpty)
                }
            }
        }
    }

    private func run() {
        model.runTerminalCommand()
        DispatchQueue.main.async { focused = true }
    }

    @ViewBuilder
    private func banner(_ palette: Palette) -> some View {
        if let host = model.activeHost {
            Text("\(host.address)\nCommands run on this host over SSH and stay out of the chat.")
                .font(palette.monoSmall)
                .foregroundStyle(palette.dim)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("No SSH host selected. Add one, or pick one below the message box.")
                    .font(palette.label)
                    .foregroundStyle(palette.dim)
                Button {
                    model.panel = .settings
                } label: {
                    Text("Open settings")
                        .font(palette.labelBold)
                        .foregroundStyle(palette.text)
                        .padding(.horizontal, 14)
                        .frame(height: 36)
                        .card(palette, fill: palette.code, radius: 9)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct TerminalEntry: View {
    let item: TranscriptItem
    let palette: Palette

    var body: some View {
        switch item.kind {
        case .tool:
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("$").foregroundStyle(palette.accent)
                    Text(item.title ?? "").foregroundStyle(palette.text)
                }
                .font(palette.monoBold)
                if !item.text.isEmpty {
                    Text(item.text)
                        .font(palette.mono)
                        .foregroundStyle(item.status == .failed ? palette.error : palette.text)
                        .textSelection(.enabled)
                }
                if item.status == .running {
                    ProgressView().controlSize(.small)
                }
            }
        case .error:
            Text(item.text).font(palette.mono).foregroundStyle(palette.error).textSelection(.enabled)
        default:
            Text(item.text).font(palette.mono).foregroundStyle(palette.dim)
        }
    }
}
