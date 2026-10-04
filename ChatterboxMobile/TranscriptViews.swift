import SwiftUI

/// "45s", "4m 12s", "1h 3m", as on the Mac.
func durationText(_ seconds: Int) -> String {
    if seconds < 60 { return "\(seconds)s" }
    if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
    return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
}

/// A tool the agent used: a spinner while it runs, then a check, or an orange mark if it failed.
struct ToolRow: View {
    let item: Companion.Item

    var body: some View {
        HStack(spacing: 7) {
            Group {
                switch item.toolState {
                case "running": ProgressView().controlSize(.mini)
                case "failed": Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                default: Image(systemName: "checkmark.circle").foregroundStyle(.green)
                }
            }
            .frame(width: 16)
            Text(item.text).lineLimit(1).truncationMode(.middle)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
}

/// The agent's thinking, folded away until tapped.
struct ThoughtRow: View {
    let text: String
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.top, 4)
        } label: {
            Label("Thought", systemImage: "sparkle").font(.callout).foregroundStyle(.secondary)
        }
        .tint(.secondary)
    }
}

/// The agent's plan as a checklist.
struct PlanCard: View {
    let steps: [Companion.PlanStep]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Plan").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: step.status == "completed" ? "checkmark.circle.fill"
                          : step.status == "in_progress" ? "arrow.right.circle.fill" : "circle")
                        .foregroundStyle(step.status == "completed" ? Color.green : step.status == "in_progress" ? Color.accentColor : Color.secondary)
                    Text(step.step)
                        .strikethrough(step.status == "completed", color: .secondary)
                        .foregroundStyle(step.status == "completed" ? .secondary : .primary)
                }
                .font(.callout)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(uiColor: .secondarySystemBackground)))
    }
}

/// A `!` command you ran on the Mac, with its output folded away.
struct ShellRow: View {
    let item: Companion.Item
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "terminal")
                    Text("$ " + item.text).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    if item.detail?.isEmpty == false {
                        Image(systemName: "chevron.right").rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                }
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            if expanded, let output = item.detail, !output.isEmpty {
                ScrollView(.horizontal) {
                    Text(output)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .padding(10)
                }
                .frame(maxHeight: 260)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(uiColor: .secondarySystemBackground)))
            }
        }
    }
}

/// A page or drawing an agent wrote (HTML or SVG), fetched from the Mac and shown live.
struct RemotePreview: View {
    let file: Companion.File
    let chat: UUID
    @Environment(MobileStore.self) private var store
    @State private var source: PreviewSource?

    static func isPreviewable(_ file: Companion.File) -> Bool {
        ["html", "htm", "svg"].contains((file.name as NSString).pathExtension.lowercased())
    }

    var body: some View {
        Group {
            if let source {
                HTMLPreview(source: source)
            } else {
                RoundedRectangle(cornerRadius: 8).fill(Color(uiColor: .secondarySystemBackground))
                    .frame(height: 160)
                    .overlay(ProgressView())
            }
        }
        .task {
            guard source == nil, let data = try? await store.file(file, in: chat), let text = String(data: data, encoding: .utf8) else { return }
            source = (file.name as NSString).pathExtension.lowercased() == "svg" ? .svg(text) : .html(text)
        }
    }
}

/// Above the message box while the agent works: how long it's been going, how full its
/// context is, and anything running in the background.
struct ChatStatusBar: View {
    let detail: Companion.ChatDetail
    @State private var expanded = false

    private var tasks: [Companion.BackgroundTask] { detail.backgroundTasks ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                if let started = detail.turnStartedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Label("Working \(durationText(Int(context.date.timeIntervalSince(started))))", systemImage: "clock")
                    }
                }
                if !tasks.isEmpty {
                    Button { expanded.toggle() } label: {
                        Label("\(tasks.count) in background", systemImage: "square.stack.3d.down.right")
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
                if let fraction = detail.contextFraction {
                    ContextRing(fraction: fraction)
                }
            }
            if expanded {
                ForEach(tasks) { task in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: task.kind == "agent" ? "person.2" : "terminal").frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(task.title).foregroundStyle(.primary).lineLimit(1)
                            if let detail = task.detail { Text(detail).lineLimit(1) }
                        }
                        Spacer(minLength: 6)
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(durationText(Int(context.date.timeIntervalSince(task.startedAt)))).monospacedDigit()
                        }
                    }
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

/// How full the agent's context is: a small ring and a percentage, orange past three quarters.
struct ContextRing: View {
    let fraction: Double

    private var color: Color { fraction >= 0.9 ? .red : fraction >= 0.75 ? .orange : .secondary }

    var body: some View {
        HStack(spacing: 4) {
            ZStack {
                Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 2)
                Circle().trim(from: 0, to: max(0.02, fraction))
                    .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 12, height: 12)
            Text("\(Int((fraction * 100).rounded()))%").monospacedDigit().foregroundStyle(fraction >= 0.75 ? color : .secondary)
        }
        .accessibilityLabel("Context \(Int((fraction * 100).rounded())) percent full")
    }
}
