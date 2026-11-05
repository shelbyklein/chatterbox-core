import SwiftUI

// Work threads on the phone (plans/work-threads.md): a project's front thread starts fresh
// threads for real pieces of work, each with a brief and its own task on the Desk, and they
// report back. A front thread's About panel lists them with their state (a pill under its title
// counts the working ones); above a work thread's transcript, a header says whom it works for.

extension Companion.WorkThread {
    var stateLabel: String {
        switch state {
        case "working": "Working"
        case "needsYou": "Needs you"
        case "done": "Done"
        default: "Ready"
        }
    }
    var stateIcon: String {
        switch state {
        case "working": "circle.dotted"
        case "needsYou": "hand.raised.fill"
        case "done": "checkmark.circle.fill"
        default: "checkmark.circle"
        }
    }
    var stateColor: Color {
        switch state {
        case "working": .blue
        case "needsYou": .attention
        case "done": .secondary
        default: .green
        }
    }
}

/// Above a work thread's transcript: the front thread it reports to, with a link back. (A front
/// thread's own work threads are in its About panel, with a "working" pill under its title.)
struct MobileWorkHeader: View {
    let summary: Companion.ChatSummary
    let detail: Companion.ChatDetail?
    let chats: [Companion.ChatSummary]
    let open: (Companion.ChatSummary) -> Void

    var body: some View {
        if let front = summary.workOf {
            let listed = chats.first { $0.id == front }
            let title = listed?.title ?? detail?.workOfTitle ?? "its front thread"
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch")
                Text("Work for \u{201C}\(title)\u{201D}. Its result goes back there.")
                    .font(.caption).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Open") {
                    open(listed ?? .init(id: front, title: title, project: nil, subtitle: nil, backend: summary.backend,
                                         isRunning: false, isWaitingOnYou: false, updatedAt: Date()))
                }
                .font(.caption.weight(.semibold))
                .accessibilityLabel("Open \(title)")
                .accessibilityIdentifier("work-front-open")
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.bar)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("work-header")
        }
    }
}

/// Start a Work Thread: its name, the brief it starts from, and its agent.
struct MobileWorkStartSheet: View {
    let summary: Companion.ChatSummary
    let start: (Companion.WorkStartRequest) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var brief = ""
    /// Empty: the front thread's own agent and model.
    @State private var agent = ""
    @State private var starting = false
    @State private var problem: String?
    private var ready: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !starting
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What it's doing, in a few words", text: $title)
                        .accessibilityIdentifier("work-title")
                } header: { Text("Name") }
                Section {
                    TextField("What to do, what's decided, which files and plans to read, what to report", text: $brief, axis: .vertical)
                        .lineLimit(5...12)
                        .accessibilityIdentifier("work-brief")
                } header: { Text("Brief") } footer: {
                    Text("A fresh thread in this folder that starts from the brief alone, not this conversation. It goes on the Desk as a task, and its result comes back here when it finishes.")
                }
                Section("Agent") {
                    Picker("Agent", selection: $agent) {
                        Text("\(summary.backend == "codex" ? "Codex" : "Claude"), as this session").tag("")
                        Text("Claude").tag("claude")
                        Text("Codex").tag("codex")
                    }
                    .pickerStyle(.inline).labelsHidden()
                }
                if let problem { Section { Text(problem).foregroundStyle(.orange) } }
            }
            .navigationTitle("Start a Work Thread")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start", action: begin).fontWeight(.semibold).disabled(!ready)
                        .accessibilityIdentifier("work-start")
                }
            }
        }
        .presentationDetents([.large])
    }

    private func begin() {
        starting = true
        Task {
            defer { starting = false }
            do {
                try await start(.init(title: title.trimmingCharacters(in: .whitespacesAndNewlines), brief: brief.trimmingCharacters(in: .whitespacesAndNewlines),
                                      agent: agent.isEmpty || agent == summary.backend ? nil : agent))
                dismiss()
            } catch { problem = error.localizedDescription }
        }
    }
}
