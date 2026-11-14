import Foundation

/// A finished sidequest's request to be archived, and Keep Open's answer to it. Kept on this
/// device: which sidequests were told to stay open.
enum SidequestArchiveAsk {
    static let keptKey = "sidequestsKeptOpen"

    static func kept(_ id: UUID) -> Bool {
        (AppPreferences.defaults.stringArray(forKey: keptKey) ?? []).contains(id.uuidString)
    }

    static func keep(_ id: UUID) {
        var kept = AppPreferences.defaults.stringArray(forKey: keptKey) ?? []
        guard !kept.contains(id.uuidString) else { return }
        kept.append(id.uuidString)
        // Only the newest matter: old sidequests are long archived.
        AppPreferences.defaults.set(Array(kept.suffix(200)), forKey: keptKey)
    }

    /// Whether to ask now: its answer went back, it's idle, not archived, and not kept open.
    static func asks(isSidequest: Bool, returned: Bool, running: Bool, archived: Bool, id: UUID) -> Bool {
        isSidequest && returned && !running && !archived && !kept(id)
    }
}

