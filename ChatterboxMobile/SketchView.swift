import PencilKit
import SwiftUI

/// What the sketch opens with: a blank page, or an image from the chat to draw on.
struct SketchRequest: Identifiable {
    let id = UUID()
    var background: UIImage?
}

/// A full-screen canvas for the Pencil (or a finger): sketch something, or mark up an image.
/// Done hands back the finished picture, ready to send with a message.
struct SketchView: View {
    let request: SketchRequest
    let onDone: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var canvas = PKCanvasView()
    /// Only the Pencil draws; a finger moves and zooms the page instead. Remembered.
    @AppStorage("sketchPencilOnly") private var pencilOnly = false

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                let size = fittedSize(in: proxy.size)
                CanvasHost(canvas: canvas, background: request.background, pencilOnly: pencilOnly)
                    .frame(width: size.width, height: size.height)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: request.background == nil ? 0 : 6))
                    .shadow(color: .black.opacity(request.background == nil ? 0 : 0.2), radius: 8)
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(request.background == nil ? "Sketch" : "Mark Up")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                // Undo and Redo are on PencilKit's own palette, so the bar keeps room for Done.
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { pencilOnly.toggle() } label: {
                        Image(systemName: pencilOnly ? "applepencil.tip" : "hand.draw")
                    }
                    .accessibilityLabel(pencilOnly ? "Pencil Only: on" : "Pencil Only: off")
                    .accessibilityHint(pencilOnly ? "Fingers draw too" : "Only the Pencil draws; a finger moves the page")
                    .accessibilityIdentifier("sketch-pencil-only")
                    Button("Clear") { canvas.drawing = PKDrawing() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onDone(render())
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

    /// The drawing over its image at the image's own resolution, or over white at the screen's.
    private func render() -> UIImage {
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

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        let toolPicker = PKToolPicker()
        var imageView: UIImageView?

        /// The image covers the zoomed page: the canvas's content, as it grows and moves.
        func fit(_ canvas: PKCanvasView) {
            imageView?.frame = CGRect(origin: .zero, size: canvas.contentSize)
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

