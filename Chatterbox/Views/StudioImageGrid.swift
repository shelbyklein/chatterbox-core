import AppKit
import SwiftUI

/// A Studio's Images view: everything its sessions rendered or shared, newest first, in one
/// grid. Each tile names its session; click one to review it (Previous and Next step through
/// the rest), and right-click to open its chat.
struct StudioImageGrid: View {
    @Environment(AppModel.self) private var model
    let sessions: [ChatSession]
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
                                       description: Text("Images this Studio's sessions make, and screenshots or renders they show, collect here."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 20)], spacing: 20) {
                        ForEach(images) { tile($0) }
                    }
                    .padding(24)
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
        .accessibilityLabel("Images, \(images.count)")
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
                    .frame(height: 170)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 2) {
                    Text(image.title).font(.callout.weight(.medium)).lineLimit(1)
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
            Button("Open Chat") { model.selectedID = image.session; model.showingHome = false }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([image.url]) }
            Button("Copy Image") { ImageClipboard.copy(image.url) }
        }
        .accessibilityLabel("Image from \(image.title)")
    }
}
