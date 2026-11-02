import CoreGraphics
import Foundation

/// Review feedback in words, the same on the Mac and the phone: numbered marks on an image or
/// on a PDF's pages, each placed in words and percentages so an agent that can't see the
/// marked-up copy still knows where it is.
enum ReviewNotes {
    /// One mark, in 0–1 coordinates of its image or page (a point mark has zero size).
    struct Mark: Equatable {
        /// 1-based page number for a PDF; nil for an image.
        var page: Int?
        var rect: CGRect
        var comment: String
    }

    static func isPoint(_ rect: CGRect) -> Bool { rect.width < 0.01 && rect.height < 0.01 }

    /// "spot at top left (x 12%, y 8%)" or "area at middle right (x 60–90%, y 40–55%)".
    static func describe(_ rect: CGRect) -> String {
        let cx = rect.midX, cy = rect.midY
        let vertical = cy < 0.33 ? "top" : cy > 0.66 ? "bottom" : "middle"
        let horizontal = cx < 0.33 ? "left" : cx > 0.66 ? "right" : "center"
        let place = vertical == "middle" && horizontal == "center" ? "center" : "\(vertical) \(horizontal)"
        let pct = { (v: CGFloat) in Int((v * 100).rounded()) }
        if isPoint(rect) {
            return "spot at \(place) (x \(pct(rect.minX))%, y \(pct(rect.minY))%)"
        }
        return "area at \(place) (x \(pct(rect.minX))–\(pct(rect.maxX))%, y \(pct(rect.minY))–\(pct(rect.maxY))%)"
    }

    /// The message: a heading naming the file and what's attached, then each mark, numbered
    /// per image or page as drawn on the marked-up copies, then the overall note. `drawn`:
    /// a marked-up copy goes with it even without numbered marks (pen strokes only).
    static func message(file: String, marks: [Mark], overall: String, attachedPages: [Int] = [], originalAttached: Bool = true,
                        drawn: Bool = false) -> String {
        var lines: [String] = []
        if !marks.isEmpty || drawn {
            if marks.contains(where: { $0.page != nil }) || !attachedPages.isEmpty {
                let pages = attachedPages.map(String.init).joined(separator: ", ")
                lines.append("Feedback on \(file). Marked-up copies of page\(attachedPages.count == 1 ? "" : "s") \(pages) are attached\(marks.isEmpty ? "." : ", numbered as below.")")
                for page in Set(marks.compactMap(\.page)).sorted() {
                    lines.append("\nPage \(page):")
                    for (index, mark) in marks.filter({ $0.page == page }).enumerated() {
                        lines.append("\(index + 1). \(describe(mark.rect)): \(note(mark.comment))")
                    }
                }
            } else {
                lines.append(originalAttached
                    ? "Feedback on \(file). The first attached image is annotated; the second is the original."
                    : "Feedback on \(file). The attached image is annotated.")
                for (index, mark) in marks.enumerated() {
                    lines.append("\(index + 1). \(describe(mark.rect)): \(note(mark.comment))")
                }
            }
        }
        let summary = overall.trimmingCharacters(in: .whitespacesAndNewlines)
        if !summary.isEmpty { lines.append(lines.isEmpty ? summary : "\nOverall: \(summary)") }
        return lines.joined(separator: "\n")
    }

    private static func note(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "(no note)" : trimmed
    }
}
