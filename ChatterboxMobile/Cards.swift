import SwiftUI

/// What a transcript row can do, handed down from the chat.
struct ItemActions {
    var decide: (UUID, String) -> Void = { _, _ in }
    var answer: (UUID, [String: [String]]?) -> Void = { _, _ in }
    var sendQueuedNow: (UUID) -> Void = { _ in }
    var markUp: (UIImage) -> Void = { _ in }
    /// Where the chat is, for its approval cards: "USA Archery › Deploy the site".
    var context: String? = nil
}

/// What a session waits on you for, in one word, everywhere (the Desk, the session's cards,
/// the Mac): Permission, Plan or Question.
enum WaitingKind {
    static func title(_ kind: String) -> String {
        switch kind {
        case "plan": "Plan"
        case "questions", "reply": "Question"
        default: "Permission"
        }
    }
    static func icon(_ kind: String) -> String {
        switch kind {
        case "plan": "list.bullet.clipboard"
        case "questions": "questionmark.bubble.fill"
        case "reply": "text.bubble.fill"
        default: "hand.raised.fill"
        }
    }
}

/// The one approval card, on the Desk and in the session: where it is (place › session), what
/// it asks, the exact command (always shown, cut in the middle; tap it for all of it), then
/// Allow (filled), Allow for Session and Deny. A plan: Start Building, Start and Accept Edits,
/// Keep Planning. The surface around it (card, colors) is the caller's.
struct ApprovalPanel: View {
    /// "USA Archery › Deploy the site"; nil leaves it out.
    var context: String?
    let ask: String
    /// The command or files; nil for a plan.
    var command: String?
    var isPlan = false
    /// A plan's text, to read before building (the session's card).
    var plan: String?
    /// Waiting for an answer; else `outcome` shows instead of the buttons.
    var pending = true
    /// Sent, and not answered yet.
    var busy = false
    /// Each part's identifier, from its name ("allow", "allow-session", "deny", "command", "context").
    var identifier: (String) -> String = { "approval-\($0)" }
    let decide: (String) -> Void
    /// Wraps each button's action (the Desk's swipe guard); as it is otherwise.
    var taps: (@escaping () -> Void) -> () -> Void = { $0 }
    /// The Desk: the top of the card (kind, where, the ask) opens its session.
    var open: (() -> Void)? = nil
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let open {
                Button(action: taps(open)) { header.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens the session")
                    .accessibilityIdentifier(identifier("open-card"))
            } else {
                header
            }
            if let command, !command.isEmpty { commandBlock(command) }
            if let plan, !plan.isEmpty {
                ScrollView { MarkdownText(text: plan).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 360)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(uiColor: .tertiarySystemFill)))
            }
            if pending {
                if busy {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Sending…").font(.footnote).foregroundStyle(Color.metadata)
                    }
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { buttons }
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) { allow; allowForSession }
                            deny
                        }
                        VStack(alignment: .leading, spacing: 8) { buttons }
                    }
                }
            }
        }
    }

    /// Its kind in one word, where it is, then what it asks.
    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(isPlan ? "Plan" : "Permission", systemImage: isPlan ? "list.bullet.clipboard" : "hand.raised.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(pending ? Color.attention : Color.metadata)
            if let context {
                Text(context).font(.subheadline.weight(.semibold)).lineLimit(2).multilineTextAlignment(.leading)
                    .accessibilityIdentifier(identifier("context"))
            }
            Text(ask).font(.callout)
                .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The command in monospace: one line cut in the middle (both ends show), all of it once tapped.
    private func commandBlock(_ command: String) -> some View {
        let long = command.count > 36 || command.contains("\n")
        return Button { if long { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } } label: {
            HStack(alignment: .top, spacing: 6) {
                Group {
                    if expanded {
                        Text(command).lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(command.split(whereSeparator: \.isNewline).joined(separator: " \u{23CE} ")).lineLimit(1).truncationMode(.middle)
                    }
                }
                .font(.caption.monospaced())
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                if long {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(Color.metadata)
                        .padding(.top, 2)
                }
            }
            .padding(.horizontal, 9).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(uiColor: .tertiarySystemFill)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Command: \(command)")
        .accessibilityHint(long ? (expanded ? "Shows one line" : "Shows the whole command") : "")
        .accessibilityIdentifier(identifier("command"))
        .contextMenu { Button("Copy Command", systemImage: "doc.on.doc") { UIPasteboard.general.string = command } }
    }

    @ViewBuilder private var buttons: some View { allow; allowForSession; deny }

    private var allow: some View {
        Button(isPlan ? "Start Building" : "Allow", action: taps { decide("approved") })
            .buttonStyle(.borderedProminent)
            // The same blue on the Desk and in a session (whose own tint is its agent's color).
            .tint(.blue)
            .accessibilityIdentifier(identifier("allow"))
    }
    private var allowForSession: some View {
        Button(isPlan ? "Start and Accept Edits" : "Allow for Session", action: taps { decide("approvedForSession") })
            .buttonStyle(.bordered)
            .tint(.blue)
            .accessibilityIdentifier(identifier("allow-session"))
    }
    private var deny: some View {
        Button(isPlan ? "Keep Planning" : "Deny", role: .destructive, action: taps { decide("denied") })
            .buttonStyle(.bordered)
            .tint(.red)
            .accessibilityIdentifier(identifier("deny"))
    }
}

/// An action the agent wants to take, or a plan it wants to start, in its session: the one
/// approval card (ApprovalPanel). Once decided, it says what was decided.
struct ApprovalCard: View {
    let item: Companion.Item
    let approval: Companion.Approval
    /// "USA Archery › Deploy the site", as the Desk shows it.
    var context: String?
    let decide: (String) -> Void

    private var pending: Bool { approval.state == "pending" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ApprovalPanel(context: context, ask: item.text, command: approval.isPlan ? nil : item.detail, isPlan: approval.isPlan,
                          plan: approval.isPlan ? item.detail : nil, pending: pending, decide: decide)
            if !pending { outcome }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.attention.opacity(pending ? 0.10 : 0.03)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.attention.opacity(pending ? 0.7 : 0.2), lineWidth: pending ? 1.5 : 1))
    }

    private var outcome: some View {
        let (text, icon, color): (String, String, Color) = switch approval.state {
        case "approved": (approval.isPlan ? "Building, asking before edits" : "Allowed", "checkmark.circle", .green)
        case "approvedForSession": (approval.isPlan ? "Building, accepting edits" : "Allowed for this session", "checkmark.circle", .green)
        case "denied": (approval.isPlan ? "Kept planning" : "Denied", "xmark.circle", .red)
        default: ("No longer waiting", "clock", .secondary)
        }
        return Label(text, systemImage: icon).font(.footnote).foregroundStyle(color)
    }
}

/// Questions the agent asked: pick options (or type your own), then send them all at once.
struct QuestionsCard: View {
    let item: Companion.Item
    let questions: [Companion.Question]
    let answer: ([String: [String]]?) -> Void
    @State private var picked: [String: Set<String>] = [:]
    @State private var other: [String: String] = [:]

    private var isPending: Bool { item.isPending }

    init(item: Companion.Item, questions: [Companion.Question], answer: @escaping ([String: [String]]?) -> Void) {
        self.item = item
        self.questions = questions
        self.answer = answer
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(isPending ? "Question" : "Answered", systemImage: isPending ? "questionmark.bubble.fill" : "checkmark.bubble")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isPending ? Color.attention : Color.metadata)
            ForEach(questions) { question in
                VStack(alignment: .leading, spacing: 8) {
                    if !question.header.isEmpty {
                        Text(question.header.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    Text(question.question).font(.callout.weight(.medium))
                    if isPending {
                        ForEach(question.options, id: \.label) { option in optionRow(option, in: question) }
                        Group {
                            if question.isSecret {
                                SecureField("Other answer", text: binding(for: question.id))
                            } else {
                                TextField("Other answer", text: binding(for: question.id), axis: .vertical)
                            }
                        }
                        .textFieldStyle(.roundedBorder)
                    } else if let given = item.answers?[question.id], !given.isEmpty {
                        Text(question.isSecret ? "••••••" : given.joined(separator: ", "))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            if isPending {
                HStack {
                    Button("Send Answers") { answer(collected) }
                        .buttonStyle(.borderedProminent)
                        .disabled(collected.isEmpty)
                    Button("Skip") { answer(nil) }
                        .buttonStyle(.bordered)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.attention.opacity(isPending ? 0.10 : 0.03)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.attention.opacity(isPending ? 0.7 : 0.2), lineWidth: isPending ? 1.5 : 1))
    }

    private func optionRow(_ option: Companion.Question.Option, in question: Companion.Question) -> some View {
        let isOn = picked[question.id]?.contains(option.label) == true
        return Button {
            var set = picked[question.id] ?? []
            if question.multiSelect {
                if isOn { set.remove(option.label) } else { set.insert(option.label) }
            } else {
                set = isOn ? [] : [option.label]
            }
            picked[question.id] = set
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: question.multiSelect ? (isOn ? "checkmark.square.fill" : "square") : (isOn ? "largecircle.fill.circle" : "circle"))
                    .foregroundStyle(isOn ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label).foregroundStyle(.primary)
                    if !option.detail.isEmpty { Text(option.detail).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(isOn ? Color.accentColor.opacity(0.12) : Color(uiColor: .secondarySystemBackground)))
        }
        .buttonStyle(.plain)
    }

    private func binding(for id: String) -> Binding<String> {
        Binding(get: { other[id] ?? "" }, set: { other[id] = $0 })
    }

    /// Picked options plus anything typed, by question.
    private var collected: [String: [String]] {
        var result: [String: [String]] = [:]
        for question in questions {
            var values = question.options.map(\.label).filter { picked[question.id]?.contains($0) == true }
            let typed = (other[question.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !typed.isEmpty { values.append(typed) }
            if !values.isEmpty { result[question.id] = values }
        }
        return result
    }
}
