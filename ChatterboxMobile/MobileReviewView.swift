import PDFKit
import SwiftUI
import UIKit

// Review: tap a spot or drag a box on an image or a PDF page, and add a note to each.
// The same feedback as the Mac's Image Review (ReviewNotes words it), finished in the
// session's message box: the notes as text, and marked-up copies as pending images.

/// What a review opens on: an image from the chat, or a PDF at the page being read.
enum MobileReviewSource {
    case image(UIImage, name: String)
    /// `page` is 0-based: the page the viewer was showing.
    case pdf(PDFDocument, name: String, page: Int)
}

struct MobileReviewRequest: Identifiable {
    let id = UUID()
    var source: MobileReviewSource
}

/// Feedback for the message box: the words, and the marked-up pictures to send with them.
struct MobileReviewResult {
    var text: String
    var images: [PendingImage]
}

extension MobileComposerDraft where Image == PendingImage {
    /// Puts review feedback in the box, after anything already typed there.
    func add(_ review: MobileReviewResult) {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !review.text.isEmpty { text = typed.isEmpty ? review.text : typed + "\n\n" + review.text }
        images.append(contentsOf: review.images)
    }
}

/// Full screen: tap to mark a spot, drag to mark an area, a note for each mark. PDFs go page
/// by page and keep each page's marks. Add to Message hands back the feedback; the presenter
/// puts it in the session's message box.
struct MobileReviewView: View {
    let source: MobileReviewSource
    let onAdd: (MobileReviewResult) -> Void

    private struct Mark: Identifiable {
        let id = UUID()
        /// 1-based page of a PDF; nil for an image.
        var page: Int?
        /// 0–1 coordinates of the image or page; zero size is a spot.
        var rect: CGRect
        var comment = ""
    }
    private enum Edit { case added(UUID), removed(Mark, at: Int) }
    private enum Field: Hashable { case mark(UUID), overall }

    @Environment(\.dismiss) private var dismiss
    @State private var marks: [Mark] = []
    @State private var edits: [Edit] = []
    @State private var pageIndex: Int
    @State private var picture: UIImage?
    @State private var overall = ""
    @State private var problem: String?
    @State private var adding = false
    @State private var confirmingCancel = false
    @State private var window: CGSize = .zero
    @State private var panelHeight: CGFloat = 120
    @FocusState private var focus: Field?

    init(source: MobileReviewSource, onAdd: @escaping (MobileReviewResult) -> Void) {
        self.source = source
        self.onAdd = onAdd
        if case .pdf(let document, _, let page) = source {
            _pageIndex = State(initialValue: min(max(page, 0), max(document.pageCount - 1, 0)))
        } else {
            _pageIndex = State(initialValue: 0)
        }
    }

    private var name: String {
        switch source {
        case .image(_, let name), .pdf(_, let name, _): name
        }
    }
    private var document: PDFDocument? {
        if case .pdf(let document, _, _) = source { return document }
        return nil
    }
    private var pageCount: Int { document?.pageCount ?? 1 }
    /// The page marks go on: 1-based for a PDF, nil for an image.
    private var page: Int? { document == nil ? nil : pageIndex + 1 }
    private var pageMarks: [Mark] { marks.filter { $0.page == page } }
    private var hasFeedback: Bool { !marks.isEmpty || !overall.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    /// An iPad, an open iPhone Duo, or a phone on its side: the notes beside the picture.
    /// Measured from the window, so the keyboard never switches the layout mid-note.
    private var sideBySide: Bool {
        min(window.width, window.height) >= 600 || window.width > window.height
    }

    var body: some View {
        NavigationStack {
            Group {
                if sideBySide {
                    HStack(spacing: 0) {
                        canvasArea
                        Divider()
                        sidebar.frame(width: min(360, max(280, window.width * 0.36)))
                    }
                } else {
                    // The space left above the keyboard, so the picture keeps a share of it.
                    GeometryReader { space in
                        VStack(spacing: 0) {
                            canvasArea
                            Divider()
                            bottomPanel(maxHeight: max(space.size.height * 0.45, 150))
                        }
                    }
                }
            }
            .background { ReviewWindowProbe(size: $window).allowsHitTesting(false) }
            .navigationTitle(name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { if hasFeedback { confirmingCancel = true } else { dismiss() } }
                        .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add to Message") { add() }
                        .bold()
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!hasFeedback || adding || picture == nil)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focus = nil }
                }
            }
            .confirmationDialog("Discard these comments?", isPresented: $confirmingCancel, titleVisibility: .visible) {
                Button("Discard Comments", role: .destructive) { dismiss() }
                Button("Keep Commenting", role: .cancel) {}
            }
            .task(id: pageIndex) { await showPage() }
            .onChange(of: focus) { _, _ in tidyNotes() }
        }
    }

    // MARK: - Picture

    private var canvasArea: some View {
        VStack(spacing: 0) {
            ZStack {
                Color(uiColor: .systemGray6)
                ReviewCanvas(
                    image: picture,
                    marks: pageMarks.map(\.rect),
                    highlighted: pageMarks.firstIndex { focus == .mark($0.id) },
                    label: document == nil ? "Image to mark" : "Page \(pageIndex + 1)",
                    turnsPages: pageCount > 1,
                    onMark: addMark,
                    onSelect: { index in
                        let current = pageMarks
                        if current.indices.contains(index) { focus = .mark(current[index].id) }
                    },
                    onTurn: { turn($0) })
                if picture == nil { ProgressView() }
            }
            .clipped()
            canvasBar
        }
    }

    /// Undo, and for a PDF the page arrows.
    private var canvasBar: some View {
        HStack(spacing: 4) {
            Button(action: undo) {
                Label("Undo", systemImage: "arrow.uturn.backward")
                    .labelStyle(.iconOnly)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .disabled(edits.isEmpty)
            .accessibilityLabel("Undo")
            Spacer(minLength: 0)
            if document != nil {
                Button { turn(-1) } label: {
                    Image(systemName: "chevron.left").frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .disabled(pageIndex == 0)
                .accessibilityLabel("Previous Page")
                Text("Page \(pageIndex + 1) of \(pageCount)")
                    .font(.subheadline.monospacedDigit())
                    .accessibilityIdentifier("reviewPageLabel")
                    .frame(minWidth: 96)
                Button { turn(1) } label: {
                    Image(systemName: "chevron.right").frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .disabled(pageIndex >= pageCount - 1)
                .accessibilityLabel("Next Page")
            } else {
                Text(marks.isEmpty ? "Tap a spot or drag a box" : "\(marks.count) mark\(marks.count == 1 ? "" : "s")")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            // Balances Undo, so the page stays centered.
            Color.clear.frame(width: 44, height: 44)
        }
        .font(.body.weight(.semibold))
        .padding(.horizontal, 8)
        .background(.bar)
    }

    private func showPage() async {
        switch source {
        case .image(let image, _):
            picture = image
        case .pdf(let document, _, _):
            picture = nil
            // Let the spinner show; a page renders in a moment.
            await Task.yield()
            guard !Task.isCancelled, let pdfPage = document.page(at: pageIndex) else { return }
            picture = ReviewRendering.page(pdfPage, longSide: 2200)
        }
    }

    private func turn(_ offset: Int) {
        let target = pageIndex + offset
        guard document != nil, target >= 0, target < pageCount else { return }
        focus = nil
        pageIndex = target
    }

    // MARK: - Marks

    private func addMark(_ rect: CGRect) {
        let mark = Mark(page: page, rect: ReviewNotes.isPoint(rect) ? CGRect(origin: rect.origin, size: .zero) : rect)
        marks.append(mark)
        edits.append(.added(mark.id))
        problem = nil
        focus = .mark(mark.id)
    }

    private func remove(_ mark: Mark) {
        guard let index = marks.firstIndex(where: { $0.id == mark.id }) else { return }
        if focus == .mark(mark.id) { focus = nil }
        edits.append(.removed(marks[index], at: index))
        marks.remove(at: index)
    }

    /// Takes back the last mark added or removed, on whichever page it was.
    private func undo() {
        guard let edit = edits.popLast() else { return }
        switch edit {
        case .added(let id):
            guard let index = marks.firstIndex(where: { $0.id == id }) else { return }
            show(marks[index].page)
            if focus == .mark(id) { focus = nil }
            marks.remove(at: index)
        case .removed(let mark, let index):
            show(mark.page)
            marks.insert(mark, at: min(index, marks.count))
        }
    }

    private func show(_ page: Int?) {
        if let page, page - 1 != pageIndex { focus = nil; pageIndex = page - 1 }
    }

    private func comment(_ id: UUID) -> Binding<String> {
        Binding {
            marks.first { $0.id == id }?.comment ?? ""
        } set: { value in
            guard let index = marks.firstIndex(where: { $0.id == id }) else { return }
            marks[index].comment = value
            // Return finishes the note (tidyNotes then takes the line break out).
            if value.contains("\n") { focus = nil }
        }
    }

    /// One line per note, once it's no longer being typed. Changing the stored text (rather
    /// than refusing the line break) is what makes the field show the tidied note.
    private func tidyNotes() {
        for index in marks.indices where focus != .mark(marks[index].id) {
            let tidy = Self.oneLine(marks[index].comment)
            if tidy != marks[index].comment { marks[index].comment = tidy }
        }
    }

    private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Notes

    private var hint: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(document == nil ? "Tap the image to mark a spot, or drag to mark an area. Then say what should change."
                                 : "Tap the page to mark a spot, or drag to mark an area. Then say what should change.")
                .font(.callout)
            Text(pageCount > 1 ? "Pinch to zoom; move with two fingers. Swipe with two fingers to turn the page."
                               : "Pinch to zoom; move with two fingers.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var markRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            if pageMarks.isEmpty { hint }
            ForEach(Array(pageMarks.enumerated()), id: \.element.id) { index, mark in
                markRow(index + 1, mark)
            }
            otherPages
        }
    }

    private func markRow(_ number: Int, _ mark: Mark) -> some View {
        let focused = focus == .mark(mark.id)
        return HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.footnote.weight(.bold).monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.orange))
                .padding(.top, 5)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                TextField("What should change here?", text: comment(mark.id), axis: .vertical)
                    .lineLimit(1...4)
                    .submitLabel(.done)
                    .focused($focus, equals: .mark(mark.id))
                    .accessibilityLabel("Note for mark \(number)")
                    .accessibilityIdentifier("reviewNote-\(number)")
                    .padding(.vertical, 7)
                Text(ReviewNotes.isPoint(mark.rect) ? "Spot" : "Area")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Button { remove(mark) } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove mark \(number)")
        }
        .padding(.leading, 10)
        .padding(.trailing, 2)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(uiColor: .secondarySystemBackground)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.orange.opacity(focused ? 0.8 : 0), lineWidth: 1.5))
        .id(mark.id)
    }

    /// For a PDF: the other pages with marks, to go back to them.
    @ViewBuilder private var otherPages: some View {
        let counts = Dictionary(grouping: marks.compactMap(\.page), by: { $0 }).mapValues(\.count)
        let others = counts.keys.filter { $0 != page }.sorted()
        if document != nil, !others.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Text("Also marked:").font(.caption).foregroundStyle(.secondary)
                    ForEach(others, id: \.self) { other in
                        Button { focus = nil; pageIndex = other - 1 } label: {
                            Text("Page \(other) · \(counts[other] ?? 0)")
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(Capsule().fill(Color.orange.opacity(0.15)))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Page \(other), \(counts[other] ?? 0) mark\(counts[other] == 1 ? "" : "s")")
                    }
                }
            }
        }
    }

    private var overallField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Overall note").font(.caption).foregroundStyle(.secondary)
            TextField("Optional", text: $overall, axis: .vertical)
                .lineLimit(1...5)
                .focused($focus, equals: .overall)
                .accessibilityLabel("Overall note")
                .accessibilityIdentifier("reviewOverallNote")
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(uiColor: .secondarySystemBackground)))
            if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
        }
        .id("overall")
    }

    /// Phone: under the picture, as tall as its notes, up to `maxHeight`.
    private func bottomPanel(maxHeight: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    markRows
                    overallField
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { panelHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
            .frame(height: min(panelHeight, maxHeight))
            .onChange(of: focus) { _, field in scroll(proxy, to: field) }
        }
    }

    /// iPad, open Duo, or landscape: beside the picture, like the Mac's.
    private var sidebar: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 12) {
                ScrollView {
                    markRows.padding(16)
                }
                .scrollDismissesKeyboard(.interactively)
                overallField.padding([.horizontal, .bottom], 16)
            }
            .onChange(of: focus) { _, field in scroll(proxy, to: field) }
        }
        .background(Color(uiColor: .systemBackground))
    }

    private func scroll(_ proxy: ScrollViewProxy, to field: Field?) {
        guard case .mark(let id) = field else { return }
        withAnimation(.snappy(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) }
    }

    // MARK: - Adding to the message

    private func add() {
        focus = nil
        adding = true
        let notes = marks.map { ReviewNotes.Mark(page: $0.page, rect: $0.rect, comment: Self.oneLine($0.comment)) }
        let base = (name as NSString).deletingPathExtension
        var images: [PendingImage] = []
        switch source {
        case .image(let image, let name):
            if !marks.isEmpty {
                let marked = ReviewRendering.annotated(image, marks: marks.map(\.rect), maxEdge: 2576)
                guard let pending = ReviewRendering.pending(marked, name: "Marked up \(base)") else { return failed() }
                images.append(pending)
            }
            // The original is already in the session; only the marked-up copy goes with the note.
            let text = ReviewNotes.message(file: name, marks: notes, overall: overall, originalAttached: false)
            finish(MobileReviewResult(text: text, images: images))
        case .pdf(let document, let name, _):
            let pages = Set(marks.compactMap(\.page)).sorted()
            for number in pages {
                guard let pdfPage = document.page(at: number - 1) else { continue }
                let shot = ReviewRendering.page(pdfPage, longSide: 1800)
                let marked = ReviewRendering.annotated(shot, marks: marks.filter { $0.page == number }.map(\.rect), maxEdge: 1800)
                guard let pending = ReviewRendering.pending(marked, name: "Marked up \(base) page \(number)") else { return failed() }
                images.append(pending)
            }
            let text = ReviewNotes.message(file: name, marks: notes, overall: overall, attachedPages: pages)
            finish(MobileReviewResult(text: text, images: images))
        }
    }

    private func finish(_ result: MobileReviewResult) {
        onAdd(result)
        dismiss()
    }

    private func failed() {
        adding = false
        problem = "Couldn't draw the marks on a copy. Try again."
    }
}

// MARK: - Canvas

/// The picture in UIKit, for touch handling SwiftUI doesn't give: one finger marks (tap a spot,
/// drag an area), two fingers pinch to zoom and move, and a quick two-finger swipe turns a PDF's page.
private struct ReviewCanvas: UIViewRepresentable {
    let image: UIImage?
    let marks: [CGRect]
    let highlighted: Int?
    let label: String
    let turnsPages: Bool
    let onMark: (CGRect) -> Void
    let onSelect: (Int) -> Void
    let onTurn: (Int) -> Void

    func makeUIView(context: Context) -> ReviewCanvasView { ReviewCanvasView() }

    func updateUIView(_ view: ReviewCanvasView, context: Context) {
        view.onMark = onMark
        view.onSelect = onSelect
        view.onTurn = onTurn
        view.turnsPages = turnsPages
        view.pictureLabel = label
        view.show(image)
        view.marks = marks
        view.highlighted = highlighted
    }
}

final class ReviewCanvasView: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    var onMark: (CGRect) -> Void = { _ in }
    var onSelect: (Int) -> Void = { _ in }
    var onTurn: (Int) -> Void = { _ in }
    var marks: [CGRect] = [] { didSet { if marks != oldValue { overlay.setNeedsDisplay() } } }
    var highlighted: Int? { didSet { if highlighted != oldValue { overlay.setNeedsDisplay() } } }
    var turnsPages = false { didSet { swipes.forEach { $0.isEnabled = turnsPages } } }
    var pictureLabel = "" { didSet { imageView.accessibilityLabel = pictureLabel } }

    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private let overlay = ReviewMarksOverlay()
    private var image: UIImage?
    private var fittedFor: CGSize = .zero
    private var drag: UIPanGestureRecognizer!
    private var swipes: [UISwipeGestureRecognizer] = []
    private var dragStart: CGPoint?
    /// The area being dragged out, in 0–1 coordinates.
    fileprivate var dragRect: CGRect?

    override init(frame: CGRect) {
        super.init(frame: frame)
        scrollView.delegate = self
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 5
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.panGestureRecognizer.minimumNumberOfTouches = 2
        scrollView.backgroundColor = .clear
        imageView.layer.shadowColor = UIColor.black.cgColor
        imageView.layer.shadowOpacity = 0.18
        imageView.layer.shadowRadius = 6
        imageView.layer.shadowOffset = CGSize(width: 0, height: 2)
        imageView.isAccessibilityElement = true
        imageView.accessibilityIdentifier = "reviewPicture"
        imageView.accessibilityTraits = [.image, .allowsDirectInteraction]
        imageView.accessibilityHint = "Tap to mark a spot, or drag to mark an area."
        scrollView.addSubview(imageView)
        addSubview(scrollView)
        overlay.canvas = self
        overlay.isUserInteractionEnabled = false
        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.contentMode = .redraw
        addSubview(overlay)

        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        scrollView.addGestureRecognizer(tap)
        drag = UIPanGestureRecognizer(target: self, action: #selector(dragged(_:)))
        drag.maximumNumberOfTouches = 1
        drag.delegate = self
        scrollView.addGestureRecognizer(drag)
        for direction in [UISwipeGestureRecognizer.Direction.left, .right] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(swiped(_:)))
            swipe.direction = direction
            swipe.numberOfTouchesRequired = 2
            swipe.delegate = self
            swipe.isEnabled = false
            scrollView.addGestureRecognizer(swipe)
            swipes.append(swipe)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ newImage: UIImage?) {
        guard newImage !== image else { return }
        image = newImage
        imageView.image = newImage
        dragStart = nil
        dragRect = nil
        refit(keepingZoom: false)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
        overlay.frame = bounds
        if bounds.size != fittedFor { refit(keepingZoom: true) }
    }

    /// Fits the picture to the space, keeping any zoom and where it was looking (the keyboard
    /// shrinks the space while a note is typed).
    private func refit(keepingZoom: Bool) {
        fittedFor = bounds.size
        guard let image, image.size.width > 0, image.size.height > 0, bounds.width > 24, bounds.height > 24 else {
            overlay.setNeedsDisplay()
            return
        }
        let zoom = keepingZoom ? scrollView.zoomScale : 1
        let focus = keepingZoom && imageView.bounds.width > 0 ? visibleCenter() : CGPoint(x: 0.5, y: 0.5)
        scrollView.zoomScale = 1
        let room = bounds.insetBy(dx: 12, dy: 12).size
        let scale = min(room.width / image.size.width, room.height / image.size.height)
        let size = CGSize(width: floor(image.size.width * scale), height: floor(image.size.height * scale))
        imageView.frame = CGRect(origin: .zero, size: size)
        imageView.layer.shadowPath = UIBezierPath(rect: CGRect(origin: .zero, size: size)).cgPath
        scrollView.contentSize = size
        centerContent()
        if zoom > 1.01 {
            scrollView.zoomScale = zoom
            look(at: focus)
        }
        overlay.setNeedsDisplay()
    }

    private func visibleCenter() -> CGPoint {
        normalized(scrollView.convert(CGPoint(x: scrollView.bounds.midX, y: scrollView.bounds.midY), to: imageView))
    }

    private func look(at point: CGPoint) {
        let target = CGPoint(x: point.x * imageView.frame.width, y: point.y * imageView.frame.height)
        let inset = scrollView.contentInset
        let maxX = max(-inset.left, scrollView.contentSize.width + inset.right - scrollView.bounds.width)
        let maxY = max(-inset.top, scrollView.contentSize.height + inset.bottom - scrollView.bounds.height)
        scrollView.contentOffset = CGPoint(x: min(max(target.x - scrollView.bounds.width / 2, -inset.left), maxX),
                                           y: min(max(target.y - scrollView.bounds.height / 2, -inset.top), maxY))
    }

    private func centerContent() {
        let dx = max(0, (scrollView.bounds.width - scrollView.contentSize.width) / 2)
        let dy = max(0, (scrollView.bounds.height - scrollView.contentSize.height) / 2)
        scrollView.contentInset = UIEdgeInsets(top: dy, left: dx, bottom: dy, right: dx)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerContent(); overlay.setNeedsDisplay() }
    func scrollViewDidScroll(_ scrollView: UIScrollView) { overlay.setNeedsDisplay() }

    /// The picture's frame on screen, in the overlay's coordinates.
    fileprivate var pictureFrame: CGRect? {
        image == nil ? nil : imageView.convert(imageView.bounds, to: overlay)
    }

    private func normalized(_ point: CGPoint) -> CGPoint {
        let size = imageView.bounds.size
        guard size.width > 0, size.height > 0 else { return .zero }
        return CGPoint(x: min(max(point.x / size.width, 0), 1), y: min(max(point.y / size.height, 0), 1))
    }

    /// The numbered badge under a touch, if any; the newest is on top.
    private func badge(at point: CGPoint) -> Int? {
        guard let frame = pictureFrame else { return nil }
        for (index, rect) in marks.enumerated().reversed() {
            let center = CGPoint(x: frame.minX + rect.minX * frame.width, y: frame.minY + rect.minY * frame.height)
            if hypot(center.x - point.x, center.y - point.y) <= 22 { return index }
        }
        return nil
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        guard image != nil else { return }
        if let index = badge(at: gesture.location(in: overlay)) { onSelect(index); return }
        let point = gesture.location(in: imageView)
        guard imageView.bounds.contains(point) else { return }
        onMark(CGRect(origin: normalized(point), size: .zero))
    }

    @objc private func dragged(_ gesture: UIPanGestureRecognizer) {
        let point = gesture.location(in: imageView)
        switch gesture.state {
        case .began, .changed:
            if gesture.state == .began {
                // Where the finger came down, before the drag was recognized.
                let moved = gesture.translation(in: imageView)
                let start = CGPoint(x: point.x - moved.x, y: point.y - moved.y)
                dragStart = image != nil && imageView.bounds.contains(start) ? normalized(start) : nil
            }
            // A second finger means pinching, not marking.
            if let pinch = scrollView.pinchGestureRecognizer, pinch.state == .began || pinch.state == .changed {
                gesture.isEnabled = false
                gesture.isEnabled = true
                return
            }
            guard let start = dragStart else { return }
            let end = normalized(point)
            dragRect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                              width: abs(end.x - start.x), height: abs(end.y - start.y))
            overlay.setNeedsDisplay()
        case .ended:
            if let start = dragStart, let rect = dragRect {
                onMark(ReviewNotes.isPoint(rect) ? CGRect(origin: start, size: .zero) : rect)
            }
            dragStart = nil
            dragRect = nil
            overlay.setNeedsDisplay()
        default:
            dragStart = nil
            dragRect = nil
            overlay.setNeedsDisplay()
        }
    }

    @objc private func swiped(_ gesture: UISwipeGestureRecognizer) {
        guard scrollView.zoomScale <= scrollView.minimumZoomScale + 0.01 else { return }
        onTurn(gesture.direction == .left ? 1 : -1)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === drag { return other === scrollView.pinchGestureRecognizer }
        return swipes.contains { $0 === gestureRecognizer }
    }
}

/// Draws the marks above the zoomed picture at screen size, so badges stay sharp and touchable.
private final class ReviewMarksOverlay: UIView {
    weak var canvas: ReviewCanvasView?

    override func draw(_ rect: CGRect) {
        guard let canvas, let frame = canvas.pictureFrame, let context = UIGraphicsGetCurrentContext() else { return }
        context.saveGState()
        context.clip(to: frame.insetBy(dx: -14, dy: -14))
        ReviewRendering.draw(canvas.marks, in: frame, badge: 13, line: 2, font: 13,
                             highlighted: canvas.highlighted, context: context)
        if let drag = canvas.dragRect {
            let box = CGRect(x: frame.minX + drag.minX * frame.width, y: frame.minY + drag.minY * frame.height,
                             width: drag.width * frame.width, height: drag.height * frame.height)
            context.setStrokeColor(ReviewRendering.color.cgColor)
            context.setLineWidth(2)
            context.setLineDash(phase: 0, lengths: [6, 4])
            context.stroke(box)
        }
        context.restoreGState()
    }
}

// MARK: - Drawing

enum ReviewRendering {
    static let color = UIColor.systemOrange

    /// Numbered marks: boxes for areas, a badge at each area's top-left corner or on each spot.
    static func draw(_ marks: [CGRect], in frame: CGRect, badge radius: CGFloat, line: CGFloat, font size: CGFloat,
                     highlighted: Int? = nil, context: CGContext) {
        for (index, mark) in marks.enumerated() {
            let rect = CGRect(x: frame.minX + mark.minX * frame.width, y: frame.minY + mark.minY * frame.height,
                              width: mark.width * frame.width, height: mark.height * frame.height)
            let emphasized = index == highlighted
            if !ReviewNotes.isPoint(mark) {
                context.setFillColor(color.withAlphaComponent(emphasized ? 0.2 : 0.12).cgColor)
                context.fill(rect)
                let width = emphasized ? line * 1.75 : line
                context.setStrokeColor(color.cgColor)
                context.setLineWidth(width)
                context.setLineDash(phase: 0, lengths: [])
                context.stroke(rect.insetBy(dx: width / 2, dy: width / 2))
            }
            let center = CGPoint(x: rect.minX, y: rect.minY)
            let circle = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            if emphasized {
                context.setFillColor(color.withAlphaComponent(0.35).cgColor)
                context.fillEllipse(in: circle.insetBy(dx: -radius * 0.45, dy: -radius * 0.45))
            }
            context.setFillColor(color.cgColor)
            context.fillEllipse(in: circle)
            let ring = radius * 0.11
            context.setStrokeColor(UIColor.white.cgColor)
            context.setLineWidth(ring)
            context.strokeEllipse(in: circle.insetBy(dx: ring / 2, dy: ring / 2))
            let label = NSAttributedString(string: "\(index + 1)", attributes: [
                .font: UIFont.systemFont(ofSize: size, weight: .bold), .foregroundColor: UIColor.white,
            ])
            let labelSize = label.size()
            UIGraphicsPushContext(context)
            label.draw(at: CGPoint(x: center.x - labelSize.width / 2, y: center.y - labelSize.height / 2))
            UIGraphicsPopContext()
        }
    }

    /// The image no longer than `maxEdge` pixels, with its numbered marks drawn as on the Mac.
    static func annotated(_ image: UIImage, marks: [CGRect], maxEdge: CGFloat) -> UIImage {
        let pixels = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let edge = max(pixels.width, pixels.height)
        guard edge > 0 else { return image }
        let ratio = min(1, maxEdge / edge)
        let target = CGSize(width: (pixels.width * ratio).rounded(), height: (pixels.height * ratio).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { context in
            let frame = CGRect(origin: .zero, size: target)
            image.draw(in: frame)
            // As on the Mac (a thousandth of the long side), but legible on small images too.
            let unit = max(max(target.width, target.height) / 1000, 1)
            draw(marks, in: frame, badge: 24 * unit, line: 4 * unit, font: 26 * unit, context: context.cgContext)
        }
    }

    /// A PDF page as a picture with its long side `longSide` pixels, as the viewer shows it
    /// (crop box, rotation and annotations).
    static func page(_ page: PDFPage, longSide: CGFloat) -> UIImage {
        let box = page.bounds(for: .cropBox)
        let turned = abs(page.rotation) % 180 == 90
        let size = turned ? CGSize(width: box.height, height: box.width) : box.size
        guard size.width > 0, size.height > 0 else { return UIImage() }
        let scale = longSide / max(size.width, size.height)
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: target, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: target))
            let cg = context.cgContext
            // PDF space has its origin at the bottom left; draw(with:to:) applies the rotation.
            cg.translateBy(x: 0, y: target.height)
            cg.scaleBy(x: target.width / size.width, y: -target.height / size.height)
            page.draw(with: .cropBox, to: cg)
        }
    }

    /// Ready for the message box: PNG, or JPEG when a PNG would be heavy (photos).
    static func pending(_ image: UIImage, name: String) -> PendingImage? {
        guard var data = image.pngData() else { return nil }
        if data.count > 3_000_000, let jpeg = image.jpegData(compressionQuality: 0.9) { data = jpeg }
        return PendingImage(preview: image, upload: .init(name: name, data: data))
    }
}

/// The window's size, which the keyboard doesn't change (unlike the space a view gets).
private struct ReviewWindowProbe: UIViewRepresentable {
    @Binding var size: CGSize

    func makeUIView(context: Context) -> Probe {
        let probe = Probe()
        probe.report = { value in if size != value { size = value } }
        return probe
    }

    func updateUIView(_ probe: Probe, context: Context) {
        probe.report = { value in if size != value { size = value } }
    }

    final class Probe: UIView {
        var report: (CGSize) -> Void = { _ in }
        override func didMoveToWindow() { super.didMoveToWindow(); check() }
        override func layoutSubviews() { super.layoutSubviews(); check() }
        private func check() {
            guard let size = window?.bounds.size else { return }
            DispatchQueue.main.async { [weak self] in self?.report(size) }
        }
    }
}
