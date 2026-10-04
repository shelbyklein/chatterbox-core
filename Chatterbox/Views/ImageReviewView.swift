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

/// A large view of an image where you mark areas and write a note for each. Sending attaches
/// a copy with the numbered marks drawn on it, plus the original, and lists the notes.
struct ImageReviewView: View {
    let attachment: Attachment
    let onSend: (_ text: String, _ attachments: [Attachment]) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var image: NSImage?
    @State private var marks: [ImageMark] = []
    @State private var dragStart: CGPoint?
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
            Divider()
            sidebar.frame(width: 280)
        }
        .frame(minWidth: 900, minHeight: 600)
        .task { image = NSImage(contentsOf: attachment.url) }
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
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let start = normalized(value.startLocation, in: fitted)
                            let end = normalized(value.location, in: fitted)
                            dragRect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                                              width: abs(end.x - start.x), height: abs(end.y - start.y))
                        }
                        .onEnded { value in
                            let start = normalized(value.startLocation, in: fitted)
                            let end = normalized(value.location, in: fitted)
                            dragRect = nil
                            // Clicks outside the picture don't make marks.
                            guard fitted.contains(value.startLocation) else { return }
                            let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                                              width: abs(end.x - start.x), height: abs(end.y - start.y))
                            let mark = ImageMark(rect: rect.width < 0.01 && rect.height < 0.01
                                                 ? CGRect(origin: start, size: .zero) : rect)
                            marks.append(mark)
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
            Text("Drag to mark an area, or click to mark a spot. Add a note for each mark.")
                .font(.caption).foregroundStyle(.secondary)

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
                            Button { marks.removeAll { $0.id == mark.id } } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).foregroundStyle(.secondary).help("Remove mark")
                        }
                    }
                    if marks.isEmpty {
                        Text("No marks yet.").font(.callout).foregroundStyle(.tertiary)
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
                    Button("Clear Marks") { marks.removeAll() }
                }
                .fixedSize()
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Send to Chat") { send() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(marks.isEmpty && overall.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
    }

    // MARK: - Sending

    private func send() {
        guard let image else { return }
        var attachments = [attachment]
        if !marks.isEmpty {
            do {
                attachments.insert(try Attachments.importImageData(Self.annotated(image, marks: marks), name: "Marked up \((attachment.name as NSString).deletingPathExtension)"), at: 0)
            } catch {
                self.error = "Couldn't draw the marks: \(error.localizedDescription)"
                return
            }
        }
        var lines: [String] = []
        if !marks.isEmpty {
            lines.append("Feedback on \(attachment.name). The first attached image has numbered marks; the second is the original.")
            for (index, mark) in marks.enumerated() {
                let note = mark.comment.trimmingCharacters(in: .whitespacesAndNewlines)
                lines.append("\(index + 1). \(Self.describe(mark.rect)): \(note.isEmpty ? "(no note)" : note)")
            }
        }
        let overallNote = overall.trimmingCharacters(in: .whitespacesAndNewlines)
        if !overallNote.isEmpty { lines.append(marks.isEmpty ? overallNote : "\nOverall: \(overallNote)") }
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

    /// The image at full size with numbered orange marks drawn on it, as PNG data.
    static func annotated(_ image: NSImage, marks: [ImageMark]) -> Data {
        let size = image.representations.first.map { CGSize(width: $0.pixelsWide, height: $0.pixelsHigh) } ?? image.size
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: CGRect(origin: .zero, size: size))
        let scale = max(size.width, size.height) / 1000
        let orange = NSColor.systemOrange
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
