import Foundation

/// One utterance's transcript when a single long-running recognizer serves a whole conversation
/// (SpeechAnalyzer). Results carry the audio-time range they cover; a newer result replaces any
/// not-yet-final text it overlaps, final text stays. Everything that ends at or before the
/// utterance's start (`boundary`) belongs to an earlier utterance and is ignored, so a late final
/// result for the previous turn can't leak into the next one. Pure value, no clocks.
struct UtteranceTranscript {
    private struct Segment {
        var start: Double
        var end: Double
        var text: String
        var isFinal: Bool
    }

    /// Where this utterance starts on the analyzer's audio timeline, in seconds.
    private(set) var boundary: Double
    private var segments: [Segment] = []
    /// The utterance so far.
    private(set) var text = ""

    init(boundary: Double = 0) { self.boundary = boundary }

    /// Starts a new, empty utterance at `boundary`.
    mutating func reset(boundary: Double) {
        self.boundary = boundary
        segments = []
        text = ""
    }

    /// Takes one recognizer result. Returns true if the utterance's text changed.
    /// A range that isn't finite (the recognizer gave no timing) is treated as current.
    @discardableResult
    mutating func apply(_ result: String, isFinal: Bool, start: Double, end: Double) -> Bool {
        let timed = start.isFinite && end.isFinite
        if timed && end <= boundary { return false }
        let start = timed ? start : boundary
        let end = timed ? max(end, start) : start
        // A newer result replaces the unfinished text it overlaps or follows.
        segments.removeAll { !$0.isFinal && ($0.start >= start || ($0.start < end && $0.end > start)) }
        segments.append(Segment(start: start, end: end, text: result, isFinal: isFinal))
        segments.sort { $0.start < $1.start }
        let joined = Self.join(segments.map(\.text))
        guard joined != text else { return false }
        text = joined
        return true
    }

    /// Joins pieces with a space only where neither side already has whitespace.
    static func join(_ pieces: [String]) -> String {
        var out = ""
        for piece in pieces where !piece.isEmpty {
            if let last = out.last, let first = piece.first, !last.isWhitespace, !first.isWhitespace { out += " " }
            out += piece
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
