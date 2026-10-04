import SwiftUI

/// Above the message box: what the agent has going apart from its reply, like subagents
/// and background commands. One line; click it for the list.
struct BackgroundWorkBar: View {
    let session: ChatSession
    var color: Color
    @State var expanded = false

    private var tasks: [BackgroundTask] { session.backgroundTasks }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 7) {
                    ActivitySpinner(color: color).frame(width: 10, height: 10)
                    Text(summary).lineLimit(1).truncationMode(.tail)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? "Hide the list" : "Show what's running")

            if expanded {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(tasks) { task in TaskRow(task: task) }
                }
                .padding(.leading, 17)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    /// "Running in the background: “Draft the logo” and 2 more", or a count by kind.
    private var summary: String {
        let agents = tasks.filter { $0.kind == .agent }.count
        let shells = tasks.count - agents
        let lead = session.isRunning ? "Also running" : "Running in the background"
        if tasks.count == 1, let task = tasks.first {
            return "\(lead): \(task.kind == .agent ? "subagent" : "command") \u{201C}\(task.title)\u{201D}"
        }
        let parts = [agents > 0 ? "\(agents) subagent\(agents == 1 ? "" : "s")" : nil,
                     shells > 0 ? "\(shells) command\(shells == 1 ? "" : "s")" : nil].compactMap { $0 }
        return "\(lead): " + parts.joined(separator: " and ")
    }
}

private struct TaskRow: View {
    let task: BackgroundTask

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: task.kind == .agent ? "person.2" : "terminal")
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(task.title)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let detail = task.detail {
                    Text(detail).lineLimit(1).truncationMode(.tail)
                }
            }
            Spacer(minLength: 8)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(Self.elapsed(from: task.startedAt, to: context.date))
                    .monospacedDigit()
            }
        }
        .help(task.kind == .agent ? "A subagent working on its own" : "A shell command left running")
    }

    static func elapsed(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
    }
}
