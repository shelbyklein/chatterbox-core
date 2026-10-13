import AppKit
import QuickLookThumbnailing
import SwiftUI

/// Every image a session rendered or shared, newest first, in a grid: the Studio inspector's
/// alternative to its latest image. Click one to review it (Previous and Next step through
/// the rest); right-click to show it in Finder or copy it.
struct SessionImageGrid: View {
    @Environment(AppModel.self) private var model
    let session: ChatSession
    private var sessions: [ChatSession] { [session] }
    @State private var images: [StudioImage] = []
    @State private var loaded = false
    @State private var reviewing: StudioImage?

    struct StudioImage: Identifiable, Hashable {
        var id: String { url.path }
        var url: URL
        var date: Date
        var session: UUID
        var title: String
    }

    var body: some View {
        Group {
            if !loaded {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if images.isEmpty {
                ContentUnavailableView("No images yet", systemImage: "photo.on.rectangle",
                                       description: Text("Images this session makes, and screenshots or renders it shows, collect here."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 260), spacing: 16)], spacing: 16) {
                        ForEach(images) { tile($0) }
                    }
                    .padding(16)
                }
            }
        }
        // A session's images change as it works: collect again when any of them changes.
        .task(id: sessions.map { "\($0.id)|\($0.items.count)" }.joined(separator: ",")) {
            images = Self.collect(sessions)
            loaded = true
        }
        .sheet(item: $reviewing) { image in
            ImageReviewView(attachment: Self.attachment(image.url), gallery: images.reversed().map(\.url)) { text, files in
                model.sessions.first { $0.id == image.session }?.send(text, attachments: files)
            }
        }
        .accessibilityLabel("All images in \(session.title), \(images.count)")
    }

    /// Every session's images (ChatImageGallery's rules), newest first, each once.
    static func collect(_ sessions: [ChatSession]) -> [StudioImage] {
        var seen = Set<String>()
        var all: [StudioImage] = []
        for session in sessions {
            for image in ChatImageGallery.collect(session) where seen.insert(image.url.path).inserted {
                all.append(StudioImage(url: image.url, date: image.date, session: session.id, title: session.title))
            }
        }
        return all.sorted { $0.date > $1.date }
    }

    static func attachment(_ url: URL) -> Attachment {
        Attachment(name: url.lastPathComponent, path: url.path, mediaType: "image/" + url.pathExtension.lowercased(), kind: .image)
    }

    private func tile(_ image: StudioImage) -> some View {
        Button { reviewing = image } label: {
            // A card: the image with room around it, and its session and age inside.
            VStack(alignment: .leading, spacing: 10) {
                GalleryThumbnail(url: image.url)
                    .frame(height: 140)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 2) {
                    Text(image.url.lastPathComponent).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                    let age = ShortAge.string(since: image.date)
                    Text(age == "now" ? "Just now" : age + " ago").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 2)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.055)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.1)))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .help(image.url.lastPathComponent)
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([image.url]) }
            Button("Copy Image") { ImageClipboard.copy(image.url) }
        }
        .accessibilityLabel("Image \(image.url.lastPathComponent)")
    }
}

/// Every file a session made or shared that isn't an image (PDFs, InDesign, Word, HTML…),
/// newest first, with Finder's preview. Click to open (PDFs and text in the viewer, the rest
/// in their app); right-click to show it in Finder or copy its path.
struct SessionFileGrid: View {
    let session: ChatSession
    @State private var files: [SessionFile] = []
    @State private var loaded = false
    @State private var viewing: LocalDocument?

    struct SessionFile: Identifiable, Hashable {
        var id: String { url.path }
        var url: URL
        var date: Date
    }

    /// Files attached in the chat, and files its replies point to, that still exist.
    static func collect(_ session: ChatSession) -> [SessionFile] {
        let fm = FileManager.default
        var seen = Set<String>()
        var found: [SessionFile] = []
        func add(_ url: URL) {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue,
                  !MediaKind.isStillImage(url.path), url.pathExtension.lowercased() != "gif",
                  seen.insert(url.path).inserted else { return }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            found.append(SessionFile(url: url, date: date))
        }
        for item in session.items {
            item.attachments?.forEach { add($0.url) }
            if item.kind == .assistant, item.phase == .final {
                PathLinks.referencedFiles(in: item.text, folder: session.workingFolder).forEach { add(URL(fileURLWithPath: $0)) }
            }
        }
        return found.sorted { $0.date > $1.date }
    }

    var body: some View {
        Group {
            if !loaded {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if files.isEmpty {
                ContentUnavailableView("No files yet", systemImage: "doc.on.doc",
                                       description: Text("PDFs, documents and other files this session makes, or points you to, collect here."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 260), spacing: 16)], spacing: 16) {
                        ForEach(files) { tile($0) }
                    }
                    .padding(16)
                }
            }
        }
        .task(id: "\(session.id)|\(session.items.count)") {
            let session = session
            files = Self.collect(session)
            loaded = true
        }
        .sheet(item: $viewing) { document in
            DocumentViewer(document: document).frame(minWidth: 720, minHeight: 640)
        }
        .accessibilityLabel("Files in \(session.title), \(files.count)")
    }

    private func open(_ file: SessionFile) {
        if LocalDocument.supports(file.url) { viewing = LocalDocument(url: file.url) } else { NSWorkspace.shared.open(file.url) }
    }

    private func tile(_ file: SessionFile) -> some View {
        Button { open(file) } label: {
            VStack(alignment: .leading, spacing: 10) {
                FileThumbnail(url: file.url)
                    .frame(height: 140).frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.url.lastPathComponent).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                    let age = ShortAge.string(since: file.date)
                    Text((age == "now" ? "Just now" : age + " ago") + " \u{00B7} " + file.url.pathExtension.uppercased())
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 2)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.055)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.1)))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .help(file.url.path)
        .contextMenu {
            Button("Open") { open(file) }
            Button("Open in App") { NSWorkspace.shared.open(file.url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
            Button("Copy Path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(file.url.path, forType: .string) }
        }
        .accessibilityLabel("File \(file.url.lastPathComponent)")
    }
}

/// Finder's preview of a file (a PDF's first page, a document's icon), made off the main thread.
struct FileThumbnail: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().aspectRatio(contentMode: .fit).padding(24)
            }
        }
        .task(id: url) {
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 400, height: 300), scale: 2, representationTypes: .thumbnail)
            image = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
        }
    }
}
