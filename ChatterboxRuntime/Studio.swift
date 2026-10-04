import Foundation

/// A place for messy work that isn't a project: several chats sharing one folder, like a run
/// of creative asks across different apps. Chatterbox makes the folder, and it needn't be a
/// git repo. Each chat in it works in that folder.
struct Studio: Codable, Identifiable, Equatable, Hashable {
    var id = UUID()
    var name: String
    var folder: String
    var createdAt = Date()
    var archivedAt: Date?
    /// Collapsed in the sidebar. Optional so older saves still load.
    var collapsed: Bool?
    /// What the Studio is for and where to look (sites, brand guides, tools), given to every
    /// chat in it.
    var instructions: String?

    var trimmedInstructions: String { instructions?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }

    /// The Studio's design guide: a file in its folder that its chats read before visual work
    /// and edit only when the user asks.
    var designFile: String { (folder as NSString).appendingPathComponent("design.md") }

    /// What a chat was last told about this Studio: its instructions, plus which version of the
    /// Studio note (so chats from before design.md hear about it once).
    var noteKey: String { trimmedInstructions + "\u{0}design.md" }

    /// Makes design.md with a short starting outline if it isn't there. Never touches one
    /// that exists.
    func ensureDesignFile() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: folder), !fm.fileExists(atPath: designFile) else { return }
        let template = """
        # \(name) design

        The design guide for this Studio. Every chat in it reads this before visual work.
        Ask a chat to fill it in or change it; chats edit it only when you ask.

        ## Brand
        ## Color
        ## Typography
        ## Logos and imagery
        ## Layout
        ## Do and don't

        """
        fm.createFile(atPath: designFile, contents: Data(template.utf8))
    }
}
