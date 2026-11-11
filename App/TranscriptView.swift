import SwiftUI
import TermCore
import UIKit

struct TranscriptView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let palette = model.palette
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(model.session.transcript) { item in
                            ItemView(item: item, palette: palette)
                        }
                        if model.isRunning {
                            if model.pendingApproval == nil { WorkingIndicator(palette: palette) }
                        } else {
                            RunFooter(palette: palette)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    // A short transcript starts at the top rather than hugging the message box.
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .topLeading)
                    .shadow(color: model.theme.glow ? palette.text.opacity(0.55) : .clear, radius: 3)
                }
                // Stay pinned to the newest output while it streams, unless the user scrolls up.
                .defaultScrollAnchor(.bottom)
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: model.scrollTick) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }
}

private struct ItemView: View {
    let item: TranscriptItem
    let palette: Palette

    var body: some View {
        switch item.kind {
        case .user:
            HStack(spacing: 0) {
                Spacer(minLength: 44)
                Text(item.text)
                    .font(palette.prose)
                    .foregroundStyle(palette.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(palette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        case .assistant:
            MarkdownView(text: item.text, palette: palette)
        case .tool:
            ToolBlock(item: item, palette: palette)
        case .info:
            // Command output is column-aligned, so it stays monospaced.
            Text(item.text).font(palette.monoSmall).foregroundStyle(palette.dim).textSelection(.enabled)
        case .error:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                Text(item.text).textSelection(.enabled)
            }
            .font(palette.label)
            .foregroundStyle(palette.error)
        }
    }
}

/// A tool call: one line saying what ran, with the end of its output underneath. Tap to see more.
private struct ToolBlock: View {
    let item: TranscriptItem
    let palette: Palette
    @State private var expanded = false

    private var lines: [Substring] {
        item.text.split(separator: "\n", omittingEmptySubsequences: false)
    }

    /// Output is shown from the end, where the result usually is.
    private var shown: String {
        let limit = expanded ? 60 : 6
        let all = lines
        guard all.count > limit else { return item.text }
        return "… \(all.count - limit) earlier lines\n" + all.suffix(limit).joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                status
                    .frame(width: 16, height: 16)
                Text(item.title ?? "tool")
                    .font(palette.monoSmall)
                    .foregroundStyle(palette.text)
                    .lineLimit(expanded ? nil : 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if lines.count > 6 {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(palette.dim)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
            }
            if !item.text.isEmpty {
                Text(shown)
                    .font(palette.monoSmall)
                    .foregroundStyle(palette.dim)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .card(palette, fill: palette.code, radius: 10)
        .contentShape(Rectangle())
        .onTapGesture { expanded.toggle() }
    }

    @ViewBuilder private var status: some View {
        switch item.status {
        case .running: ProgressView().controlSize(.mini)
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(palette.success)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(palette.error)
        case .denied: Image(systemName: "minus.circle").foregroundStyle(palette.dim)
        case nil: Image(systemName: "circle").foregroundStyle(palette.dim)
        }
    }
}

private struct WorkingIndicator: View {
    let palette: Palette
    @State private var pulsing = false

    var body: some View {
        HStack(spacing: 8) {
            SparkMark(size: 14, color: palette.accent)
                .opacity(pulsing ? 0.3 : 1)
                .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulsing)
            Text("Working…").font(palette.label).foregroundStyle(palette.dim)
        }
        .onAppear { pulsing = true }
    }
}

/// Shown under a finished answer: quick actions and the token count.
private struct RunFooter: View {
    @Environment(AppModel.self) private var model
    let palette: Palette
    @State private var copied = false

    var body: some View {
        if model.lastAnswer != nil {
            HStack(spacing: 4) {
                IconButton(systemName: copied ? "checkmark" : "doc.on.doc", label: "Copy answer", color: palette.dim) {
                    model.copyLastAnswer()
                    copied = true
                }
                IconButton(systemName: "arrow.clockwise", label: "Retry", color: palette.dim) {
                    model.retry()
                }
                if let usage = model.usageLine {
                    Text(usage).font(palette.caption).foregroundStyle(palette.dim).padding(.leading, 4)
                }
            }
            .padding(.leading, -10)
            .task(id: copied) {
                guard copied else { return }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                copied = false
            }
        }
    }
}

// MARK: Markdown

/// Renders an assistant message: headings, lists, quotes, tables and fenced code.
struct MarkdownView: View {
    let text: String
    let palette: Palette

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(Markdown.blocks(text).enumerated()), id: \.offset) { _, block in
                BlockView(block: block, palette: palette)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct BlockView: View {
    let block: Markdown.Block
    let palette: Palette

    var body: some View {
        switch block {
        case .paragraph(let text):
            prose(text, palette.prose)
        case .heading(let level, let text):
            prose(text, palette.heading(level))
                .padding(.top, 4)
        case .listItem(let marker, let indent, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker).font(palette.prose).foregroundStyle(palette.dim)
                prose(text, palette.prose)
            }
            .padding(.leading, CGFloat(indent) * 16)
        case .quote(let text):
            prose(text, palette.prose)
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    Rectangle().fill(palette.border).frame(width: 3)
                }
        case .code(let language, let text):
            CodeBlock(code: text, language: language, palette: palette)
        case .table(let rows):
            TableBlock(rows: rows, palette: palette)
        case .rule:
            Rectangle().fill(palette.border).frame(height: 1)
        }
    }

    private func prose(_ text: String, _ font: Font) -> some View {
        Text(InlineMarkdown.render(text, codeColor: palette.accent))
            .font(font)
            .foregroundStyle(palette.text)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum InlineMarkdown {
    /// Bold, italics, links and `code` within one block; inline code takes `codeColor`.
    static func render(_ text: String, codeColor: Color) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        guard var result = try? AttributedString(markdown: text, options: options) else { return AttributedString(text) }
        let codeRanges = result.runs.compactMap { run -> Range<AttributedString.Index>? in
            run.inlinePresentationIntent?.contains(.code) == true ? run.range : nil
        }
        for range in codeRanges {
            result[range].foregroundColor = codeColor
        }
        return result
    }
}

private struct CodeBlock: View {
    let code: String
    let language: String?
    let palette: Palette
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? "code").font(palette.caption).foregroundStyle(palette.dim)
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(palette.caption)
                        .foregroundStyle(palette.dim)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(palette.mono)
                    .foregroundStyle(palette.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(palette, fill: palette.code, radius: 10)
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copied = false
        }
    }
}

private struct TableBlock: View {
    let rows: [[String]]
    let palette: Palette

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(InlineMarkdown.render(cell, codeColor: palette.accent))
                                .font(index == 0 ? palette.labelBold : palette.label)
                                .foregroundStyle(palette.text)
                        }
                    }
                    if index == 0 {
                        Rectangle().fill(palette.border).frame(height: 1).gridCellUnsizedAxes(.horizontal)
                    }
                }
            }
            .padding(12)
        }
        .card(palette, fill: palette.code, radius: 10)
    }
}
