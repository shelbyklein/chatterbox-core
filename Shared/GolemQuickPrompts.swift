import Foundation

/// A prepared message for Golem: one tap sends it.
struct GolemQuickPrompt: Codable, Identifiable, Equatable {
    var id = UUID()
    var label: String
    var text: String
}

/// Golem's quick prompts, kept on this device. In the text, `{since}` becomes the time an hour
/// ago and `{now}` the time now, written the way Golem's activity file writes times.
enum GolemQuickPrompts {
    static let key = "golemQuickPrompts"
    static let defaults: [GolemQuickPrompt] = [
        GolemQuickPrompt(id: UUID(uuidString: "6A0F5C1E-3C1B-4C55-9D51-0F7D9B6C0001")!, label: "Catch me up",
                         text: "Catch me up on the last hour, since {since}: what changed in my chats (finished, waiting on me, still working) and any important email that arrived. Keep it short and lead with anything that needs me."),
        GolemQuickPrompt(id: UUID(uuidString: "6A0F5C1E-3C1B-4C55-9D51-0F7D9B6C0002")!, label: "What needs me?",
                         text: "Is anything waiting on me right now? List only what needs a decision or reply from me, most urgent first."),
        GolemQuickPrompt(id: UUID(uuidString: "6A0F5C1E-3C1B-4C55-9D51-0F7D9B6C0003")!, label: "My notes",
                         text: "What are my notes?"),
    ]

    static func decode(_ data: Data) -> [GolemQuickPrompt] {
        data.isEmpty ? defaults : ((try? JSONDecoder().decode([GolemQuickPrompt].self, from: data)) ?? defaults)
    }
    static func encode(_ prompts: [GolemQuickPrompt]) -> Data {
        (try? JSONEncoder().encode(prompts)) ?? Data()
    }

    static func expand(_ text: String, now: Date = Date(), timeZone: TimeZone = .current) -> String {
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.timeZone = timeZone
        stamp.dateFormat = "MMM d, h:mm a"
        return text.replacingOccurrences(of: "{since}", with: stamp.string(from: now.addingTimeInterval(-3600)))
            .replacingOccurrences(of: "{now}", with: stamp.string(from: now))
    }
}
