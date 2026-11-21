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
        Day(id: "2026-11-21", changes: [
            "The usage meter shows Gemini's 5-hour and weekly limits in Gemini chats on the Mac and in Usage on the phone, with the same 50/20/5% warnings as Claude and Codex.",
            "Gemini now shows interactive question cards on Mac and phone, and Settings → Tools discovers Gemini's MCP servers and skills and passes Chatterbox-added MCP servers into Gemini chats.",
            "On the phone's Chats, Projects and Studios cards, a session's sidequests, Sidechats and work threads are small icons inside its card (wrapping onto more lines as needed), so every card takes one column; tap an icon for its title and Open.",
            "In the phone's Activity, a session with sidequests takes one column like the other cards, its sidequests as small icons inside it.",
            "Stop always stops a Gemini reply: if Gemini doesn't answer within 10 seconds, Chatterbox ends the reply itself and restarts Gemini, keeping its conversation for your next message.",
            "Picking another agent's model while a reply runs no longer changes the current agent's model; the switch waits for the reply to end.",
        ]),
        Day(id: "2026-11-20", changes: [
            "On the phone's Desk, Check for updates sits beside the \u{201C}What needs doing?\u{201D} box, the update summary line is gone, and the top bar is more compact so more of the board fits on screen.",
            "On the phone's Desk, a card's Start, Link, Done and Remove stay on one line; in the open Duo's narrow columns, Link, Done and Remove become icons.",
            "Gemini is a third agent beside Claude and Codex, through Google's Antigravity CLI and your Google sign-in: pick it in the model picker (Mac and phone), File → New Gemini Chat, or Settings → Models. It edits files with your approval, resumes its sessions, and can take sidequests, work threads and automations.",
            "Open models on the PC are hidden from the model pickers for now; chats already on one keep it.",
            "On the closed phone, a session's sidebar slides in from the right instead of dropping from the top; tap the chat beside it or drag its left edge to close it.",
            "On an iPhone without the Duo's side rail, a session's name and model stay stacked in the middle of the bar, clear of the Back and menu buttons.",
            "On the phone, permissions in Session Settings and New Chat are one row of icons: the chosen one is highlighted, with its name and what it does shown with it.",
            "On the closed phone the model shows in the same colored pill as the open phone, and Session Settings titles Model inside its card like Effort.",
            "On the closed phone, a session's name sits on the left of its bar and the model on the right, and the sidebar button replaces the agent button (tap the model for Session Settings).",
            "An automation whose project chat was closed no longer retries every minute: it skips that run, says why in Automations, and tries again at its next time.",
            "The Desk's Check for updates works again after its routine was renamed: it remembers its ClickUp and Outlook routine whatever it's called.",
            "On the phone, an up arrow at the bottom left jumps to the start of the latest reply.",
            "On the phone, PDFs can show as spreads (two pages side by side, cover alone) from the book button at the top of the viewer.",
            "On the phone, the Mac's pressure warning is a small pill of its readings on its own row above search.",
            "On the open Duo, swipe right from the session sidebar's left edge to put it away.",
            "On the phone, Show on the Desk is a button beside Make Task (filled while on). On the open Duo, the session sidebar's button sits right of the model pill, and upright only one side panel opens at a time.",
            "On the phone, opening a session's sidebar puts the keyboard away.",
            "On the phone, a session's Notes show just your note (or Add a note), plus a link to its Studio's instructions.",
            "On the phone, a session's sidebar starts with Notes, then what it made, then Actions (its Desk task, Work Thread, Sidequest, Fork, and Rename, Restart, Pin, Archive and more), then Tools and Where. Swipe in from the right edge to open it.",
            "On the phone, a sidequest's bubble has Open, Archive and Delete as one row of icons.",
            "On the phone, tapping a picture in a chat opens it ready to comment: tap to add a note, with Draw, Save, Share and Copy in its bottom bar.",
            "Phone Feedback waits in the Chatterbox session's message box for you to send, instead of sending by itself.",
            "On the open Duo, list and cards buttons sit by the search field (on Activity, at the end of its active and new count). The phone's ••• menu has Usage again; Feedback has its own button.",
            "Phone feedback no longer attaches the image log.",
            "On the open Duo, the list's name sits at the left of its header, level with the session's name, and New Chat at the right.",
            "On the open Duo, search is a field at the top of the session list that scrolls away with it, instead of a button that opened off the edge of the screen.",
            "On the open Duo, a session's name sits at the left of its bar and the model is a pill at the right in the agent's color; tap the pill for Session Settings.",
            "On the phone, tapping the model line under a session's name (\u{201C}Opus 5.5 \u{00B7} High\u{201D}) opens Session Settings; the name still opens About. On the open Duo, the rail has a sidebar button that opens and closes the session's sidebar.",
            "On the open Duo, the side rail under the clock has buttons again: Back, ••• and Feedback in a session, ••• and Feedback otherwise. Its ••• has the session's items and the page's (Settings, Archived, layout), so there's no second ••• over the list.",
            "On the phone, marking up a picture or PDF puts each note in a bubble right where you tapped, and the picture keeps the whole screen; Review at the top lists every note and the overall note.",
            "On the phone, tapping a sidequest icon shows its short title and Open, not its whole instructions.",
            "A warning on your Mac and iPhone when Claude or Codex has 50%, 20% and then 5% of a usage limit left, with how fast you're using it and when it would run out.",
            "Usage limits now show your burn rate: how many percent an hour you're using and when it runs out at that pace (Mac: the context ring's popover; iPhone: Usage). Settings → Mobile notifications can turn the warnings off on the phone.",
        ]),
        Day(id: "2026-11-19", changes: [
            "On the phone, marking up a picture or PDF ends with Send, which sends your notes and the marked-up copies right away instead of leaving them in the message box.",
            "On the phone, when notes sit beside the picture (the open Duo, or a phone on its side), a button at the top hides the notes panel so the picture gets the whole width; placing a note brings it back.",
            "On the phone, pictures in a chat load when you come back to it, without scrolling or leaving and coming back again.",
            "On the Mac, double-click a session's name at the top of the chat to rename it; Return saves, Esc cancels.",
            "Settings → Diagnostics: a \u{201C}request timed out\u{201D} now says which session and what it was doing, and how long the background service really took.",
            "Mac sidebar: the Archive and Delete buttons on a temporary session no longer flicker when you move the pointer onto them.",
            "On the phone, a session's sidequests are a row of small icons at the top of the chat and under the session in a Studio, instead of a full row each; tap one for its task and Open.",
            "On the phone, Activity shows a session's sidequests and sidechats as small icons on its card; tap one for its title and Open.",
            "In the sidebar's Activity, a session's sidequests show as small icons beside its name instead of rows of their own; hover one to see its title, click to open it.",
            "On the Mac, a session's sidequests start as small bubbles in its corner; click one to open it.",
            "Mac sidebar: hover over a temporary session (a sidechat or sidequest) for Archive and Delete buttons at its right.",
            "Mac sidebar: Hide folds a session's sidechats and sidequests into one line (\"4 threads · 1 working\"); click it to open them again.",
            "Mac Activity: a new reply's dot is its model's color, and sidequests sit indented under the session that sent them.",
            "The Mac's session sidebar has Skills used: each skill the session has used (Claude's or Codex's), how many times, and when last.",
            "Closing Image Review with unsent notes (Esc or Cancel) asks before deleting them.",
            "Image Review on the Mac starts with numbered notes: click a spot (or drag an area) to add one. The pen is now a button above them, to switch on when you want to draw.",
            "The background service saves its state off its main thread, so it answers the app and phone promptly while replies stream.",
            "The Mac app uses much less CPU while replies stream: it's now an optimized build, and the sidebar no longer rescans every session's tags and the archive on each update.",
            "Desk card titles show in full, on as many lines as they need, instead of ending in an ellipsis.",
            "Link a thread on the Mac's Desk has a search box and shows at least five threads at a time.",
            "Desk columns on the Mac collapse to a narrow strip: empty ones by themselves, any column with the button in its header. Click a strip to open it.",
            "Review and On hold cards on the Desk are accordions: just the title and the buttons, until you tap the title to see the rest.",
            "Desk: \"Waiting for response\" when putting a card on hold (the Hold button on Review cards, and each card's menu). It sits in On hold with that label; long-press or right-click a held card to switch.",
            "Desk cards from ClickUp (or an email) show the task's status as a colored pill and a link that opens it there, on the Mac and the phone.",
        ]),
        Day(id: "2026-11-18", changes: [
            "Tapping Download on a phone image always starts it: it shows progress, the picture or an error, whatever else is going on.",
            "Images on the phone load the first time you open a session, without leaving and coming back.",
            "The \"This looks like … work\" banner is gone from chats on the Mac and the phone. Moving a session to a Studio is still in its menu.",
            "A session card on the Mac that's asking you something has a yellow border, instead of a bar down its side.",
            "Turning off Show Tag Pills on the Mac also hides the tags on session cards and sidebar rows.",
            "Activity on the phone puts a session's sidequests and Sidechats inside its card, as the other lists do.",
        ]),
        Day(id: "2026-11-17", changes: [
            "The Desk's Needs you shows only sessions on the Desk: ones with a task, their sidequests, and any you switch on with Show on the Desk (a session's Task menu on the Mac; its ⋯ menu or About on the phone).",
            "New Project on the phone: New Chat's \"Start in\" has New Project…, where you pick a Mac folder (or make a subfolder in it). From the Projects page, New starts there.",
            "Sidequests and automation runs on the phone are rows inside the card of the session that started them, like Sidechats and work threads.",
            "Touching the text of a Review or Needs you card on the phone no longer opens the session, so scrolling over it doesn't either. Use the card's Open button (permission and plan cards now have one).",
            "Review cards on the phone have smaller one-line buttons: Complete, Open and Hold.",
            "The Desk has the same desk-lamp icon on the Mac as on the phone.",
            "A pinned session on the Mac stays in its own list (its Studio, Projects or Chats) too, first and marked with a pin.",
        ]),
        Day(id: "2026-11-14", changes: [
            "Tapping Download on a phone image keeps the request running through visibility or address changes, and resumes it when you return to the app.",
            "Images on the phone have Download and Restart Download buttons, with a progress bar, percent and data transferred while they load.",
            "Projects on the phone show a solid rounded square with a star.",
            "A Studio's header on the phone has a New Session button for that Studio; its instructions moved to the ⋯ menu.",
        ]),
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
                // Not in tests: a sheet over the app would hide what they tap. That's the phone's
                // UI tests, and the Mac's test harnesses, which run the app's views in a plain
                // executable (no .app bundle, with fresh preferences that never saw the note).
                if ProcessInfo.processInfo.environment["CHATTERBOX_TEST_HOST"] != nil
                    || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
                    || Bundle.main.bundleURL.pathExtension != "app" { return }
                let new = seen.isEmpty ? Array(Changelog.days.prefix(1)) : Changelog.since(seen)
                if !new.isEmpty { showing = new }
            }
            .sheet(isPresented: Binding(get: { showing != nil }, set: { if !$0 { done() } })) {
                WhatsNewNote(days: showing ?? [], seeAll: seeAll.map { action in { done(); action() } }, close: done)
            }
    }

    private func done() { seen = Changelog.latest; showing = nil }
}
