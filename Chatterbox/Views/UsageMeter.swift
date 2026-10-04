import SwiftUI

/// A small ring under the message box showing how full the chat's context is. Hover for the
/// numbers, click for them plus the account's usage limits. Drawn statically: it only redraws
/// when the numbers change.
struct UsageMeter: View {
    /// Just the percentage, for the small floating chat.
    var compact = false
    let session: ChatSession
    let color: Color
    @State private var isOpen = false

    private var context: ContextUsage? { session.contextUsage[session.record.backend] }
    private var limits: [UsageWindow] { UsageLimits.shared.windows(for: session.record.backend) }

    var body: some View {
        if let context {
            let fraction = context.fraction
            Button { isOpen.toggle() } label: {
                HStack(spacing: 5) {
                    ZStack {
                        Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 2)
                        Circle()
                            .trim(from: 0, to: max(0.02, fraction ?? 0))
                            .stroke(ringColor(fraction ?? 0), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 12, height: 12)
                    Text(fraction.map { (compact ? "" : "Context ") + "\(Int(($0 * 100).rounded()))%" } ?? "\(Self.tokens(context.used))" + (compact ? "" : " tokens"))
                        .lineLimit(1)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(fraction.map { $0 >= 0.75 ? ringColor($0) : Color.secondary } ?? .secondary)
                }
                .padding(2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(summary)
            .popover(isPresented: $isOpen, arrowEdge: .top) { details.padding(14).frame(width: 280) }
            .accessibilityLabel(fraction.map { "Context \(Int($0 * 100)) percent full" } ?? "Context \(context.used) tokens")
        }
    }

    private func ringColor(_ fraction: Double) -> Color {
        fraction >= 0.9 ? .red : fraction >= 0.75 ? .orange : color
    }

    private var summary: String {
        var lines: [String] = []
        if let context { lines.append("Context: " + Self.contextText(context)) }
        for window in limits { lines.append("\(window.label) limit: " + Self.limitText(window)) }
        return lines.joined(separator: "\n")
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let context, let fraction = context.fraction {
                meterRow(title: "Context", value: Self.contextText(context), fraction: fraction,
                         tint: ringColor(fraction))
            }
            if !limits.isEmpty {
                Divider()
                Text("\(session.record.backend.label) usage limits").font(.callout.weight(.medium))
                ForEach(limits) { window in
                    meterRow(title: window.label, value: Self.limitText(window), fraction: window.utilization,
                             tint: window.utilization >= 0.9 ? .red : window.utilization >= 0.75 ? .orange : color)
                }
            }
        }
    }

    private func meterRow(title: String, value: String, fraction: Double, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.callout)
                Spacer()
                Text(value).font(.caption).foregroundStyle(.secondary)
            }
            ProgressView(value: min(1, max(0, fraction))).tint(tint)
        }
    }

    static func contextText(_ context: ContextUsage) -> String {
        guard let window = context.window else { return "\(tokens(context.used)) tokens" }
        return "\(tokens(context.used)) of \(tokens(window)) tokens (\(Int(((context.fraction ?? 0) * 100).rounded()))%)"
    }

    static func limitText(_ window: UsageWindow) -> String {
        let used = "\(Int((window.utilization * 100).rounded()))% used"
        guard let reset = window.resetsAt else { return used }
        let when = Calendar.current.isDateInToday(reset)
            ? reset.formatted(date: .omitted, time: .shortened)
            : reset.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        return "\(used), resets \(when)"
    }

    static func tokens(_ count: Int) -> String {
        switch count {
        case 1_000_000...: return String(format: count % 1_000_000 == 0 ? "%.0fM" : "%.1fM", Double(count) / 1_000_000)
        case 1_000...: return String(format: count >= 100_000 || count % 1_000 == 0 ? "%.0fK" : "%.1fK", Double(count) / 1_000)
        default: return "\(count)"
        }
    }
}
