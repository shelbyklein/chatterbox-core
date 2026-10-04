import SwiftUI

/// Agent identity on mobile. Bubble fills are dark enough for white message text in either theme.
enum MobileConversationStyle {
    static func bubble(for backend: String) -> Color {
        backend == "codex" ? Color(red: 0.14, green: 0.42, blue: 0.27)
            : Color(red: 0.62, green: 0.28, blue: 0.11)
    }

    static func accent(for backend: String) -> Color {
        Color(uiColor: UIColor { traits in
            if backend == "codex" {
                return traits.userInterfaceStyle == .dark
                    ? UIColor(red: 0.36, green: 0.78, blue: 0.55, alpha: 1)
                    : UIColor(red: 0.14, green: 0.42, blue: 0.27, alpha: 1)
            }
            return traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.96, green: 0.61, blue: 0.36, alpha: 1)
                : UIColor(red: 0.62, green: 0.28, blue: 0.11, alpha: 1)
        })
    }

    struct Group: Identifiable {
        var items: [Companion.Item]
        var isSteps: Bool
        var id: UUID { items[0].id }
    }

    /// Keep progress notes visible, but fold consecutive technical rows in Golem's conversation.
    static func groups(_ items: [Companion.Item], conversation: Bool) -> [Group] {
        var result: [Group] = []
        for item in items {
            let steps = conversation && [.tool, .thought, .shell].contains(item.kind)
            if steps, result.last?.isSteps == true {
                result[result.count - 1].items.append(item)
            } else {
                result.append(Group(items: [item], isSteps: steps))
            }
        }
        return result
    }
}

/// Parsed Markdown blocks, rather than splitting on blank lines: a list, table or code fence
/// stays intact even when it contains paragraph spacing. Paragraphs each get their own bubble.
struct MobileReplyBubbles: View {
    let text: String
    let messageID: UUID

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(MarkdownText.blocks(text).enumerated()), id: \.offset) { index, block in
                MarkdownBlockText(block: block, source: text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color(uiColor: .secondarySystemBackground),
                                in: RoundedRectangle(cornerRadius: 20))
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("reply-bubble-\(messageID)-\(index)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 32)
    }
}
