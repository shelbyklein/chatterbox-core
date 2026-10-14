import AppKit
import PDFKit
import SwiftUI

struct LocalDocument: Identifiable {
    let url: URL
    var id: URL { url }
    static func supports(_ url: URL) -> Bool {
        ["pdf", "md", "markdown", "txt", "text"].contains(url.pathExtension.lowercased())
    }
    var isPDF: Bool { url.pathExtension.lowercased() == "pdf" }
}

/// Read off the UI thread and bound text size before Markdown builds its view tree.
enum DocumentLoader {
    static func text(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 2_000_001) ?? Data()
        guard data.count <= 2_000_000 else { throw Failure.tooLarge }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else { throw Failure.encoding }
        return text
    }
    enum Failure: LocalizedError {
        case tooLarge, encoding
        var errorDescription: String? {
            switch self {
            case .tooLarge: "This text file is too large for the built-in viewer. Use Open in App to read it."
            case .encoding: "This file could not be read as text. Use Open in App to view it."
            }
        }
    }
}

struct DocumentViewer: View {
    let document: LocalDocument
    @Environment(\.dismiss) private var dismiss
    @State private var text: String?
    @State private var pdf: PDFDocument?
    @State private var error: String?
    @State private var source = false
    @State private var revision = 0
    @State private var password = ""
    @State private var unlockFailed = false
    /// How a PDF with several pages is shown: "pages" (one at a time, flipped), "spreads"
    /// (two side by side, like an open book) or "scroll" (one long column).
    @AppStorage("pdfLayout") private var pdfLayout = "pages"
    @State private var pages = PDFPager()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: document.isPDF ? "doc.richtext" : "doc.text")
                Text(document.url.lastPathComponent).font(.headline).lineLimit(1).help(document.url.path)
                Spacer()
                if !document.isPDF {
                    Picker("", selection: $source) {
                        Text("Read").tag(false).disabled((text?.count ?? 0) > 100_000)
                        Text("Source").tag(true)
                    }.pickerStyle(.segmented).frame(width: 150)
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text ?? "", forType: .string)
                    }.disabled(text == nil)
                }
                if let pdf, !pdf.isLocked, pdf.pageCount > 1 { pdfControls(pdf) }
                HStack(spacing: 12) {
                Button { revision += 1 } label: { Image(systemName: "arrow.clockwise") }.help("Reload file")
                Menu {
                    Button("Open in App") { NSWorkspace.shared.open(document.url) }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([document.url]) }
                    Button("Copy File Path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(document.url.path, forType: .string)
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                }.fixedSize().layoutPriority(1)
            }.padding(16)
            Divider()
            Group {
                if let error {
                    ContentUnavailableView("Couldn’t open document", systemImage: "doc.badge.ellipsis", description: Text(error))
                } else if let pdf {
                    if pdf.isLocked {
                        VStack(spacing: 12) {
                            Text("This PDF requires a password.")
                            SecureField("Password", text: $password).frame(width: 260).onSubmit { unlock(pdf) }
                            Button("Unlock") { unlock(pdf) }
                            if unlockFailed { Text("That password didn’t unlock the PDF.").foregroundStyle(.red) }
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else { NativePDFView(document: pdf, layout: pdf.pageCount > 1 ? pdfLayout : "scroll", pager: pages) }
                } else if let text {
                    if source || document.url.pathExtension.lowercased() == "txt" || document.url.pathExtension.lowercased() == "text" {
                        SelectableDocumentText(text: text)
                    } else {
                        ScrollView {
                            MarkdownText(text: text).textSelection(.enabled)
                                .frame(maxWidth: 880, alignment: .leading).padding(28)
                                .frame(maxWidth: .infinity, alignment: .center)
                        }
                    }
                } else { ProgressView("Opening document…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .environment(\.chatFolder, document.url.deletingLastPathComponent().path)
        .task(id: "\(document.id)|\(revision)") { await load() }
    }

    /// Flip buttons and the page (or spread) you're on, then the layout.
    private func pdfControls(_ pdf: PDFDocument) -> some View {
        HStack(spacing: 10) {
            if pdfLayout != "scroll" {
                Button { pages.view?.goToPreviousPage(nil) } label: { Image(systemName: "chevron.left") }
                    .keyboardShortcut(.leftArrow, modifiers: []).help("Previous page (←)")
                    .disabled(!pages.canGoBack)
                Text(pages.label(total: pdf.pageCount, spreads: pdfLayout == "spreads"))
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(minWidth: 74)
                Button { pages.view?.goToNextPage(nil) } label: { Image(systemName: "chevron.right") }
                    .keyboardShortcut(.rightArrow, modifiers: []).help("Next page (→)")
                    .disabled(!pages.canGoForward)
            }
            Picker("Layout", selection: $pdfLayout) {
                Image(systemName: "doc").tag("pages").help("One page at a time")
                Image(systemName: "book").tag("spreads").help("Two pages side by side")
                Image(systemName: "list.bullet.rectangle.portrait").tag("scroll").help("Scroll through every page")
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .accessibilityLabel("Page layout")
        }
        .buttonStyle(.borderless)
    }

    private func unlock(_ pdf: PDFDocument) {
        unlockFailed = !pdf.unlock(withPassword: password)
        if !unlockFailed { password = "" }
    }

    @MainActor private func load() async {
        text = nil; pdf = nil; error = nil; unlockFailed = false
        let url = document.url
        do {
            if document.isPDF {
                let data = try await Task.detached(priority: .userInitiated) { try Data(contentsOf: url) }.value
                guard !Task.isCancelled else { return }
                guard let loaded = PDFDocument(data: data) else {
                    error = "This file isn’t a readable PDF."; return
                }
                pdf = loaded
            } else {
                let loaded = try await Task.detached(priority: .userInitiated) { try DocumentLoader.text(url) }.value
                guard !Task.isCancelled else { return }
                text = loaded
                // Large documents remain readable without building thousands of Markdown views.
                if loaded.count > 100_000 { source = true }
            }
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }
}

/// The PDF view the flip buttons drive, and which page it's on.
@MainActor @Observable final class PDFPager {
    @ObservationIgnored weak var view: PDFView?
    private(set) var page = 0
    private(set) var canGoBack = false
    private(set) var canGoForward = false

    func update(_ view: PDFView) {
        guard let document = view.document, let current = view.currentPage else { return }
        page = document.index(for: current)
        canGoBack = view.canGoToPreviousPage
        canGoForward = view.canGoToNextPage
    }

    /// "3 of 12", or for spreads the pages showing: "2–3 of 12" (the cover shows alone).
    func label(total: Int, spreads: Bool) -> String {
        let first = page + 1
        guard spreads, first > 1 else { return "\(first) of \(total)" }
        let left = first % 2 == 0 ? first : first - 1
        return left + 1 <= total ? "\(left)–\(left + 1) of \(total)" : "\(left) of \(total)"
    }
}

struct NativePDFView: NSViewRepresentable {
    let document: PDFDocument
    var layout = "scroll"
    var pager: PDFPager? = nil
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = document
        apply(layout, to: view)
        pager?.view = view
        context.coordinator.observe(view, pager: pager)
        return view
    }
    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== document { view.document = document }
        if context.coordinator.layout != layout { apply(layout, to: view); context.coordinator.layout = layout; pager?.update(view) }
    }
    private func apply(_ layout: String, to view: PDFView) {
        switch layout {
        case "pages": view.displayMode = .singlePage; view.displaysAsBook = false
        case "spreads": view.displayMode = .twoUp; view.displaysAsBook = true
        default: view.displayMode = .singlePageContinuous; view.displaysAsBook = false
        }
        view.displayDirection = .vertical
        view.autoScales = true
    }

    final class Coordinator {
        var layout: String?
        private var token: NSObjectProtocol?
        @MainActor func observe(_ view: PDFView, pager: PDFPager?) {
            guard let pager else { return }
            pager.update(view)
            token = NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: view, queue: .main) { [weak view] _ in
                MainActor.assumeIsolated { if let view { pager.update(view) } }
            }
        }
        deinit { if let token { NotificationCenter.default.removeObserver(token) } }
    }
}

struct SelectableDocumentText: NSViewRepresentable {
    let text: String
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        let view = NSTextView()
        view.isEditable = false
        view.isSelectable = true
        view.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        view.textContainerInset = NSSize(width: 24, height: 20)
        view.autoresizingMask = [.width]
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.textContainer?.widthTracksTextView = true
        view.string = text
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ view: NSScrollView, context: Context) {
        if let textView = view.documentView as? NSTextView, textView.string != text { textView.string = text }
    }
}
