import PencilKit
import SwiftUI

/// What the sketch opens with: a blank page, or an image from the chat to draw on.
struct SketchRequest: Identifiable {
    let id = UUID()
    var background: UIImage?
}

/// A note pinned to a spot in Mark Up: where (0–1 of the page) and what it says.
struct SketchNote: Identifiable, Equatable {
    let id = UUID()
    var point: CGPoint
    var text: String
}

/// A full-screen canvas for the Pencil (or a finger): sketch something, or mark up an image.
/// Comment mode pins numbered notes to spots. Done hands back the finished picture (drawing and
/// numbered pins) and the notes as text, ready to send with a message.
struct SketchView: View {
    let request: SketchRequest
    let onDone: (UIImage, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var canvas = PKCanvasView()
    /// Only the Pencil draws; a finger moves and zooms the page instead. Remembered.
    @AppStorage("sketchPencilOnly") private var pencilOnly = false
    /// Comment mode: drawing pauses, and a tap pins a numbered note there.
    @State private var commenting = false
    @State private var notes: [SketchNote] = []
    /// The spot just tapped, waiting for its note.
    @State private var pending: CGPoint?
    @State private var noteText = ""

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                let size = fittedSize(in: proxy.size)
                CanvasHost(canvas: canvas, background: request.background, pencilOnly: pencilOnly,
                           commenting: commenting, notes: notes) { point in noteText = ""; pending = point }
                    .frame(width: size.width, height: size.height)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: request.background == nil ? 0 : 6))
                    .shadow(color: .black.opacity(request.background == nil ? 0 : 0.2), radius: 8)
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .alert("Note \(notes.count + 1)", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
                TextField("What about this spot?", text: $noteText, axis: .vertical)
                Button("Add") {
                    let text = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let point = pending, !text.isEmpty { notes.append(SketchNote(point: point, text: text)) }
                    pending = nil
                }
                Button("Cancel", role: .cancel) { pending = nil }
            }
            .navigationTitle(commenting ? "Tap to Comment" : request.background == nil ? "Sketch" : "Mark Up")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                // Undo and Redo are on PencilKit's own palette, so the bar keeps room for Done.
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { commenting.toggle() } label: {
                        Image(systemName: commenting ? "text.bubble.fill" : "text.bubble")
                    }
                    .accessibilityLabel(commenting ? "Comment: on" : "Comment: off")
                    .accessibilityHint("Tap a spot to pin a note there")
                    .accessibilityIdentifier("sketch-comment")
                    Button { pencilOnly.toggle() } label: {
                        Image(systemName: pencilOnly ? "applepencil.tip" : "hand.draw")
                    }
                    .accessibilityLabel(pencilOnly ? "Pencil Only: on" : "Pencil Only: off")
                    .accessibilityHint(pencilOnly ? "Fingers draw too" : "Only the Pencil draws; a finger moves the page")
                    .accessibilityIdentifier("sketch-pencil-only")
                    Button("Clear") { canvas.drawing = PKDrawing(); notes = [] }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onDone(render(), notesText)
                        dismiss()
                    }
                    .bold()
                }
            }
        }
    }

    /// A blank sketch fills the screen; an image keeps its shape, as large as fits.
    private func fittedSize(in space: CGSize) -> CGSize {
        guard let image = request.background, image.size.width > 0, image.size.height > 0 else { return space }
        let available = CGSize(width: space.width - 32, height: space.height - 32)
        let scale = min(available.width / image.size.width, available.height / image.size.height)
        return CGSize(width: image.size.width * scale, height: image.size.height * scale)
    }

    /// The notes for the message: numbered as their pins on the picture.
    private var notesText: String {
        guard !notes.isEmpty else { return "" }
        return (["Notes on the marked-up picture (numbered as on it):"]
                + notes.enumerated().map { "\($0.offset + 1). \($0.element.text)" }).joined(separator: "\n")
    }

    /// The drawing over its image at the image's own resolution (or over white at the screen's),
    /// with each note's numbered pin, drawn as the Comment view draws its marks.
    private func render() -> UIImage {
        let drawn = renderDrawing()
        guard !notes.isEmpty else { return drawn }
        let pixels = max(drawn.size.width * drawn.scale, drawn.size.height * drawn.scale)
        return ReviewRendering.annotated(drawn, marks: notes.map { CGRect(origin: $0.point, size: .zero) }, maxEdge: pixels)
    }

    private func renderDrawing() -> UIImage {
        // The whole page at 1×, whatever's zoomed into: the canvas's own frame, from its origin.
        let bounds = CGRect(origin: .zero, size: canvas.frame.size)
        guard bounds.width > 0 else { return UIImage() }
        let outputSize = request.background?.size ?? bounds.size
        let scale = outputSize.width / bounds.width
        let format = UIGraphicsImageRendererFormat()
        format.scale = request.background == nil ? UIScreen.main.scale : (request.background?.scale ?? 1)
        return UIGraphicsImageRenderer(size: outputSize, format: format).image { context in
            let rect = CGRect(origin: .zero, size: outputSize)
            if let background = request.background {
                background.draw(in: rect)
            } else {
                UIColor.white.setFill()
                context.fill(rect)
            }
            canvas.drawing.image(from: bounds, scale: format.scale * scale).draw(in: rect)
        }
    }
}

/// PencilKit's canvas and tool palette, with the image being marked up inside it: pinch to
/// zoom, two fingers to pan (one finger or the Pencil draws), and the image zooms and pans with
/// the marks.
private struct CanvasHost: UIViewRepresentable {
    let canvas: PKCanvasView
    let background: UIImage?
    var pencilOnly = false
    var commenting = false
    var notes: [SketchNote] = []
    /// A tap in Comment mode: the spot, 0–1 of the page.
    var onTap: (CGPoint) -> Void = { _ in }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        let toolPicker = PKToolPicker()
        var imageView: UIImageView?
        var onTap: (CGPoint) -> Void = { _ in }
        var tap: UITapGestureRecognizer?
        /// The pins, numbered, inside the canvas so they move with the page.
        var pins: [UILabel] = []
        var points: [CGPoint] = []

        /// The image covers the zoomed page: the canvas's content, as it grows and moves; the
        /// pins sit at their spots on it.
        func fit(_ canvas: PKCanvasView) {
            imageView?.frame = CGRect(origin: .zero, size: canvas.contentSize)
            for (pin, point) in zip(pins, points) {
                pin.center = CGPoint(x: point.x * canvas.contentSize.width, y: point.y * canvas.contentSize.height)
            }
        }

        func show(_ notes: [SketchNote], on canvas: PKCanvasView) {
            guard notes.map(\.point) != points || pins.count != notes.count else { return }
            pins.forEach { $0.removeFromSuperview() }
            points = notes.map(\.point)
            pins = notes.indices.map { index in
                let pin = UILabel(frame: CGRect(x: 0, y: 0, width: 28, height: 28))
                pin.text = "\(index + 1)"
                pin.font = .systemFont(ofSize: 14, weight: .bold)
                pin.textAlignment = .center
                pin.textColor = .white
                pin.backgroundColor = .systemRed
                pin.layer.cornerRadius = 14
                pin.layer.borderColor = UIColor.white.cgColor
                pin.layer.borderWidth = 2
                pin.clipsToBounds = true
                pin.isUserInteractionEnabled = false
                canvas.addSubview(pin)
                return pin
            }
            fit(canvas)
        }

        @objc func tapped(_ gesture: UITapGestureRecognizer) {
            guard let canvas = gesture.view as? PKCanvasView, canvas.frame.width > 0, canvas.zoomScale > 0 else { return }
            // In the page's own 1× coordinates, whatever's zoomed in.
            let at = gesture.location(in: canvas)
            let page = CGSize(width: canvas.contentSize.width, height: canvas.contentSize.height)
            guard page.width > 0, page.height > 0 else { return }
            onTap(CGPoint(x: min(max(at.x / page.width, 0), 1), y: min(max(at.y / page.height, 0), 1)))
        }
        func scrollViewDidZoom(_ scrollView: UIScrollView) { if let c = scrollView as? PKCanvasView { fit(c) } }
        func scrollViewDidScroll(_ scrollView: UIScrollView) { if let c = scrollView as? PKCanvasView { fit(c) } }
    }

    /// Keeps the page the canvas's size at 1× when the view's size settles or changes.
    final class Container: UIView {
        var canvas: PKCanvasView?
        var coordinator: Coordinator?
        override func layoutSubviews() {
            super.layoutSubviews()
            guard let canvas else { return }
            canvas.frame = bounds
            if canvas.zoomScale == 1 { canvas.contentSize = bounds.size }
            coordinator?.fit(canvas)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let container = Container()
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        // The Pencil draws; a finger draws too unless Pencil Only is on (then it moves the page).
        canvas.drawingPolicy = pencilOnly ? .pencilOnly : .anyInput
        canvas.tool = PKInkingTool(.pen, color: .systemRed, width: 6)
        // Pinch to zoom in close, two fingers to move around.
        canvas.minimumZoomScale = 1
        canvas.maximumZoomScale = 6
        canvas.bouncesZoom = true
        canvas.showsHorizontalScrollIndicator = false
        canvas.showsVerticalScrollIndicator = false
        canvas.delegate = context.coordinator
        if let background {
            // Inside the canvas, under the strokes, so it zooms and pans with them.
            let imageView = UIImageView(image: background)
            imageView.contentMode = .scaleToFill
            canvas.insertSubview(imageView, at: 0)
            context.coordinator.imageView = imageView
        }
        container.canvas = canvas
        container.coordinator = context.coordinator
        container.addSubview(canvas)

        let picker = context.coordinator.toolPicker
        picker.setVisible(true, forFirstResponder: canvas)
        picker.addObserver(canvas)
        DispatchQueue.main.async { canvas.becomeFirstResponder() }
        return container
    }

    func updateUIView(_ view: UIView, context: Context) {
        canvas.drawingPolicy = pencilOnly ? .pencilOnly : .anyInput
        // Comment mode: no drawing; a tap pins a note (zoom and two-finger pan still work).
        canvas.drawingGestureRecognizer.isEnabled = !commenting
        context.coordinator.onTap = onTap
        if commenting, context.coordinator.tap == nil {
            let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
            canvas.addGestureRecognizer(tap)
            context.coordinator.tap = tap
        }
        context.coordinator.tap?.isEnabled = commenting
        context.coordinator.show(notes, on: canvas)
    }
}

/// Top bar: screenshot the app, mark it up, then finish the note in the Chatterbox session.
struct FeedbackButton: View {
    @Environment(MobileStore.self) private var store
    var body: some View {
        Button { store.startFeedback() } label: { Image(systemName: "exclamationmark.bubble") }
            .accessibilityLabel("Feedback")
    }
}

