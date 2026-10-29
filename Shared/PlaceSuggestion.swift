import Foundation

/// Which Studio a loose session's work belongs in, from its first message and each Studio's
/// name and instructions. Cautious on purpose: nothing unless one Studio clearly fits, since
/// a wrong suggestion is worse than none.
enum PlaceSuggestion {
    struct Place: Equatable {
        var id: UUID
        var name: String
        var instructions: String
    }

    static func best(for text: String, among places: [Place]) -> Place? {
        let said = words(text)
        guard !said.isEmpty else { return nil }
        let scored = places.map { place -> (Place, Int) in
            let name = words(place.name)
            // The Studio named outright (every word of it) is the strongest sign.
            var score = !name.isEmpty && name.isSubset(of: said) ? 10 : 0
            score += words(place.instructions).subtracting(name).intersection(said).count
            return (place, score)
        }.sorted { $0.1 > $1.1 }
        guard let first = scored.first, first.1 >= 3 else { return nil }
        if scored.count > 1, scored[1].1 >= first.1 - 1 { return nil }
        return first.0
    }

    /// Dismissed per session, on this device.
    static let dismissedKey = "placeSuggestionDismissed"
    static func isDismissed(_ id: UUID) -> Bool {
        (UserDefaults.standard.stringArray(forKey: dismissedKey) ?? []).contains(id.uuidString)
    }
    static func dismiss(_ id: UUID) {
        let list = (UserDefaults.standard.stringArray(forKey: dismissedKey) ?? []).suffix(500) + [id.uuidString]
        UserDefaults.standard.set(Array(list), forKey: dismissedKey)
    }

    private static let ignored: Set<String> = [
        "the", "and", "for", "with", "this", "that", "from", "into", "your", "you", "our", "are", "was", "can", "will",
        "please", "make", "need", "want", "about", "some", "new", "all", "any", "but", "not", "have", "has", "its",
        "work", "working", "things", "stuff", "help", "also", "just", "like", "get", "use", "one", "two", "out", "more",
        "chat", "chats", "session", "sessions", "studio", "studios", "project", "projects", "here", "there", "them",
    ]

    static func words(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
            .filter { $0.count >= 3 && !ignored.contains($0) }
            .map { $0.count > 4 && $0.hasSuffix("s") ? String($0.dropLast()) : $0 })
    }
}
