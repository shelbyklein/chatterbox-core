import Foundation

/// Where a piece of work belongs, from what it says and each place's name and what belongs
/// there: a Studio's instructions, or a project's brief (the Desk proposes both; a loose
/// session's card suggests Studios). Cautious on purpose: nothing unless one place clearly
/// fits, since a wrong suggestion is worse than none.
enum PlaceSuggestion {
    struct Place: Equatable {
        enum Kind: String { case studio, project }
        var id: UUID
        var name: String
        /// What belongs there: a Studio's instructions, or a project's brief.
        var instructions: String
        var kind: Kind = .studio
    }

    /// The one place the text names: its whole name (strongest), a distinctive word of its name
    /// ("archery", "SDHQ"), or a website its instructions or brief name ("usarchery" from
    /// usarchery.org). Ordinary words its instructions happen to share no longer count: one
    /// Studio with long instructions matched most chats on "create", "image", "version".
    static func best(for text: String, among places: [Place]) -> Place? {
        let said = words(text)
        guard !said.isEmpty else { return nil }
        // More words in a name must not make it win over a second explicitly
        // named place. Generic-only names are not useful identity evidence.
        let eligible = places.filter { !terms(of: $0).isEmpty }
        let named = eligible.filter {
            let name = words($0.name)
            return !name.isEmpty && name.isSubset(of: said)
        }
        if !named.isEmpty { return named.count == 1 ? named[0] : nil }
        let matches = eligible.filter { !terms(of: $0).isDisjoint(with: said) }
        return matches.count == 1 ? matches[0] : nil
    }

    /// A place's own terms: the distinctive words of its name, and the sites its instructions
    /// or brief name (the part before .org/.com, and the words of it).
    static func terms(of place: Place) -> Set<String> {
        var terms = words(place.name).subtracting(genericNameWords)
        let nameParts = place.name.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        if let first = nameParts.first, first.count >= 2, first == first.uppercased(),
           first.contains(where: \.isLetter), nameParts.count > 1 {
            let rest = nameParts.dropFirst().filter { !genericNameWords.contains($0.lowercased()) }
            let abbreviation = first.lowercased() + rest.compactMap(\.first).map(String.init).joined().lowercased()
            if !rest.isEmpty, (3...8).contains(abbreviation.count) { terms.insert(abbreviation) }
        }
        let text = place.instructions.lowercased()
        let pattern = try? NSRegularExpression(pattern: #"(?:https?://)?(?:www\.)?([a-z0-9-]+)\.(?:org|com|net|io|co|app|dev|us)\b"#)
        for match in pattern?.matches(in: text, range: NSRange(text.startIndex..., in: text)) ?? [] {
            guard let range = Range(match.range(at: 1), in: text) else { continue }
            let stem = String(text[range])
            if stem.count >= 4, !genericNameWords.contains(stem) { terms.insert(stem) }
        }
        return terms
    }

    /// Name words too common to point at one place on their own.
    private static let genericNameWords: Set<String> = [
        "usa", "product", "studio", "design", "shop", "store", "home", "personal", "team", "club", "labs", "lab",
        "company", "group", "media", "creative", "agency", "app", "apps", "site", "web", "website", "google", "github",
        "youtube", "instagram", "facebook", "clickup", "dropbox", "apple", "example",
    ]

    /// The place called `name` (any case, and "the" or "Studio"/"project" around it ignored),
    /// when exactly one is.
    static func named(_ name: String, among places: [Place]) -> Place? {
        func plain(_ text: String) -> String {
            var words = text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
            if words.first == "the" { words.removeFirst() }
            if let last = words.last, ["studio", "project"].contains(last), words.count > 1 { words.removeLast() }
            if let first = words.first, ["studio", "project"].contains(first), words.count > 1 { words.removeFirst() }
            return words.joined(separator: " ")
        }
        let wanted = plain(name)
        guard !wanted.isEmpty else { return nil }
        let exact = places.filter { $0.name.trimmingCharacters(in: .whitespaces).localizedCaseInsensitiveCompare(name.trimmingCharacters(in: .whitespaces)) == .orderedSame }
        if exact.count == 1 { return exact[0] }
        let matches = places.filter { plain($0.name) == wanted }
        return matches.count == 1 ? matches[0] : nil
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
