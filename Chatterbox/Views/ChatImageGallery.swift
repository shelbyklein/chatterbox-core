import AppKit
import CryptoKit
import ImageIO
import SwiftUI

/// Every image made in a chat, newest first: images the agent generated, and screenshots,
/// renders, and proofs its replies pointed to. Clicking one opens it in the image viewer.
struct ChatImageGallery: View {
    let session: ChatSession
    let onOpen: (Attachment) -> Void
    /// Puts the chosen images in the message box, ready to send back to the chat.
    var onAdd: ([URL]) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var images: [GalleryImage] = []
    @State private var loaded = false
    @State private var selected: [String] = []   // Paths, in the order you picked them.

    struct GalleryImage: Identifiable, Hashable {
        var id: String { url.path }
        var url: URL
        var date: Date
    }

    /// Images in the chat, found by scanning its replies. Files that are gone are skipped.
    static func collect(_ session: ChatSession) -> [GalleryImage] {
        let fm = FileManager.default
        var seen = Set<String>()
        var found: [GalleryImage] = []
        func add(_ url: URL) {
            guard MediaKind.isStillImage(url.path) || url.pathExtension.lowercased() == "gif",
                  seen.insert(url.path).inserted, fm.fileExists(atPath: url.path) else { return }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            found.append(GalleryImage(url: url, date: date))
        }
        for item in session.items {
            switch item.kind {
            case .image:
                item.attachments?.forEach { add($0.url) }
            case .assistant where item.phase == .final:
                ChatSession.referencedImages(in: item.text, folder: session.workingFolder).forEach(add)
            default:
                break
            }
        }
        return dedupe(found.reversed())
    }

    /// The generator's raw output and the copy the agent saved under a real name are often
    /// the same picture: keep one, preferring the named file. Only same-size files are hashed.
    private static func dedupe(_ images: [GalleryImage]) -> [GalleryImage] {
        func size(_ url: URL) -> Int { (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1 }
        func generated(_ url: URL) -> Bool { url.lastPathComponent.hasPrefix("exec-") }
        let sizes = images.map { size($0.url) }
        let counts = Dictionary(sizes.map { ($0, 1) }, uniquingKeysWith: +)
        var kept: [String: Int] = [:]   // content key -> index in result
        var result: [GalleryImage] = []
        for (image, size) in zip(images, sizes) {
            guard size > 0, counts[size, default: 0] > 1, let data = try? Data(contentsOf: image.url) else { result.append(image); continue }
            let key = "\(size)-" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            if let index = kept[key] {
                if generated(result[index].url), !generated(image.url) { result[index] = image }
            } else {
                kept[key] = result.count
                result.append(image)
            }
        }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Images in \u{201C}\(session.title)\u{201D}").font(.headline).lineLimit(1)
                if loaded { Text("\(images.count)").foregroundStyle(.secondary) }
                Spacer()
                if selected.isEmpty {
                    Text("Click the circles to pick images to add to the chat").font(.caption).foregroundStyle(.secondary)
                } else {
                    Button("Clear") { selected = [] }
                    Button("Add \(selected.count) to Chat") {
                        onAdd(selected.map { URL(fileURLWithPath: $0) })
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(16)
            Divider()
            if !loaded {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if images.isEmpty {
                ContentUnavailableView("No images yet", systemImage: "photo.on.rectangle",
                                       description: Text("Images the agent makes, and screenshots or renders it shows you, collect here."))
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 260), spacing: 12)], spacing: 12) {
                        ForEach(images) { image in tile(image) }
                    }
                    .padding(16)
                }
            }
        }
        .frame(minWidth: 720, idealWidth: 960, minHeight: 520, idealHeight: 720)
        .task {
            images = Self.collect(session)
            loaded = true
        }
    }

    private func tile(_ image: GalleryImage) -> some View {
        Button {
            let attachment = Attachment(name: image.url.lastPathComponent, path: image.url.path,
                                        mediaType: "image/" + image.url.pathExtension.lowercased(), kind: .image)
            dismiss()
            // The viewer is a sheet too: open it once this one has gone.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { onOpen(attachment) }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                GalleryThumbnail(url: image.url)
                    .frame(height: 170)
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(isSelected(image) ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: isSelected(image) ? 3 : 1))
                    .overlay(alignment: .topTrailing) { checkmark(image) }
                Text(image.url.lastPathComponent).font(.caption).lineLimit(1).truncationMode(.middle)
                Text(image.date.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("View \(image.url.lastPathComponent)")
        // ⌘-click picks it too, like Finder.
        .simultaneousGesture(TapGesture().modifiers(.command).onEnded { toggle(image) })
        .contextMenu {
            Button(isSelected(image) ? "Deselect" : "Select") { toggle(image) }
            Button("Add to Chat") { onAdd([image.url]); dismiss() }
            Divider()
            Button("Copy Image") { ImageClipboard.copy(image.url) }
            Button("Open in Preview") { NSWorkspace.shared.open(image.url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([image.url]) }
        }
    }
}

extension ChatImageGallery {
    fileprivate func isSelected(_ image: GalleryImage) -> Bool { selected.contains(image.url.path) }

    fileprivate func toggle(_ image: GalleryImage) {
        if let index = selected.firstIndex(of: image.url.path) { selected.remove(at: index) } else { selected.append(image.url.path) }
    }

    /// A circle on each tile: click it to pick the image; it shows its place in the order.
    fileprivate func checkmark(_ image: GalleryImage) -> some View {
        Button { toggle(image) } label: {
            ZStack {
                Circle().fill(isSelected(image) ? Color.accentColor : Color.black.opacity(0.35))
                Circle().strokeBorder(.white, lineWidth: 1.5)
                if let index = selected.firstIndex(of: image.url.path) {
                    Text("\(index + 1)").font(.caption.weight(.bold)).foregroundStyle(.white)
                }
            }
            .frame(width: 24, height: 24)
            .padding(8)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(isSelected(image) ? "Deselect" : "Select to add to the chat")
        .accessibilityLabel(isSelected(image) ? "Deselect \(image.url.lastPathComponent)" : "Select \(image.url.lastPathComponent)")
    }
}

/// A downsized thumbnail, loaded off the main thread.
private struct GalleryThumbnail: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: url) {
            image = await Task.detached(priority: .utility) { () -> NSImage? in
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                              kCGImageSourceThumbnailMaxPixelSize: 600,
                                                                              kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
                else { return nil }
                return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }.value
        }
    }
}
