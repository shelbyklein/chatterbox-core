import Foundation
import SwiftUI

/// What changed in Chatterbox, newest first, in plain words: Settings → What's New on the Mac
/// and the phone, and the note shown once after an update. Every shipped change adds a line
/// to today's day here (AGENTS.md, "Changelog"); a day already listed gets the new line on top.
enum Changelog {
    struct Day: Identifiable, Hashable {
        /// "2026-11-13": also what the "seen" marker remembers.
        let id: String
        let changes: [String]

        var date: Date? {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
            return f.date(from: id)
        }
        var title: String {
            guard let date else { return id }
            return date.formatted(.dateTime.weekday(.wide).month(.wide).day())
        }
    }

    static let days: [Day] = [
        Day(id: "2026-11-13", changes: [
            "New Chat from inside a Studio on the phone starts the session in that Studio.",
            "A finished sidequest no longer archives itself: its answer still goes back, and it asks \"Archive this sidequest?\" with Archive and Keep Open.",
            "Archived sessions on the phone: ⋯ → Archived lists them, newest first, with search; tap one to open it, or swipe to unarchive.",
            "An image still loading on the phone after a few seconds says so; tap it to start it over.",
            "Mark Up on the phone has a Comment mode: tap a spot to pin a numbered note. The picture goes with its pins, and the notes go in your message.",
            "What's New: this list, in Settings on the Mac and the phone, with a note after each update.",
            "Mark Up on the phone: pinch to zoom and pan with two fingers; a Pencil Only switch lets a finger move the page instead of drawing.",
            "Open Duo, portrait: the session list is a shelf over the chat (the button at the chat's top left, or swipe in from the left edge), so the chat gets the whole width.",
            "Open Duo: the chat's title and model show again, centered on its bar.",
            "Phone lists: the flame sits beside \"turns today\", sessions sit closer together, and search spans the column.",
            "Sessions can hand each other information: agents use `tell` to send another session a message or read its latest replies.",
            "Phone images load without backing out of the chat: a dead Mac address is skipped in seconds, loads restart on a working one, and old addresses are dropped.",
            "New Chat sits beside each list's title on the phone.",
            "The floating ⋯ pill is gone from the open Duo; a chat's actions are under About → Actions.",
        ]),
        Day(id: "2026-11-12", changes: [
            "Projects show an app symbol on the phone instead of a folder.",
            "The phone no longer freezes when scrolling up just after a chat opens.",
            "Secrets: saving a key asks for the background service's access right away, and agents are told when a saved key isn't readable yet.",
        ]),
        Day(id: "2026-11-11", changes: [
            "Each Studio has its own Tools: right-click a Studio → Tools…, or pick it in Settings → Tools.",
            "Make Project… on the Mac: right-click a loose chat to make it a project in a folder you choose.",
            "On hold on Review cards (Mac and phone), for when you're waiting on a response.",
        ]),
        Day(id: "2026-11-10", changes: [
            "Project issue boards for PlayCase Arcade games, on the Mac and the phone; agents file issues with `issue add`.",
            "The Mac's Session activity popover is gone from the toolbar.",
            "Images on the Mac zoom in when you view them.",
            "Fable 5.2 is in the model list.",
        ]),
        Day(id: "2026-11-09", changes: [
            "The phone's ⋯ menu is slimmer; Notifications, Appearance and Unpair are together in Settings.",
            "The Mac counts as overloaded only when CPU or memory stays over 95%.",
            "Desk tasks carry a Yes/No confidence, and Yes tasks start by themselves.",
        ]),
    ]

    static var latest: String { days.first?.id ?? "" }

    /// Days newer than `seen` (all of them when nothing was seen yet, up to `limit`).
    static func since(_ seen: String?, limit: Int = 3) -> [Day] {
        Array(days.filter { seen == nil || seen!.isEmpty || $0.id > seen! }.prefix(limit))
    }

    /// The preference that remembers the newest day already shown.
    static let seenKey = "changelogSeen"
}

/// The list, day by day: Settings → What's New.
struct ChangelogList: View {
    var days: [Changelog.Day] = Changelog.days
    var body: some View {
        List {
            ForEach(days) { day in
                Section(day.title) {
                    ForEach(day.changes, id: \.self) { change in
                        Text(LocalizedStringKey(change)).font(.callout).padding(.vertical, 2)
                    }
                }
            }
        }
        .accessibilityIdentifier("changelog")
    }
}

/// Shown once after an update brings new lines: what changed since the last one seen, with
/// the way to the full list. Closing it marks them seen.
struct WhatsNewNote: View {
    let days: [Changelog.Day]
    var seeAll: (() -> Void)? = nil
    let close: () -> Void
    var body: some View {
        NavigationStack {
            ChangelogList(days: days)
                .navigationTitle("What's New")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done", action: close) }
                    if let seeAll {
                        ToolbarItem(placement: .cancellationAction) { Button("See All", action: seeAll) }
                    }
                }
        }
        #if os(macOS)
        .frame(width: 520, height: 460)
        #endif
    }
}

extension View {
    /// The What's New note, once per update with new lines (the newest day on the first launch
    /// that has the list).
    func whatsNewNote(seeAll: (() -> Void)? = nil) -> some View { modifier(WhatsNewOnUpdate(seeAll: seeAll)) }
}

private struct WhatsNewOnUpdate: ViewModifier {
    var seeAll: (() -> Void)?
    @AppStorage(Changelog.seenKey) private var seen = ""
    @State private var showing: [Changelog.Day]?

    func body(content: Content) -> some View {
        content
            .task {
                // Not in UI tests: a sheet over the app would hide what they tap.
                if ProcessInfo.processInfo.environment["CHATTERBOX_TEST_HOST"] != nil
                    || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }
                let new = seen.isEmpty ? Array(Changelog.days.prefix(1)) : Changelog.since(seen)
                if !new.isEmpty { showing = new }
            }
            .sheet(isPresented: Binding(get: { showing != nil }, set: { if !$0 { done() } })) {
                WhatsNewNote(days: showing ?? [], seeAll: seeAll.map { action in { done(); action() } }, close: done)
            }
    }

    private func done() { seen = Changelog.latest; showing = nil }
}
