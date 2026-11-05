import SwiftUI

// Work threads on the Mac (plans/work-threads.md): a project's front thread starts fresh threads
// for real pieces of work, each with a brief and its own task on the Desk, and they report back.
// In the front thread, the thread sidebar's Task & work lists them with their state
// (ThreadSidebar.swift); in a work thread, a header says whom it works for, with a link back.
// "Start a Work Thread" is in that section and the session menu, beside the task items (Make
// This a Task, Link to a Task, Unlink).

/// Where a thread stands, as the thread sidebar and the board say it.
enum WorkThreadState: String {
    case working, needsYou, ready, done

    @MainActor init(_ session: ChatSession) {
        self = session.record.archivedAt != nil ? .done : session.isWaitingOnYou ? .needsYou
            : session.isWorkingOn ? .working : .ready
    }

    var label: String {
        switch self {
        case .working: "Working"
        case .needsYou: "Needs you"
        case .ready: "Ready"
        case .done: "Done"
        }
    }
    var icon: String {
        switch self {
        case .working: "circle.dotted"
        case .needsYou: "hand.raised.fill"
        case .ready: "checkmark.circle"
        case .done: "checkmark.circle.fill"
        }
    }
    var color: Color {
        switch self {
        case .working: .blue
        case .needsYou: .attention
        case .ready: .green
        case .done: .secondary
        }
    }
}

/// A work thread's name, its brief, and its agent; Start sends them to the service.
struct WorkThreadForm: View {
    let front: ChatSession
    let done: () -> Void
    @Environment(AppModel.self) private var model
    @State private var title = ""
    @State private var brief = ""
    /// nil: the front thread's own agent and model.
    @State private var agent: Backend?
    @State private var starting = false
    @State private var problem: String?
    private var ready: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !starting
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Start a Work Thread").font(.headline)
            Text("A fresh thread in this folder that starts from your brief alone, not this conversation. It goes on the Desk as a task, and its result comes back here when it finishes.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Name", text: $title, prompt: Text("What it's doing, in a few words"))
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Work thread name")
            Text("Brief").font(.subheadline.weight(.semibold))
            TextEditor(text: $brief)
                .font(.body)
                .frame(minHeight: 110, maxHeight: 220)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .topLeading) {
                    if brief.isEmpty {
                        Text("What to do, what's decided, which files and plans to read, what to report")
                            .foregroundStyle(.tertiary).padding(.horizontal, 9).padding(.vertical, 4).allowsHitTesting(false)
                    }
                }
                .accessibilityLabel("Brief")
            Picker("Agent", selection: $agent) {
                Text("\(front.record.backend.label), as this session").tag(Backend?.none)
                Text("Claude").tag(Backend?.some(.claude))
                Text("Codex").tag(Backend?.some(.codex))
            }
            .pickerStyle(.menu)
            if let problem { Text(problem).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            HStack {
                if starting { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button("Start Work Thread", action: start)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!ready)
            }
        }
        .padding(16)
        .frame(width: 400)
    }

    private func start() {
        guard ready else { return }
        starting = true
        Task {
            defer { starting = false }
            do {
                try await model.startWorkThread(of: front, title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                                                brief: brief.trimmingCharacters(in: .whitespacesAndNewlines), agent: agent == front.record.backend ? nil : agent)
                done()
            } catch {
                problem = "Couldn't start it: \(error.localizedDescription)"
            }
        }
    }
}

/// Across the top of a work thread: the front thread it works for, with a link back.
struct WorkThreadBanner: View {
    let session: ChatSession
    @Environment(AppModel.self) private var model

    var body: some View {
        let front = session.record.workOf.flatMap { id in model.sessions.first { $0.id == id } }
        let reported = session.record.workReported != nil || session.record.workReportedAt != nil
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
            Text("Work for \u{201C}\(front?.title ?? "a session that's gone")\u{201D}. "
                 + (session.isWorkPending ? "Background work is still running; its result goes back there when that's done."
                    : reported ? "Its result went back there." : "Its result goes back there when it finishes."))
                .lineLimit(2)
            Spacer()
            if let front {
                Button("Open \(front.title)") { model.selectedID = front.id }
                    .help("Back to the front thread")
                    .accessibilityIdentifier("workFront")
            }
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.10))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workBanner")
    }
}

/// A session menu's task items (plans/work-threads.md): Make This a Task, Link to a Task (a
/// To do one), or Unlink from its task. Nothing from a service older than tasks.
struct ThreadTaskMenu: View {
    let session: ChatSession
    var desk: DeskModel = .shared

    var body: some View {
        if desk.hasTasks, session.record.sidequestOf == nil, session.record.automationID == nil, session.record.archivedAt == nil {
            if let task = desk.task(of: session.id) {
                Button("Unlink from Task \u{201C}\(DeskStore.short(task.text, limit: 40))\u{201D}") { Task { await desk.unlink(task.id) } }
            } else {
                Button("Make This a Task") { Task { await desk.makeTask(session.id) } }
                let todo = desk.snapshot?.incoming ?? []
                if !todo.isEmpty {
                    Menu("Link to a Task") {
                        ForEach(todo) { request in
                            Button(DeskStore.short(request.text, limit: 60)) { Task { await desk.link(request.id, to: session.id) } }
                        }
                    }
                }
            }
        }
    }
}
