import Foundation

/// What the chat's image boxes did lately (came into view, a tap, a load starting, the request
/// and how it ended), kept in memory on this phone. Feedback attaches the newest lines, so a
/// picture that won't load can be diagnosed from the device itself.
@MainActor
enum MobileImageTrace {
    private static var lines: [String] = []
    private static let limit = 120
    private static let clock: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()

    static func note(_ file: String, _ event: String) {
        let line = "\(clock.string(from: Date())) \(String(file.prefix(40))): \(event)"
        if lines.last?.hasSuffix(": " + event) == true, lines.last?.contains(" \(String(file.prefix(40))): ") == true { return }
        lines.append(line)
        if lines.count > limit { lines.removeFirst(lines.count - limit) }
    }

    /// The newest lines, or nil when nothing happened.
    static func recent(_ count: Int = 60) -> String? {
        lines.isEmpty ? nil : lines.suffix(count).joined(separator: "\n")
    }
}
