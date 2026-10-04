#if GOLEM_APP
import Foundation
import Observation

/// Golem's journal: what he's done (check-ins, briefings, emails, suggested answers) and the
/// decisions made along the way, with times, for the panel beside his chat. Kept in his
/// folder as journal.json, newest last, trimmed to the latest few hundred.
@MainActor
@Observable
final class GolemJournal {
    static let shared = GolemJournal()

    struct Entry: Codable, Identifiable, Equatable {
        enum Kind: String, Codable { case activity, decision }
        var id = UUID()
        var date = Date()
        var kind: Kind
        var title: String
        var detail: String?
        /// The chat it concerns, if any, by id and by the name it had then.
        var chat: UUID?
        var chatName: String?
    }

    private(set) var entries: [Entry] = []
    private static let limit = 400

    static var file: URL { URL(fileURLWithPath: AppModel.dotFolder).appendingPathComponent("journal.json") }

    private init() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        entries = (try? Data(contentsOf: Self.file)).flatMap { try? decoder.decode([Entry].self, from: $0) } ?? []
    }
    func refresh() {
        let decoder=JSONDecoder();decoder.dateDecodingStrategy = .iso8601
        if let data=try? Data(contentsOf:Self.file),let fresh=try? decoder.decode([Entry].self,from:data),fresh != entries{entries=fresh}
    }

    var activity: [Entry] { entries.filter { $0.kind == .activity }.reversed() }
    var decisions: [Entry] { entries.filter { $0.kind == .decision }.reversed() }

    func add(_ kind: Entry.Kind, title: String, detail: String? = nil, chat: ChatSession? = nil) {
        guard !RuntimeClient.usesDaemon else{return}
        let name = chat.map { $0.record.projectFolder != nil ? $0.projectName : $0.title }
        entries.append(Entry(kind: kind, title: title, detail: detail?.isEmpty == true ? nil : detail, chat: chat?.id, chatName: name))
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
        save()
    }

    // MARK: - Suggested answers

    /// Golem suggested answers for a question card in another chat.
    func suggested(_ item: DisplayItem, in chat: ChatSession) {
        add(.activity, title: "Suggested an answer", detail: Self.describe(item, item.suggested) + Self.because(item.suggestedReason), chat: chat)
    }

    /// You answered a card Golem had suggested answers for: whether you took his.
    func answered(_ item: DisplayItem, suggested: [String: [String]], with answers: [String: [String]]?, in chat: ChatSession) {
        let title: String
        if answers == nil {
            title = "Skipped a question \(item.suggestedBy ?? "Golem") had an answer for"
        } else if answers == suggested {
            title = "Sent \(item.suggestedBy ?? "Golem")\u{2019}s suggested answer"
        } else {
            title = "Answered differently from \(item.suggestedBy ?? "Golem")\u{2019}s suggestion"
        }
        add(.decision, title: title, detail: answers.map { Self.describe(item, $0) }, chat: chat)
    }

    private static func describe(_ item: DisplayItem, _ answers: [String: [String]]?) -> String {
        (item.questions ?? []).compactMap { question in
            answers?[question.id].map { "\(question.question) \u{2192} \($0.joined(separator: ", "))" }
        }.joined(separator: "\n")
    }

    private static func because(_ reason: String?) -> String {
        guard let reason, !reason.isEmpty else { return "" }
        return "\nWhy: " + reason
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        guard let data = try? encoder.encode(entries) else { return }
        try? FileManager.default.createDirectory(at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.file, options: .atomic)
    }
}

#endif
