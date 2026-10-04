import SwiftUI

/// What a transcript row can do, handed down from the chat.
struct ItemActions {
    var decide: (UUID, String) -> Void = { _, _ in }
    var answer: (UUID, [String: [String]]?) -> Void = { _, _ in }
    var sendQueuedNow: (UUID) -> Void = { _ in }
    var markUp: (UIImage) -> Void = { _ in }
}

/// An action the agent wants to take, or a plan it wants to start: allow, allow for this
/// chat, or deny. Once decided, it says what was decided.
struct ApprovalCard: View {
    let item: Companion.Item
    let approval: Companion.Approval
    let decide: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(approval.isPlan ? "Ready to build" : "Permission needed",
                  systemImage: approval.isPlan ? "list.bullet.clipboard" : "hand.raised.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(approval.state == "pending" ? .yellow : .secondary)
            Text(item.text).font(.callout.weight(.medium))
            if let detail = item.detail, !detail.isEmpty {
                if approval.isPlan {
                    ScrollView { MarkdownText(text: detail).frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(maxHeight: 360)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color(uiColor: .secondarySystemBackground)))
                } else {
                    Text(detail).font(.caption.monospaced()).textSelection(.enabled).lineLimit(14)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color(uiColor: .secondarySystemBackground)))
                }
            }
            if approval.state == "pending" {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { buttons }
                    VStack(alignment: .leading, spacing: 8) { buttons }
                }
            } else {
                outcome
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.yellow.opacity(approval.state == "pending" ? 0.12 : 0.04)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.yellow.opacity(approval.state == "pending" ? 0.5 : 0.15)))
    }

    @ViewBuilder
    private var buttons: some View {
        Button(approval.isPlan ? "Start Building" : "Allow") { decide("approved") }
            .buttonStyle(.borderedProminent)
        Button(approval.isPlan ? "Start and Accept Edits" : "Allow for This Chat") { decide("approvedForSession") }
            .buttonStyle(.bordered)
        Button(approval.isPlan ? "Keep Planning" : "Deny", role: .destructive) { decide("denied") }
            .buttonStyle(.bordered)
    }

    private var outcome: some View {
        let (text, icon, color): (String, String, Color) = switch approval.state {
        case "approved": (approval.isPlan ? "Building, asking before edits" : "Allowed", "checkmark.circle", .green)
        case "approvedForSession": (approval.isPlan ? "Building, accepting edits" : "Allowed for this chat", "checkmark.circle", .green)
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
    @State private var picked: [String: Set<String>]
    @State private var other: [String: String]

    private var isPending: Bool { item.isPending }

    /// Opens with Golem's suggestion picked, if he made one: options he named are selected,
    /// anything else goes in the "Other" field.
    init(item: Companion.Item, questions: [Companion.Question], answer: @escaping ([String: [String]]?) -> Void) {
        self.item = item
        self.questions = questions
        self.answer = answer
        var picked: [String: Set<String>] = [:], other: [String: String] = [:]
        for question in questions {
            guard let values = item.suggested?[question.id] else { continue }
            let labels = Set(question.options.map(\.label))
            picked[question.id] = Set(values.filter(labels.contains))
            let typed = values.filter { !labels.contains($0) }
            if !typed.isEmpty { other[question.id] = typed.joined(separator: ", ") }
        }
        _picked = State(initialValue: picked)
        _other = State(initialValue: other)
    }

    /// Golem's suggestion for every question on the card, sent as is with one tap.
    private var suggestion: [String: [String]]? {
        guard isPending, let suggested = item.suggested else { return nil }
        let answers = suggested.filter { id, _ in questions.contains { $0.id == id } }
        return answers.isEmpty ? nil : answers
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(isPending ? "Questions for you" : "Answered", systemImage: isPending ? "questionmark.bubble.fill" : "checkmark.bubble")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isPending ? .yellow : .secondary)
            if let suggestion {
                VStack(alignment: .leading, spacing: 8) {
                    Label {
                        Text("Golem suggests " + questions.compactMap { suggestion[$0.id]?.joined(separator: ", ") }.joined(separator: " \u{00B7} "))
                            .font(.callout.weight(.semibold))
                    } icon: { Image(systemName: "sparkles") }
                    if let reason = item.suggestedReason, !reason.isEmpty {
                        Text(reason).font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Send Golem\u{2019}s Answer") { answer(suggestion) }
                        .buttonStyle(.borderedProminent)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.yellow.opacity(0.10)))
                .accessibilityElement(children: .contain)
            }
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
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.yellow.opacity(isPending ? 0.12 : 0.04)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.yellow.opacity(isPending ? 0.5 : 0.15)))
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
