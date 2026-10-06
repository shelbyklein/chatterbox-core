import Foundation

/// When a spoken utterance is over, and when someone has started talking over Golem. Pure
/// state with the time passed in, so it can be checked without sleeping. The listener feeds it
/// the transcription so far and asks it, on a short timer, whether the utterance is due.
struct UtterancePause {
    enum Outcome: Equatable {
        /// You spoke and then paused: send what was heard.
        case send(String)
        /// Nothing was heard before the give-up time.
        case silent
    }

    /// The range the pause setting allows, in seconds.
    static let pauseRange: ClosedRange<TimeInterval> = 0.5...3.0
    /// After a finished sentence the wait is at most this long.
    static let sentenceEndPause: TimeInterval = 0.7
    /// A request that has heard nothing is replaced after this long (recognition requests are limited to about a minute).
    static let rotateAfter: TimeInterval = 50

    let pause: TimeInterval
    let giveUp: TimeInterval
    let minimumWords: Int
    /// When this utterance started waiting; the give-up time counts from here.
    let opened: Date

    private(set) var text = ""
    private(set) var lastHeard: Date
    private(set) var bargedIn = false

    init(pause: TimeInterval, giveUp: TimeInterval, minimumWords: Int, opened: Date = Date()) {
        self.pause = pause
        self.giveUp = giveUp
        self.minimumWords = max(1, minimumWords)
        self.opened = opened
        self.lastHeard = opened
    }

    /// The transcription so far. Returns true exactly once per utterance: when it first has
    /// `minimumWords` words of two letters or more, which is when you've started talking over.
    mutating func heard(_ text: String, at now: Date) -> Bool {
        if text != self.text {
            self.text = text
            lastHeard = now
        }
        guard !bargedIn, Self.qualifyingWords(in: text) >= minimumWords else { return false }
        bargedIn = true
        return true
    }

    /// Whether the utterance is over: `.send` once you've spoken and been quiet for the effective
    /// pause, `.silent` once `giveUp` has passed with nothing heard, otherwise nil.
    func due(at now: Date) -> Outcome? {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !words.isEmpty {
            return now.timeIntervalSince(lastHeard) >= Self.effectivePause(pause, after: words) ? .send(words) : nil
        }
        return now.timeIntervalSince(opened) >= giveUp ? .silent : nil
    }

    /// An empty request that has been open for more than 50 seconds should be replaced by a new one.
    func shouldRotate(openedAt: Date, now: Date) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && now.timeIntervalSince(openedAt) > Self.rotateAfter
    }

    /// The pause, kept within its range; shortened to 0.7 s after a sentence that ended with . ? or !.
    static func effectivePause(_ pause: TimeInterval, after text: String) -> TimeInterval {
        let base = min(max(pause, pauseRange.lowerBound), pauseRange.upperBound)
        let closers: Set<Character> = ["\"", "'", "”", "’", ")", "]"]
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last(where: { !closers.contains($0) }) else { return base }
        return [".", "?", "!"].contains(last) ? min(base, sentenceEndPause) : base
    }

    /// Words with at least two letters: "a" and "I" don't count, so a stray sound isn't talking over.
    static func qualifyingWords(in text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace })
            .filter { $0.filter(\.isLetter).count >= 2 }
            .count
    }
}
