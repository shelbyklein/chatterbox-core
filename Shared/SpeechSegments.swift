import Foundation

/// How a reply that is still being written becomes a queue of things to say. Foundation only, so
/// the logic runs in a fixture on a Mac (tests/golem-ios-voice/segments).
///
/// Cleaning and segmenting interact like this. Markdown cleaning (`clean`) is not stable for a
/// half-written text: `**bol`, `[a link](http`, a table row without its closing bar or an open
/// code fence all clean differently once the rest arrives. So `SpeechSegmenter` never cleans the
/// raw text as it stands. It first takes the *stable prefix* (`stablePrefix`): every complete line
/// outside an open code fence, plus the part of the unfinished last line that ends at a sentence
/// end followed by a space with its `* _ \` [ ] ( )` marks balanced. Only that prefix is cleaned,
/// and the cleaned text is segmented. The segmenter remembers the cleaned text it already cut
/// (`consumedText`) and each time cuts only what follows it, so text arriving in pieces is
/// never spoken twice and never skipped. If an edit ever changes already-cut text, it continues
/// from the longest matching prefix instead of guessing. A sentence is cut only once its end is
/// followed by whitespace, so the tail waits for more text, unless the reply is `final`.
enum SpeechSegments {
    /// A sentence longer than this is cut at its last comma or semicolon (else last space).
    static let sentenceLimit = 600
    /// Short sentences are merged into one request up to about this many characters.
    static let mergeLimit = 240
    /// Long replies are read up to here, then "the rest is in the chat".
    static let spokenLimit = 5000
    static let capTail = "The rest is in the chat."

    private static let closers: Set<Character> = ["\"", "'", ")", "]", "\u{201D}", "\u{2019}", "\u{00BB}", "*", "_", "`"]
    private static let abbreviations: Set<String> = ["mr", "mrs", "ms", "dr", "prof", "vs", "e.g", "i.e"]

    // MARK: - Cutting

    /// Complete sentences (and over-long runs) in `rest`, trimmed, plus how many characters of
    /// `rest` they use. The unfinished tail stays unused until `final`.
    static func cut(_ rest: String, final ended: Bool) -> (segments: [String], consumed: Int) {
        let chars = Array(rest)
        var ranges: [Range<Int>] = [], start = 0, i = 0
        func isBlank(_ c: Character) -> Bool { c == " " || c == "\t" }
        while i < chars.count {
            let c = chars[i]
            if c.isNewline {
                var j = i + 1
                while j < chars.count, isBlank(chars[j]) { j += 1 }
                if j < chars.count, chars[j].isNewline {
                    ranges += split(start ..< i, in: chars)
                    i = j + 1; start = i; continue
                }
                i += 1; continue
            }
            if ".!?\u{2026}".contains(c), !(c == "." && isAbbreviation(chars, before: i)) {
                var end = i + 1
                while end < chars.count, closers.contains(chars[end]) { end += 1 }
                if end < chars.count, chars[end].isWhitespace {
                    ranges += split(start ..< end, in: chars)
                    i = end + 1; start = i; continue
                }
                i = max(end, i + 1); continue
            }
            i += 1
        }
        var used = start
        if ended {
            if start < chars.count { ranges += split(start ..< chars.count, in: chars) }
            used = chars.count
        } else if chars.count - start > sentenceLimit {
            // A very long unfinished sentence: speak up to its last comma so audio isn't held back.
            let parts = split(start ..< chars.count, in: chars)
            if parts.count > 1 { ranges += parts.dropLast(); used = parts[parts.count - 1].lowerBound }
        }
        let segments = ranges.map { String(chars[$0]).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return (segments, used)
    }

    /// `range`, cut into runs of at most `sentenceLimit` characters at a comma/semicolon, else a space.
    private static func split(_ range: Range<Int>, in chars: [Character]) -> [Range<Int>] {
        var out: [Range<Int>] = [], from = range.lowerBound
        while range.upperBound - from > sentenceLimit {
            let window = chars[from ..< from + sentenceLimit]
            let at = window.lastIndex { $0 == "," || $0 == ";" }.map { $0 + 1 } ?? window.lastIndex(of: " ").map { $0 + 1 }
            guard let at, at > from else { break }
            out.append(from ..< at); from = at
        }
        out.append(from ..< range.upperBound)
        return out
    }

    /// "3." at the start of a list line, "Dr.", "e.g." and the like aren't sentence ends.
    private static func isAbbreviation(_ chars: [Character], before i: Int) -> Bool {
        var j = i
        while j > 0, !chars[j - 1].isWhitespace { j -= 1 }
        let word = String(chars[j ..< i])
        if word.isEmpty { return false }
        if word.count <= 3, word.allSatisfy({ $0.isASCII && $0.isNumber }) {
            var k = j
            while k > 0, chars[k - 1] == " " || chars[k - 1] == "\t" { k -= 1 }
            if k == 0 || chars[k - 1].isNewline { return true }
        }
        return abbreviations.contains(word.lowercased())
    }

    /// Short sentences share a request, up to `limit` characters.
    static func merge(_ sentences: [String], limit: Int = mergeLimit) -> [String] {
        var out: [String] = [], group = ""
        for s in sentences {
            if !group.isEmpty, group.count + 1 + s.count > limit { out.append(group); group = "" }
            group += (group.isEmpty ? "" : " ") + s
        }
        if !group.isEmpty { out.append(group) }
        return out
    }

    // MARK: - Cleaning

    private static let rules: [(NSRegularExpression, String)] = {
        let table: [(String, String, NSRegularExpression.Options)] = [
            ("```[\\s\\S]*?```", " (code in the chat) ", []),
            ("`([^`]+)`", "$1", []),
            ("!\\[[^\\]]*\\]\\([^)]*\\)", "", []),                                  // images
            ("\\[([^\\]]+)\\]\\([^)]*\\)", "$1", []),                               // links → their text
            ("https?://\\S+?(?=[.,;:!?)]*(?:\\s|$))", "a link", []),
            ("(?<![\\w.])(?:~|/[\\w.-]+)(?:/[\\w .-]+)+/([\\w.-]+)", "$1", []),      // paths → file name
            ("^[ \\t]*\\|?[ \\t]*:?-{3,}.*$", "", .anchorsMatchLines),               // table rules
            ("^[ \\t]*\\|[ \\t]*(.*?)[ \\t]*\\|[ \\t]*$", "$1.", .anchorsMatchLines),  // table rows → "a, b."
            ("[ \\t]*\\|[ \\t]*", ", ", []),
            ("^#{1,6}[ \\t]*", "", .anchorsMatchLines),
            ("^[ \\t]*[-*+][ \\t]+", "", .anchorsMatchLines),
            ("(\\*\\*|__|\\*|_)(\\S[^*_]*?\\S|\\S)\\1", "$2", []),
            ("[ \\t]+", " ", []),
            ("\\n{3,}", "\n\n", []),
        ]
        return table.compactMap { pattern, template, options in
            (try? NSRegularExpression(pattern: pattern, options: options)).map { ($0, template) }
        }
    }()

    /// A reply as it should sound: no markdown marks, code blocks or full URLs and paths. Neither
    /// trimmed nor capped (leading and trailing whitespace is kept so segmenting can see it).
    static func clean(_ text: String) -> String {
        var s = text
        for (regex, template) in rules {
            s = regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
        }
        return s
    }

    /// `clean`, trimmed and capped at `limit` characters with "The rest is in the chat."
    static func spoken(_ text: String, limit: Int = spokenLimit) -> String {
        var s = clean(text).trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count > limit { s = capped(s, room: limit) }
        return s
    }

    /// `s` shortened to about `room` characters at its last sentence end, with the cap tail.
    static func capped(_ s: String, room: Int) -> String {
        let cut = s.prefix(max(room, 0))
        let end = cut.lastIndex(where: { ".!?".contains($0) }) ?? cut.endIndex
        let head = s[..<end]
        return head.isEmpty ? capTail : String(head) + ". " + capTail
    }

    // MARK: - The part of a growing text that is safe to clean

    /// What of `raw` can be cleaned now without a later character changing how it cleans.
    static func stablePrefix(_ raw: String, final: Bool) -> Substring {
        if final { return raw[...] }
        guard let lastNewline = raw.lastIndex(where: { $0.isNewline }) else {
            return stableLine(raw[...], from: raw.startIndex)
        }
        let lineEnd = raw.index(after: lastNewline)
        let complete = raw[..<lineEnd]
        if complete.components(separatedBy: "```").count % 2 == 0 {   // an open code fence
            guard let fence = complete.range(of: "```", options: .backwards) else { return raw[..<raw.startIndex] }
            let before = complete[..<fence.lowerBound]
            let from = before.lastIndex(where: { $0.isNewline }).map { raw.index(after: $0) } ?? raw.startIndex
            return raw[..<from]
        }
        return stableLine(raw[lineEnd...], from: lineEnd)
    }

    /// The unfinished last line: kept up to its last sentence end plus space with marks balanced.
    private static func stableLine(_ line: Substring, from lineStart: String.Index) -> Substring {
        let base = line.base
        let nothing = base[..<lineStart]
        let trimmed = line.drop { $0 == " " || $0 == "\t" }
        if trimmed.hasPrefix("|") || line.contains("```") { return nothing }
        // Candidate ends: the position after a space that follows a sentence end (and its closers).
        var candidates: [String.Index] = []
        var i = line.startIndex
        while i < line.endIndex {
            if ".!?\u{2026}".contains(line[i]) {
                var j = line.index(after: i)
                while j < line.endIndex, closers.contains(line[j]) { j = line.index(after: j) }
                if j < line.endIndex, line[j] == " " || line[j] == "\t" { candidates.append(line.index(after: j)) }
                i = j; continue
            }
            i = line.index(after: i)
        }
        for end in candidates.reversed() where balanced(line[..<end]) { return base[..<end] }
        return nothing
    }

    /// Emphasis, code, bracket and parenthesis marks all closed (a leading list marker doesn't count).
    private static func balanced(_ s: Substring) -> Bool {
        var text = s.drop { $0 == " " || $0 == "\t" }
        if let first = text.first, "-*+".contains(first), text.dropFirst().first == " " { text = text.dropFirst() }
        func count(_ c: Character) -> Int { text.reduce(0) { $0 + ($1 == c ? 1 : 0) } }
        return count("`") % 2 == 0 && count("*") % 2 == 0 && count("_") % 2 == 0
            && count("[") == count("]") && count("(") == count(")")
    }
}

/// Turns a reply that grows over time into the segments to say, each exactly once, in order.
/// Feed it the reply's full text so far; it returns only the segments that became ready.
struct SpeechSegmenter {
    let limit: Int
    /// The reply is longer than `limit` and the rest will not be spoken.
    private(set) var capped = false
    /// `final` was fed: no more segments will come.
    private(set) var ended = false
    /// Characters of cleaned text queued so far (against `limit`).
    private(set) var queuedCount = 0

    private var consumedText = ""
    private var lastStable: Substring?

    init(limit: Int = SpeechSegments.spokenLimit) { self.limit = limit }

    mutating func feed(_ raw: String, final: Bool) -> [String] {
        guard !ended else { return [] }
        if final { ended = true }
        guard !capped else { return [] }
        let text = raw.contains("\r\n") ? raw.replacingOccurrences(of: "\r\n", with: "\n") : raw
        let stable = SpeechSegments.stablePrefix(text, final: final)
        if !final, let last = lastStable, last == stable { return [] }
        lastStable = stable
        let cleaned = SpeechSegments.clean(String(stable))
        if !cleaned.hasPrefix(consumedText) {
            // Already-cut text changed: continue from what still matches rather than guess.
            var common = consumedText.startIndex, other = cleaned.startIndex
            while common < consumedText.endIndex, other < cleaned.endIndex, consumedText[common] == cleaned[other] {
                common = consumedText.index(after: common); other = cleaned.index(after: other)
            }
            consumedText = String(consumedText[..<common])
        }
        let rest = String(cleaned.dropFirst(consumedText.count))
        let (pieces, used) = SpeechSegments.cut(rest, final: final)
        consumedText += String(rest.prefix(used))
        var out: [String] = []
        for segment in SpeechSegments.merge(pieces) {
            let room = limit - queuedCount
            if segment.count > room {
                let tail = SpeechSegments.capped(segment, room: room)
                out.append(tail); queuedCount += tail.count; capped = true
                break
            }
            queuedCount += segment.count
            out.append(segment)
        }
        return out
    }
}
