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

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                let size = fittedSize(in: proxy.size)
                CanvasHost(canvas: canvas, background: request.background)
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
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { canvas.undoManager?.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                        .accessibilityLabel("Undo")
                    Button { canvas.undoManager?.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                        .accessibilityLabel("Redo")
                    Button("Clear") { canvas.drawing = PKDrawing() }
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
        let bounds = canvas.bounds
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

/// PencilKit's canvas and tool palette, over the image being marked up.
private struct CanvasHost: UIViewRepresentable {
    let canvas: PKCanvasView
    let background: UIImage?

    final class Coordinator {
        let toolPicker = PKToolPicker()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        if let background {
            let imageView = UIImageView(image: background)
            imageView.contentMode = .scaleToFill
            imageView.frame = container.bounds
            imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            container.addSubview(imageView)
        }
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        // The Pencil draws; a finger draws too, so it works without one (and on iPhone).
        canvas.drawingPolicy = .anyInput
        canvas.tool = PKInkingTool(.pen, color: .systemRed, width: 6)
        canvas.frame = container.bounds
        canvas.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(canvas)

        let picker = context.coordinator.toolPicker
        picker.setVisible(true, forFirstResponder: canvas)
        picker.addObserver(canvas)
        DispatchQueue.main.async { canvas.becomeFirstResponder() }
        return container
    }

    func updateUIView(_ view: UIView, context: Context) {}
}
