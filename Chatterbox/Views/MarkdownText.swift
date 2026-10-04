#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import SwiftUI

/// Markdown renderer for replies: headings, paragraphs, bulleted and numbered lists,
/// tables, quotes, rules, and fenced code, with inline bold, italics, code, and links.
struct MarkdownText: View {
    let text: String
    @Environment(\.readerStyle) private var style
    @Environment(\.chatFolder) private var folder

    var body: some View {
        let paths = PathLinks.context(for: text, folder: folder)
        VStack(alignment: .leading, spacing: style.paragraphSpacing) {
            ForEach(Array(Self.blocks(text).enumerated()), id: \.offset) { _, block in
                BlockView(block: block, paths: paths)
            }
        }
    }

    // MARK: - Blocks

    enum Block {
        case heading(level: Int, text: String)
        case paragraph(String)
        case list(items: [ListItem])
        case table(header: [String], rows: [[String]], alignments: [HorizontalAlignment])
        case quote(String)
        case rule
        /// `closed` is false while the fence is still streaming.
        case code(String, language: String, closed: Bool)
    }

    struct ListItem {
        var marker: String      // "•" or "3."
        var depth: Int
        var text: String
    }

    /// Parsed blocks of finished messages are kept, so a chat switch or re-render doesn't
    /// parse them again. A streaming message is a new text each time it grows; the cache
    /// is bounded, so those just age out.
    private final class Cached<Value>: NSObject {
        let value: Value
        init(_ value: Value) { self.value = value }
    }
    private static let blockCache: NSCache<NSString, Cached<[Block]>> = {
        let cache = NSCache<NSString, Cached<[Block]>>()
        cache.countLimit = 300
        return cache
    }()

    static func blocks(_ text: String) -> [Block] {
        let key = text as NSString
        if let hit = blockCache.object(forKey: key) { return hit.value }
        let parsed = parseBlocks(text)
        blockCache.setObject(Cached(parsed), forKey: key)
        return parsed
    }

    /// The uncached parse behind `blocks`.
    static func parseBlocks(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var list: [ListItem] = []
        var quote: [String] = []
        let lines = text.components(separatedBy: "\n")
        var index = 0

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
            if !list.isEmpty { blocks.append(.list(items: list)); list = [] }
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))); quote = [] }
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code; an unterminated fence is still streaming, so show it anyway.
            if trimmed.hasPrefix("```") {
                flush()
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[index])
                    index += 1
                }
                blocks.append(.code(code.joined(separator: "\n"), language: language, closed: index < lines.count))
                index += 1
                continue
            }

            if trimmed.isEmpty { flush(); index += 1; continue }

            if let match = trimmed.firstMatch(of: #/^(#{1,6})\s+(.+?)\s*#*$/#) {
                flush()
                blocks.append(.heading(level: match.1.count, text: String(match.2)))
                index += 1
                continue
            }

            if trimmed.firstMatch(of: #/^([-*_])(\s*\1){2,}$/#) != nil {
                flush()
                blocks.append(.rule)
                index += 1
                continue
            }

            // A table is a pipe row followed by a separator row like |---|:--:|.
            if trimmed.hasPrefix("|") || trimmed.contains(" | "), index + 1 < lines.count,
               let alignments = tableAlignments(lines[index + 1]) {
                flush()
                let header = tableCells(trimmed)
                var rows: [[String]] = []
                index += 2
                while index < lines.count {
                    let row = lines[index].trimmingCharacters(in: .whitespaces)
                    guard row.contains("|"), !row.isEmpty else { break }
                    rows.append(tableCells(row))
                    index += 1
                }
                let width = max(header.count, rows.map(\.count).max() ?? 0)
                let pad = { (cells: [String]) in cells + Array(repeating: "", count: max(0, width - cells.count)) }
                blocks.append(.table(header: pad(header), rows: rows.map(pad),
                                     alignments: alignments + Array(repeating: .leading, count: max(0, width - alignments.count))))
                continue
            }

            if trimmed.hasPrefix(">") {
                if !paragraph.isEmpty || !list.isEmpty { flush() }
                quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                index += 1
                continue
            }

            let indent = line.prefix(while: { $0 == " " || $0 == "\t" }).reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            if let match = trimmed.firstMatch(of: #/^[-*+•]\s+(.*)$/#) {
                if !paragraph.isEmpty || !quote.isEmpty { flush() }
                list.append(ListItem(marker: "\u{2022}", depth: indent / 2, text: String(match.1)))
                index += 1
                continue
            }
            if let match = trimmed.firstMatch(of: #/^(\d{1,3})[.)]\s+(.*)$/#) {
                if !paragraph.isEmpty || !quote.isEmpty { flush() }
                list.append(ListItem(marker: "\(match.1).", depth: indent / 2, text: String(match.2)))
                index += 1
                continue
            }

            // A wrapped continuation of the previous list item.
            if !list.isEmpty, indent >= 2 {
                list[list.count - 1].text += " " + trimmed
                index += 1
                continue
            }
            if !list.isEmpty || !quote.isEmpty { flush() }
            paragraph.append(line)
            index += 1
        }
        flush()
        return blocks
    }

    static func tableCells(_ row: String) -> [String] {
        var body = row.trimmingCharacters(in: .whitespaces)
        if body.hasPrefix("|") { body.removeFirst() }
        if body.hasSuffix("|") { body.removeLast() }
        // Split on pipes that aren't escaped (\|) or inside inline code.
        var cells: [String] = []
        var current = ""
        var inCode = false
        var previous: Character = " "
        for char in body {
            if char == "`" { inCode.toggle() }
            if char == "|", !inCode, previous != "\\" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(char)
            }
            previous = char
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells.map { $0.replacingOccurrences(of: "\\|", with: "|") }
    }

    /// The column alignments if `line` is a table separator row, else nil.
    static func tableAlignments(_ line: String) -> [HorizontalAlignment]? {
        let cells = tableCells(line)
        guard !cells.isEmpty, line.contains("-"),
              cells.allSatisfy({ $0.firstMatch(of: #/^:?-{1,}:?$/#) != nil }) else { return nil }
        return cells.map { cell in
            switch (cell.hasPrefix(":"), cell.hasSuffix(":")) {
            case (true, true): return .center
            case (false, true): return .trailing
            default: return .leading
            }
        }
    }

    // MARK: - Inline

    /// Bold, italics, links, and code spans. Code gets a subtle chip; code naming a file or
    /// folder that exists links to it in Finder (see PathLinks).
    static func inline(_ text: String, style: ReaderStyle = .defaults, paths: PathLinks? = nil) -> AttributedString {
        inline(text, style: style, paths: paths, cached: true)
    }

    private static let inlineCache: NSCache<NSString, Cached<AttributedString>> = {
        let cache = NSCache<NSString, Cached<AttributedString>>()
        cache.countLimit = 2000
        return cache
    }()

    /// The markdown parse of an inline run, before styling and path links (both of which
    /// depend on the reader style and the disk, so they're applied fresh each time).
    private static func parsedInline(_ text: String, cached: Bool) -> AttributedString {
        let key = text as NSString
        if cached, let hit = inlineCache.object(forKey: key) { return hit.value }
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let parsed = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        if cached { inlineCache.setObject(Cached(parsed), forKey: key) }
        return parsed
    }

    static func inline(_ text: String, style: ReaderStyle, paths: PathLinks?, cached: Bool) -> AttributedString {
        var result = parsedInline(text, cached: cached)
        for run in result.runs {
            if let intent = run.inlinePresentationIntent, intent.contains(.code) {
                result[run.range].font = style.code
                result[run.range].backgroundColor = Color.primary.opacity(0.09)
                if run.link == nil, let paths, let url = paths.url(for: String(result[run.range].characters)) {
                    result[run.range].link = url
                    result[run.range].underlineStyle = Text.LineStyle(pattern: .dot)
                }
            }
            if run.link != nil {
                result[run.range].foregroundColor = Color.highlight
                result[run.range].underlineStyle = .single
            }
        }
        return result
    }
}

/// Render one parsed block with the same typography and link context as a whole reply.
/// Mobile conversation bubbles use this to preserve lists, tables and fenced previews.
struct MarkdownBlockText: View {
    let block: MarkdownText.Block
    let source: String
    @Environment(\.chatFolder) private var folder

    var body: some View {
        BlockView(block: block, paths: PathLinks.context(for: source, folder: folder))
    }
}

// MARK: - Views

private struct BlockView: View {
    let block: MarkdownText.Block
    let paths: PathLinks
    @Environment(\.readerStyle) private var style

    private func inline(_ text: String) -> AttributedString { MarkdownText.inline(text, style: style, paths: paths) }

    var body: some View {
        switch block {
        case .heading(let level, let text):
            Text(inline(text))
                .font(style.heading(level))
                .padding(.top, level <= 2 ? style.paragraphSpacing * 0.6 : 2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

        case .paragraph(let text):
            Text(inline(text))
                .font(style.body)
                .lineSpacing(style.lineSpacing)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

        case .list(let items):
            VStack(alignment: .leading, spacing: max(3, style.paragraphSpacing / 2)) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(item.marker)
                            .font(style.body)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(minWidth: item.marker == "\u{2022}" ? 10 : 20, alignment: .trailing)
                        Text(inline(item.text))
                            .font(style.body)
                            .lineSpacing(style.lineSpacing)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(item.depth) * 18)
                }
            }

        case .table(let header, let rows, let alignments):
            TableView(header: header, rows: rows, alignments: alignments, paths: paths)

        case .quote(let text):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5).fill(.tertiary).frame(width: 3)
                Text(inline(text))
                    .font(style.body)
                    .foregroundStyle(.secondary)
                    .lineSpacing(style.lineSpacing)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .rule:
            Divider().padding(.vertical, 4)

        case .code(let code, let language, let closed):
            CodeBlock(code: code, language: language, closed: closed)
        }
    }
}

private struct TableView: View {
    let header: [String]
    let rows: [[String]]
    let alignments: [HorizontalAlignment]
    let paths: PathLinks
    @Environment(\.readerStyle) private var style

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(header.indices, id: \.self) { column in
                        cell(header[column], column: column).fontWeight(.semibold)
                    }
                }
                .background(Color.primary.opacity(0.06))
                ForEach(rows.indices, id: \.self) { row in
                    Divider().gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        ForEach(header.indices, id: \.self) { column in
                            cell(rows[row][column], column: column)
                        }
                    }
                    .background(row.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.025))
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12)))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private func cell(_ text: String, column: Int) -> some View {
        let alignment = alignments[column]
        // Measured at the width it wraps to: inside the sideways scroll view a cell gets no
        // width, and plain text would report a one-line height, so wrapped lines spilled
        // over the rows below.
        return WrappingWidth(maxWidth: 360) {
            Text(MarkdownText.inline(text, style: style, paths: paths))
                .font(style.secondary)
                .lineSpacing(style.lineSpacing * 0.6)
                .multilineTextAlignment(alignment == .trailing ? .trailing : alignment == .center ? .center : .leading)
                .textSelection(.enabled)
        }
            // Fills its column, so the row's shading reaches across every cell.
            .frame(minWidth: 40, maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .center))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .gridColumnAlignment(alignment)
    }
}

/// Lays text out no wider than `maxWidth`, and reports the height it takes at that width,
/// even when the parent offers no width (as a sideways scroll view doesn't).
private struct WrappingWidth: Layout {
    var maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let ideal = child.sizeThatFits(.unspecified).width
        let width = min(proposal.width ?? ideal, ideal, maxWidth)
        return child.sizeThatFits(ProposedViewSize(width: width, height: nil))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let width = min(bounds.width, maxWidth)
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: width, height: nil))
    }
}

#if canImport(AppKit)
private struct RunInTerminalKey: EnvironmentKey { static let defaultValue: ((String) -> Void)? = nil }
extension EnvironmentValues {
    /// Set by a chat: types a shell command into its terminal panel.
    var runInTerminal: ((String) -> Void)? {
        get { self[RunInTerminalKey.self] }
        set { self[RunInTerminalKey.self] = newValue }
    }
}
#endif

private struct CodeBlock: View {
    let code: String
    let language: String
    var closed = true
    @Environment(\.readerStyle) private var style
    #if canImport(AppKit)
    @Environment(\.runInTerminal) private var runInTerminal
    #endif

    private var isShell: Bool {
        ["bash", "sh", "zsh", "shell", "console", "terminal", "fish"].contains(language.lowercased())
    }
    @State private var copied = false
    @State private var showCode = false

    /// HTML and SVG blocks can be previewed live (HTMLPreview on the Mac, MobileHTMLPreview on iOS).
    private var preview: PreviewSource? {
        let lang = language.lowercased()
        let head = code.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200).lowercased()
        if lang == "svg" || (lang.isEmpty || lang == "xml") && head.hasPrefix("<svg") { return .svg(code) }
        if lang == "html" || lang == "htm" || lang.isEmpty && (head.hasPrefix("<!doctype html") || head.hasPrefix("<html")) {
            return .html(code)
        }
        return nil
    }

    var body: some View {
        if let preview, closed {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Picker("", selection: $showCode) {
                        Text("Preview").tag(false)
                        Text("Code").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    Spacer()
                    copyButton
                }
                if showCode { codeBody } else { HTMLPreview(source: preview) }
            }
        } else {
            codeBody
        }
    }

    private var copyButton: some View {
        Button(copied ? "Copied" : "Copy") {
            #if canImport(AppKit)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(code, forType: .string)
            #else
            UIPasteboard.general.string = code
            #endif
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
        }
        .buttonStyle(.borderless)
        .font(.caption)
    }

    private var codeBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "code" : language)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                #if canImport(AppKit)
                if isShell, closed, let runInTerminal {
                    Button("Run in Terminal") { runInTerminal(code) }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .help("Type this into the terminal at the bottom of the chat. You press Return.")
                }
                #endif
                copyButton
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(style.code)
                    .lineSpacing(style.lineSpacing * 0.5)
                    .textSelection(.enabled)
                    .padding(12)
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
    }
}
