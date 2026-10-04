import Photos
import SafariServices
import SwiftUI

/// Pins as small pills. A website opens inside the app; an app, file, or Shortcut opens on the Mac.
struct MobilePinPills: View {
    let pins: [Companion.Pin]
    @Environment(MobileStore.self) private var store
    @State private var page: PageRequest?
    @State private var note: String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(pins) { pin in
                    Button { open(pin) } label: {
                        HStack(spacing: 4) {
                            Image(systemName: Self.icon(pin)).font(.system(size: 10))
                            Text(pin.title).lineLimit(1)
                        }
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                    }
                    // Its own tap target, even inside a list row (which plain buttons aren't).
                    .buttonStyle(.borderless)
                    .tint(.primary)
                    .contextMenu {
                        if pin.kind == "website", let url = URL(string: pin.target) {
                            Button { UIApplication.shared.open(url) } label: { Label("Open in Safari", systemImage: "safari") }
                            Button { UIPasteboard.general.url = url } label: { Label("Copy Link", systemImage: "link") }
                        }
                        Button { openOnMac(pin) } label: { Label("Open on Mac", systemImage: "desktopcomputer") }
                    }
                }
            }
        }
        .sheet(item: $page) { SafariView(url: $0.url).ignoresSafeArea() }
        .alert(note ?? "", isPresented: Binding(get: { note != nil }, set: { if !$0 { note = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }

    static func icon(_ pin: Companion.Pin) -> String {
        switch pin.kind {
        case "website": "globe"
        case "app": "app"
        case "shortcut": "square.stack.3d.up"
        default: "doc"
        }
    }

    private func open(_ pin: Companion.Pin) {
        if pin.kind == "website", let url = URL(string: pin.target) {
            page = PageRequest(url: url)
        } else {
            openOnMac(pin)
        }
    }

    private func openOnMac(_ pin: Companion.Pin) {
        Task {
            do {
                try await store.openOnMac(pin)
                note = "Opened \(pin.title) on \(store.connection?.macName ?? "your Mac")."
            } catch {
                note = error.localizedDescription
            }
        }
    }
}

struct PageRequest: Identifiable {
    let id = UUID()
    var url: URL
}

/// A website inside the app, in Safari's own viewer.
struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

/// Reads and edits a Studio's instructions: what it's for, and the sites and tools to use.
struct StudioInstructionsEditor: View {
    let title: String
    let studio: UUID
    let initial: String
    @Environment(MobileStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 8) {
                Text("Every chat in this Studio follows these. Open chats get the new version with their next message.")
                    .font(.footnote).foregroundStyle(.secondary)
                TextEditor(text: $text)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color(uiColor: .secondarySystemBackground)))
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            }
            .padding()
            .navigationTitle("\(title) Instructions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.bold().disabled(saving)
                }
            }
            .onAppear { text = initial }
        }
    }

    private func save() {
        saving = true
        Task {
            do {
                try await store.setInstructions(text, studio: studio)
                dismiss()
            } catch {
                self.error = error.localizedDescription
                saving = false
            }
        }
    }
}

/// An image full screen: pinch or double-tap to zoom, save to Photos, share, copy, or mark up.
struct ImageViewer: View {
    let image: UIImage
    var onMarkUp: ((UIImage) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var note: String?

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .scaleEffect(scale)
                    .offset(offset)
                    .gesture(
                        MagnifyGesture()
                            .onChanged { scale = max(1, min(8, lastScale * $0.magnification)) }
                            .onEnded { _ in lastScale = scale; if scale == 1 { resetPan() } }
                            .simultaneously(with: DragGesture()
                                .onChanged { value in
                                    guard scale > 1 else { return }
                                    offset = CGSize(width: lastOffset.width + value.translation.width,
                                                    height: lastOffset.height + value.translation.height)
                                }
                                .onEnded { _ in lastOffset = offset })
                    )
                    .onTapGesture(count: 2) {
                        withAnimation(.spring(duration: 0.3)) {
                            if scale > 1 { scale = 1; lastScale = 1; resetPan() } else { scale = 2.5; lastScale = 2.5 }
                        }
                    }
            }
            .background(Color.black.ignoresSafeArea())
            .toolbarBackground(.visible, for: .navigationBar, .bottomBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button { save() } label: { Label("Save to Photos", systemImage: "square.and.arrow.down") }
                    Spacer()
                    ShareLink(item: Image(uiImage: image), preview: SharePreview("Image", image: Image(uiImage: image))) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    Spacer()
                    Button { UIPasteboard.general.image = image; note = "Copied." } label: { Label("Copy", systemImage: "doc.on.doc") }
                    if let onMarkUp {
                        Spacer()
                        Button { dismiss(); onMarkUp(image) } label: { Label("Mark Up", systemImage: "pencil.tip.crop.circle") }
                    }
                }
            }
            .alert(note ?? "", isPresented: Binding(get: { note != nil }, set: { if !$0 { note = nil } })) {
                Button("OK", role: .cancel) {}
            }
        }
    }

    private func resetPan() {
        offset = .zero
        lastOffset = .zero
    }

    /// Asks once for permission to add to Photos, then saves.
    private func save() {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            Task { @MainActor in
                guard status == .authorized || status == .limited else {
                    note = "Chatterbox can't add to Photos. Allow it in Settings → Chatterbox → Photos."
                    return
                }
                PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAsset(from: image)
                } completionHandler: { ok, error in
                    Task { @MainActor in note = ok ? "Saved to Photos." : (error?.localizedDescription ?? "Couldn't save.") }
                }
            }
        }
    }
}
