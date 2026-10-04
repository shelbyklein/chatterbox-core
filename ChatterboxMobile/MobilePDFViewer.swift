import PDFKit
import SwiftUI
import UniformTypeIdentifiers

struct MobilePDFButton: View {
    let file: Companion.File
    let chat: UUID
    @State private var reviewing = false
    var body: some View {
        Button { reviewing = true } label: {
            HStack(spacing: 10) {
                Image(systemName: "doc.richtext").font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.name).lineLimit(2)
                    Text(file.byteCount.map { "PDF · " + ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "PDF · Tap to review")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.left.and.arrow.down.right").font(.caption)
            }
            .padding(12)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Review PDF: " + file.name)
        .fullScreenCover(isPresented: $reviewing) { MobilePDFViewer(file: file, chat: chat) }
    }
}

struct MobilePDFViewer: View {
    let file: Companion.File
    let chat: UUID
    @Environment(MobileStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var entry: MobilePDFCache.Entry?
    @State private var downloading = false
    @State private var received: Int64 = 0
    @State private var expected: Int64 = 0
    @State private var problem: String?
    @State private var task: Task<Void, Never>?
    @State private var exporting = false
    @State private var sharing = false
    @State private var pageLabel = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if downloading {
                    VStack(spacing: 8) {
                        if expected > 0 { ProgressView(value: Double(received), total: Double(expected)) }
                        else { ProgressView() }
                        HStack {
                            Text("Downloading \(ByteCountFormatter.string(fromByteCount: received, countStyle: .file))").font(.caption)
                            Spacer()
                            Button("Cancel Download") { task?.cancel() }
                        }
                    }.padding()
                }
                if let problem {
                    VStack(spacing: 8) {
                        Text(problem).font(.callout)
                        Button("Try Again") { load(force: true) }.disabled(downloading)
                    }.padding()
                }
                if let entry {
                    PDFReviewDocument(url: entry.url, revision: entry.savedAt) { pageLabel = $0 }
                        .accessibilityIdentifier("pdfReviewSurface")
                } else if !downloading && problem == nil {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else { Spacer() }
            }
            .navigationTitle(file.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { task?.cancel(); dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { load(force: true) } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("Refresh PDF").disabled(downloading)
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button { exporting = true } label: { Label("Save to Files", systemImage: "folder.badge.plus") }.disabled(entry == nil)
                    Spacer()
                    Text(pageLabel).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { sharing = true } label: { Label("Share", systemImage: "square.and.arrow.up") }.disabled(entry == nil)
                }
            }
            .sheet(isPresented: $exporting) { if let entry { PDFExportPicker(url: entry.url) } }
            .sheet(isPresented: $sharing) { if let entry { PDFShareSheet(url: entry.url) } }
            .task { load() }
            .onDisappear { task?.cancel() }
        }
    }

    private func load(force: Bool = false) {
        guard !downloading else { return }
        task = Task {
            let cached = await Task.detached { MobilePDFCache.cached(file, chat: chat) }.value
            if entry == nil { entry = cached }
            if !force, let cached, cached.file.revision == file.revision { return }
            downloading = true; received = 0; expected = file.byteCount ?? 0; problem = nil
            defer { downloading = false }
            do {
                let saved = try await store.downloadPDF(file, in: chat) { bytes, total in
                    received = bytes; if total > 0 { expected = total }
                }
                try Task.checkCancellation()
                entry = saved
            } catch {
                if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                    problem = entry == nil ? "Download cancelled. Tap Try Again to download the PDF." : "Download cancelled. Showing the saved copy."
                } else {
                    problem = entry == nil ? error.localizedDescription : "Showing the saved copy. " + error.localizedDescription
                }
            }
        }
    }
}

private struct PDFReviewDocument: View {
    let url: URL
    let revision: Date
    let pageChanged: (String) -> Void
    @State private var document: PDFDocument?
    @State private var password = ""
    @State private var locked = false
    @State private var incorrect = false
    var body: some View {
        Group {
            if locked {
                VStack(spacing: 16) {
                    Label("Password-protected PDF", systemImage: "lock.doc")
                    SecureField("PDF password", text: $password).textFieldStyle(.roundedBorder)
                    if incorrect { Text("That password didn't unlock this PDF.").foregroundStyle(.secondary) }
                    Button("Unlock") {
                        if document?.unlock(withPassword: password) == true { locked = false; password = "" }
                        else { incorrect = true }
                    }.buttonStyle(.borderedProminent)
                }.padding().frame(maxWidth: 400).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let document { PDFReviewSurface(document: document, pageChanged: pageChanged) }
            else { ProgressView() }
        }
        .task(id: revision) {
            document = PDFDocument(url: url); locked = document?.isLocked == true
            password = ""; incorrect = false
        }
    }
}

/// PDFKit supplies native pinch zoom, page scrolling and selection.
private struct PDFReviewSurface: UIViewRepresentable {
    let document: PDFDocument
    let pageChanged: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(pageChanged) }
    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true; view.displayMode = .singlePageContinuous; view.displayDirection = .vertical
        view.backgroundColor = .systemBackground
        context.coordinator.observer = NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: view, queue: .main) { [weak view, weak coordinator = context.coordinator] _ in
            if let view { coordinator?.report(view) }
        }
        return view
    }
    func updateUIView(_ view: PDFView, context: Context) {
        guard view.document !== document else { return }
        view.document = document
        DispatchQueue.main.async { context.coordinator.report(view) }
    }
    final class Coordinator {
        var observer: NSObjectProtocol?
        let callback: (String) -> Void
        init(_ callback: @escaping (String) -> Void) { self.callback = callback }
        func report(_ view: PDFView) {
            guard let document = view.document, let page = view.currentPage else { return }
            callback("\(document.index(for: page) + 1) of \(document.pageCount)")
        }
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    }
}

private struct PDFExportPicker: UIViewControllerRepresentable {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    func makeCoordinator() -> Coordinator { Coordinator { dismiss() } }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let finished: () -> Void
        init(_ finished: @escaping () -> Void) { self.finished = finished }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { finished() }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finished() }
    }
}
private struct PDFShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct SavedPDFsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [MobilePDFCache.Entry] = []
    @State private var selection: MobilePDFCache.Entry?
    @State private var problem: String?
    var body: some View {
        NavigationStack {
            List {
                if let problem { Text(problem).foregroundStyle(.secondary) }
                ForEach(entries) { entry in
                    Button { selection = entry } label: {
                        Label { VStack(alignment: .leading) {
                            Text(entry.file.name).foregroundStyle(.primary)
                            Text("Saved " + entry.savedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                        } } icon: { Image(systemName: "doc.richtext") }
                    }
                    .swipeActions { Button("Remove", role: .destructive) {
                        do { try MobilePDFCache.remove(entry); entries.removeAll { $0.id == entry.id } }
                        catch { problem = error.localizedDescription }
                    } }
                }
            }
            .overlay { if entries.isEmpty { ContentUnavailableView("No Saved PDFs", systemImage: "doc.richtext", description: Text("PDFs you open in a chat are kept here for offline review.")) } }
            .navigationTitle("Saved PDFs")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { entries = await Task.detached { MobilePDFCache.entries() }.value }
            .fullScreenCover(item: $selection) { entry in MobilePDFViewer(file: entry.file, chat: entry.chat) }
        }
    }
}
