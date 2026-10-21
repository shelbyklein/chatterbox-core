import AppKit
import SwiftUI

/// Opens an image from the chat in the review window. Set by ChatView.
struct ImageReviewAction {
    var open: (Attachment) -> Void = { NSWorkspace.shared.open($0.url) }
}

private struct ImageReviewKey: EnvironmentKey {
    static let defaultValue = ImageReviewAction()
}

extension EnvironmentValues {
    var reviewImage: ImageReviewAction {
        get { self[ImageReviewKey.self] }
        set { self[ImageReviewKey.self] = newValue }
    }
}

/// One numbered mark on an image, in 0–1 coordinates so it survives resizing.
/// A point mark has zero size.
struct ImageMark: Identifiable {
    var id = UUID()
    var rect: CGRect
    var comment = ""
    var isPoint: Bool { rect.width < 0.01 && rect.height < 0.01 }
}

/// Points are normalized to the image, independent of the review window's size.
struct ImageStroke: Identifiable {
    var id = UUID()
    var points: [CGPoint]

    func path(in rect: CGRect, flipped: Bool = false) -> CGPath {
        let path = CGMutablePath()
        for (index, point) in points.enumerated() {
            let position = CGPoint(x: rect.minX + point.x * rect.width,
                                   y: rect.minY + (flipped ? 1 - point.y : point.y) * rect.height)
            if index == 0 { path.move(to: position) } else { path.addLine(to: position) }
        }
        return path
    }
}

enum ImageReviewTool: Hashable { case pen, notes }
private enum ImageReviewEdit: Equatable { case stroke(UUID), mark(UUID) }

/// Draw feedback on a copy of the image and send it, together with the original, to the chat.
struct ImageReviewView: View {
    /// The image showing; Previous and Next move it through the chat's other images.
    @State private var attachment: Attachment
    /// The chat's images in order, for Previous and Next (empty: just this one).
    let gallery: [URL]
    let onSend: (_ text: String, _ attachments: [Attachment]) -> Void

    init(attachment: Attachment, gallery: [URL] = [], initialTool: ImageReviewTool = .pen,
         onSend: @escaping (_ text: String, _ attachments: [Attachment]) -> Void) {
        _attachment = State(initialValue: attachment)
        _tool = State(initialValue: initialTool)
        self.gallery = gallery
        self.onSend = onSend
    }
    /// Marks and notes made on other images while browsing, kept until the sheet closes.
    @State private var drafts: [String: (marks: [ImageMark], strokes: [ImageStroke], edits: [ImageReviewEdit], overall: String)] = [:]
    @Environment(\.dismiss) private var dismiss

    @State private var image: NSImage?
    @State private var marks: [ImageMark] = []
    @State private var strokes: [ImageStroke] = []
    @State private var activePoints: [CGPoint] = []
    @State private var edits: [ImageReviewEdit] = []
    @State private var tool: ImageReviewTool
    @State private var dragRect: CGRect?
    @State private var overall = ""
    @State private var error: String?
    @FocusState private var focusedMark: UUID?

    private let markColor = Color.orange

    var body: some View {
        HStack(spacing: 0) {
            canvas
                .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.85))
                .overlay { browseButtons }
            Divider()
            sidebar.frame(width: 280)
        }
        .frame(minWidth: 900, minHeight: 600)
        .task(id: attachment.path) { image = NSImage(contentsOf: attachment.url) }
    }

    // MARK: - Browsing

    private var position: Int? { gallery.firstIndex { $0.path == attachment.path } }

    /// Moves to the previous (-1) or next (+1) image in the chat, keeping each one's marks.
    private func step(_ offset: Int) {
        guard let position, gallery.indices.contains(position + offset) else { return }
        let url = gallery[position + offset]
        drafts[attachment.path] = (marks, strokes, edits, overall)
        let draft = drafts[url.path]
        marks = draft?.marks ?? []
        strokes = draft?.strokes ?? []
        edits = draft?.edits ?? []
        activePoints = []
        dragRect = nil
        overall = draft?.overall ?? ""
        error = nil
        image = nil
        attachment = Attachment(name: url.lastPathComponent, path: url.path,
                                mediaType: "image/" + url.pathExtension.lowercased(), kind: .image)
    }

    @ViewBuilder private var browseButtons: some View {
        if let position, gallery.count > 1 {
            HStack {
                // ⌘[ and ⌘], not bare arrows: those move the cursor in the note fields.
                browseButton("chevron.left", "Previous image (⌘[)", enabled: position > 0) { step(-1) }
                    .keyboardShortcut("[", modifiers: .command)
                Spacer()
                browseButton("chevron.right", "Next image (⌘])", enabled: position < gallery.count - 1) { step(1) }
                    .keyboardShortcut("]", modifiers: .command)
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottom) {
                Text("\(position + 1) of \(gallery.count)")
                    .font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(.black.opacity(0.55)))
                    .padding(.bottom, 14)
                    .allowsHitTesting(false)
            }
        }
    }

    private func browseButton(_ symbol: String, _ label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 18, weight: .semibold))
                .frame(width: 40, height: 40)
                .background(Circle().fill(.black.opacity(0.55)))
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.25)
        .disabled(!enabled)
        .help(label)
        .accessibilityLabel(label)
    }

    // MARK: - Image and marks

    private var canvas: some View {
        GeometryReader { geo in
            if let image {
                let fitted = fittedRect(image.size, in: geo.size)
                ZStack(alignment: .topLeading) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: fitted.width, height: fitted.height)
                        .offset(x: fitted.minX, y: fitted.minY)
                    Canvas { context, size in
                        let rect = CGRect(origin: .zero, size: size)
                        let width = max(size.width, size.height) * 0.004
                        for stroke in strokes + (activePoints.isEmpty ? [] : [ImageStroke(points: activePoints)]) {
                            if stroke.points.count == 1, let point = stroke.points.first {
                                let dot = CGRect(x: point.x * size.width - width / 2, y: point.y * size.height - width / 2,
                                                 width: width, height: width)
                                context.fill(Path(ellipseIn: dot), with: .color(markColor))
                            } else {
                                context.stroke(Path(stroke.path(in: rect)), with: .color(markColor),
                                               style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
                            }
                        }
                    }
                    .frame(width: fitted.width, height: fitted.height)
                    .clipped()
                    .offset(x: fitted.minX, y: fitted.minY)
                    .allowsHitTesting(false)
                    ForEach(Array(marks.enumerated()), id: \.element.id) { index, mark in
                        markView(index + 1, mark.rect, in: fitted, highlighted: focusedMark == mark.id)
                    }
                    if let dragRect {
                        Rectangle()
                            .strokeBorder(markColor, style: StrokeStyle(lineWidth: 2, dash: [5]))
                            .frame(width: dragRect.width * fitted.width, height: dragRect.height * fitted.height)
                            .offset(x: fitted.minX + dragRect.minX * fitted.width, y: fitted.minY + dragRect.minY * fitted.height)
                    }
                }
                // The whole canvas takes clicks. The picture is moved into place by offsets,
                // which don't move a view's frame: sized to the picture alone, the clickable
                // area stayed at the left and missed the picture's right side.
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard fitted.contains(value.startLocation) else { return }
                            let start = normalized(value.startLocation, in: fitted)
                            let end = normalized(value.location, in: fitted)
                            if tool == .pen {
                                if activePoints.isEmpty { activePoints = [start] }
                                if let last = activePoints.last, hypot(end.x - last.x, end.y - last.y) > 0.001 {
                                    activePoints.append(end)
                                }
                                return
                            }
                            dragRect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                                              width: abs(end.x - start.x), height: abs(end.y - start.y))
                        }
                        .onEnded { value in
                            let start = normalized(value.startLocation, in: fitted)
                            let end = normalized(value.location, in: fitted)
                            dragRect = nil
                            // Clicks outside the picture don't make marks.
                            guard fitted.contains(value.startLocation) else { return }
                            if tool == .pen {
                                var points = activePoints.isEmpty ? [start] : activePoints
                                if points.last != end { points.append(end) }
                                let stroke = ImageStroke(points: points)
                                strokes.append(stroke)
                                edits.append(.stroke(stroke.id))
                                activePoints = []
                                return
                            }
                            let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                                              width: abs(end.x - start.x), height: abs(end.y - start.y))
                            let mark = ImageMark(rect: rect.width < 0.01 && rect.height < 0.01
                                                 ? CGRect(origin: start, size: .zero) : rect)
                            marks.append(mark)
                            edits.append(.mark(mark.id))
                            focusedMark = mark.id
                        }
                )
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(16)
    }

    private func markView(_ number: Int, _ rect: CGRect, in fitted: CGRect, highlighted: Bool) -> some View {
        let origin = CGPoint(x: fitted.minX + rect.minX * fitted.width, y: fitted.minY + rect.minY * fitted.height)
        let size = CGSize(width: rect.width * fitted.width, height: rect.height * fitted.height)
        let isPoint = rect.width < 0.01 && rect.height < 0.01
        return ZStack(alignment: .topLeading) {
            if !isPoint {
                Rectangle()
                    .strokeBorder(markColor, lineWidth: highlighted ? 3 : 2)
                    .background(markColor.opacity(highlighted ? 0.15 : 0.06))
                    .frame(width: size.width, height: size.height)
                    .offset(x: origin.x, y: origin.y)
            }
            Text("\(number)")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(markColor))
                .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
                .offset(x: origin.x - 11, y: origin.y - 11)
        }
        .allowsHitTesting(false)
    }

    // MARK: - Notes

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(attachment.name).font(.headline).lineLimit(1).truncationMode(.middle)
            Picker("Annotation tool", selection: $tool) {
                Label("Pen", systemImage: "pencil.tip").tag(ImageReviewTool.pen)
                Text("Numbered notes").tag(ImageReviewTool.notes)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(tool == .pen ? "Drag on the image to draw." : "Drag to mark an area, or click to mark a spot. Add a note for each mark.")
                .font(.caption).foregroundStyle(.secondary)
            Button(action: undo) { Label("Undo", systemImage: "arrow.uturn.backward") }
                .disabled(edits.isEmpty)
                .accessibilityLabel("Undo annotation")

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(marks.enumerated()), id: \.element.id) { index, mark in
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(index + 1)")
                                .font(.caption.weight(.bold)).foregroundStyle(.white)
                                .frame(width: 20, height: 20).background(Circle().fill(markColor))
                            TextField("What should change here?", text: $marks[index].comment, axis: .vertical)
                                .textFieldStyle(.roundedBorder)
                                .lineLimit(1...4)
                                .focused($focusedMark, equals: mark.id)
                            Button {
                                marks.removeAll { $0.id == mark.id }
                                edits.removeAll { $0 == .mark(mark.id) }
                            } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).foregroundStyle(.secondary).help("Remove mark")
                        }
                    }
                    if marks.isEmpty && strokes.isEmpty {
                        Text("No annotations yet.").font(.callout).foregroundStyle(.tertiary)
                    }
                }
            }

            Text("Overall note").font(.caption).foregroundStyle(.secondary)
            TextField("Optional", text: $overall, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...5)

            if let error { Text(error).font(.caption).foregroundStyle(.orange) }

            HStack {
                Menu("More") {
                    Button("Copy Image") { ImageClipboard.copy(attachment.url) }
                    Button("Open in Preview") { NSWorkspace.shared.open(attachment.url) }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([attachment.url]) }
                    Button("Clear Annotations") { marks.removeAll(); strokes.removeAll(); edits.removeAll() }
                }
                .fixedSize()
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Send to Session") { send() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(image == nil || (marks.isEmpty && strokes.isEmpty && overall.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
        }
        .padding(16)
    }

    // MARK: - Sending

    private func undo() {
        guard let edit = edits.popLast() else { return }
        switch edit {
        case .stroke(let id): strokes.removeAll { $0.id == id }
        case .mark(let id): marks.removeAll { $0.id == id }
        }
    }

    private func send() {
        guard let image else { return }
        var attachments = [attachment]
        let hasAnnotations = !marks.isEmpty || !strokes.isEmpty
        if hasAnnotations {
            do {
                attachments.insert(try Attachments.importImageData(Self.annotated(image, marks: marks, strokes: strokes), name: "Marked up \((attachment.name as NSString).deletingPathExtension)"), at: 0)
            } catch {
                self.error = "Couldn't draw the marks: \(error.localizedDescription)"
                return
            }
        }
        var lines: [String] = []
        if hasAnnotations {
            lines.append("Feedback on \(attachment.name). The first attached image is annotated; the second is the original.")
            for (index, mark) in marks.enumerated() {
                let note = mark.comment.trimmingCharacters(in: .whitespacesAndNewlines)
                lines.append("\(index + 1). \(Self.describe(mark.rect)): \(note.isEmpty ? "(no note)" : note)")
            }
        }
        let overallNote = overall.trimmingCharacters(in: .whitespacesAndNewlines)
        if !overallNote.isEmpty { lines.append(hasAnnotations ? "\nOverall: \(overallNote)" : overallNote) }
        onSend(lines.joined(separator: "\n"), attachments)
        dismiss()
    }

    /// Where a mark sits, in words and percentages, so agents that can't see the drawing still know.
    static func describe(_ rect: CGRect) -> String {
        let cx = rect.midX, cy = rect.midY
        let vertical = cy < 0.33 ? "top" : cy > 0.66 ? "bottom" : "middle"
        let horizontal = cx < 0.33 ? "left" : cx > 0.66 ? "right" : "center"
        let place = vertical == "middle" && horizontal == "center" ? "center" : "\(vertical) \(horizontal)"
        let pct = { (v: CGFloat) in Int((v * 100).rounded()) }
        if rect.width < 0.01 && rect.height < 0.01 {
            return "spot at \(place) (x \(pct(rect.minX))%, y \(pct(rect.minY))%)"
        }
        return "area at \(place) (x \(pct(rect.minX))–\(pct(rect.maxX))%, y \(pct(rect.minY))–\(pct(rect.maxY))%)"
    }

    /// The image at full size with pen strokes and numbered marks drawn on it, as PNG data.
    static func annotated(_ image: NSImage, marks: [ImageMark], strokes: [ImageStroke] = []) -> Data {
        let size = image.representations.first.map { CGSize(width: $0.pixelsWide, height: $0.pixelsHigh) } ?? image.size
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: CGRect(origin: .zero, size: size))
        let scale = max(size.width, size.height) / 1000
        let orange = NSColor.systemOrange
        if let context = NSGraphicsContext.current?.cgContext {
            context.saveGState()
            context.clip(to: CGRect(origin: .zero, size: size))
            context.setStrokeColor(orange.cgColor)
            context.setFillColor(orange.cgColor)
            context.setLineWidth(4 * scale)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            for stroke in strokes {
                if stroke.points.count == 1, let point = stroke.points.first {
                    context.fillEllipse(in: CGRect(x: point.x * size.width - 2 * scale,
                                                   y: (1 - point.y) * size.height - 2 * scale,
                                                   width: 4 * scale, height: 4 * scale))
                } else {
                    context.addPath(stroke.path(in: CGRect(origin: .zero, size: size), flipped: true))
                    context.strokePath()
                }
            }
            context.restoreGState()
        }
        for (index, mark) in marks.enumerated() {
            // Flip: marks use a top-left origin, AppKit drawing uses bottom-left.
            let rect = CGRect(x: mark.rect.minX * size.width, y: (1 - mark.rect.maxY) * size.height,
                              width: mark.rect.width * size.width, height: mark.rect.height * size.height)
            if !mark.isPoint {
                orange.withAlphaComponent(0.12).setFill()
                NSBezierPath(rect: rect).fill()
                orange.setStroke()
                let border = NSBezierPath(rect: rect)
                border.lineWidth = 4 * scale
                border.stroke()
            }
            let radius = 24 * scale
            let center = CGPoint(x: rect.minX, y: rect.maxY)
            let badge = NSBezierPath(ovalIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            orange.setFill()
            badge.fill()
            NSColor.white.setStroke()
            badge.lineWidth = 2.5 * scale
            badge.stroke()
            let label = NSAttributedString(string: "\(index + 1)", attributes: [
                .font: NSFont.boldSystemFont(ofSize: 26 * scale), .foregroundColor: NSColor.white,
            ])
            let labelSize = label.size()
            label.draw(at: CGPoint(x: center.x - labelSize.width / 2, y: center.y - labelSize.height / 2))
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }

    // MARK: - Geometry

    private func fittedRect(_ imageSize: CGSize, in container: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: (container.width - size.width) / 2, y: (container.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    private func normalized(_ point: CGPoint, in fitted: CGRect) -> CGPoint {
        CGPoint(x: min(max((point.x - fitted.minX) / fitted.width, 0), 1),
                y: min(max((point.y - fitted.minY) / fitted.height, 0), 1))
    }
}
