import Foundation

public enum Markdown {
    public struct Segment: Equatable, Sendable {
        public var isCode: Bool
        public var text: String
        /// The tag after the opening fence, e.g. `swift`.
        public var language: String?
    }

    /// A block-level element of a message. Inline syntax (bold, links, `code`) stays in the text.
    public enum Block: Equatable, Sendable {
        case paragraph(String)
        case heading(level: Int, text: String)
        /// `marker` is "•" for bullets or the number as written ("2."); `indent` is the nesting level.
        case listItem(marker: String, indent: Int, text: String)
        case quote(String)
        case code(language: String?, text: String)
        /// Rows of cells; the first row is the header.
        case table([[String]])
        case rule
    }

    /// Splits text into prose and fenced code blocks. An unclosed fence (mid-stream) is treated as code.
    public static func segments(_ text: String) -> [Segment] {
        var segments: [Segment] = []
        var current: [Substring] = []
        var inCode = false
        var language: String?

        func flush() {
            let joined = current.joined(separator: "\n")
            current = []
            let body = inCode ? joined : joined.trimmingCharacters(in: .newlines)
            if !body.isEmpty { segments.append(Segment(isCode: inCode, text: body, language: inCode ? language : nil)) }
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                flush()
                inCode.toggle()
                let tag = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                language = inCode && !tag.isEmpty ? tag : nil
            } else {
                current.append(line)
            }
        }
        flush()
        return segments
    }

    /// The message as blocks for rendering.
    public static func blocks(_ text: String) -> [Block] {
        segments(text).flatMap { segment -> [Block] in
            segment.isCode ? [.code(language: segment.language, text: segment.text)] : proseBlocks(segment.text)
        }
    }

    private enum Run {
        case none, paragraph, quote, table
    }

    private static func proseBlocks(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var run = Run.none
        var lines: [String] = []
        var rows: [[String]] = []

        func flush() {
            switch run {
            case .paragraph: blocks.append(.paragraph(lines.joined(separator: "\n")))
            case .quote: blocks.append(.quote(lines.joined(separator: "\n")))
            case .table: if !rows.isEmpty { blocks.append(.table(rows)) }
            case .none: break
            }
            run = .none
            lines = []
            rows = []
        }

        func collect(_ kind: Run) {
            if run != kind {
                flush()
                run = kind
            }
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            let leading = rawLine.prefix { $0 == " " || $0 == "\t" }.count
            let indent = min(leading / 2, 4)

            if trimmed.isEmpty {
                flush()
            } else if trimmed.hasPrefix("|"), trimmed.count > 1 {
                collect(.table)
                let cells = tableCells(trimmed)
                // The `|---|---|` line under the header carries no content.
                let isSeparator = cells.allSatisfy { !$0.isEmpty && $0.allSatisfy { "-: ".contains($0) } }
                if !isSeparator { rows.append(cells) }
            } else if let heading = heading(trimmed) {
                flush()
                blocks.append(heading)
            } else if trimmed.count >= 3, let first = trimmed.first, "-*_".contains(first), trimmed.allSatisfy({ $0 == first }) {
                flush()
                blocks.append(.rule)
            } else if trimmed.hasPrefix(">") {
                collect(.quote)
                lines.append(trimmed.dropFirst().trimmingCharacters(in: .whitespaces))
            } else if let item = listItem(trimmed, indent: indent) {
                flush()
                blocks.append(item)
            } else if run == .none, leading >= 2, case .listItem(let marker, let level, let body)? = blocks.last {
                // An indented line right after a list item continues it.
                blocks[blocks.count - 1] = .listItem(marker: marker, indent: level, text: body + "\n" + trimmed)
            } else {
                collect(.paragraph)
                lines.append(trimmed)
            }
        }
        flush()
        return blocks
    }

    private static func tableCells(_ line: String) -> [String] {
        var cells = line.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        if cells.first == "" { cells.removeFirst() }
        if cells.last == "" { cells.removeLast() }
        return cells
    }

    private static func heading(_ line: String) -> Block? {
        let level = line.prefix { $0 == "#" }.count
        guard (1...6).contains(level) else { return nil }
        let rest = line.dropFirst(level)
        guard rest.first == " " else { return nil }
        return .heading(level: level, text: rest.trimmingCharacters(in: .whitespaces))
    }

    private static func listItem(_ line: String, indent: Int) -> Block? {
        for bullet in ["- ", "* ", "+ "] where line.hasPrefix(bullet) {
            return .listItem(marker: "•", indent: indent, text: line.dropFirst(2).trimmingCharacters(in: .whitespaces))
        }
        let digits = line.prefix { $0.isASCII && $0.isNumber }
        let rest = line.dropFirst(digits.count)
        guard (1...3).contains(digits.count), let delimiter = rest.first, delimiter == "." || delimiter == ")",
              rest.dropFirst().first == " " else { return nil }
        return .listItem(marker: "\(digits).", indent: indent, text: rest.dropFirst(2).trimmingCharacters(in: .whitespaces))
    }

    public static func export(_ session: Session) -> String {
        var lines = ["# \(session.title)", ""]
        for item in session.transcript {
            switch item.kind {
            case .user: lines.append("**❯ \(item.text)**")
            case .assistant: lines.append(item.text)
            case .tool: lines.append("```\n\(item.title ?? "tool")\n\(item.text)\n```")
            case .info, .error: continue
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}
