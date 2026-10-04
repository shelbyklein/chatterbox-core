import AppKit
import SwiftUI

/// Renders one transcript row. Commentary is deliberately quiet so the final reply stands out.
struct ItemView: View {
    let item: DisplayItem
    /// True for the row the agent is working on right now.
    var isActive = false
    /// For user messages: the agent it went to, which picks the bubble color.
    var agent: Backend = .claude
    var onApproval: (UUID, DisplayItem.ApprovalState) -> Void = { _, _ in }
    var onAnswer: (UUID, [String: [String]]?) -> Void = { _, _ in }
    var onSendNow: (UUID) -> Void = { _ in }
    @Environment(\.readerStyle) private var style
    @Environment(\.chatFolder) private var chatFolder

    var body: some View {
        switch item.kind {
        case .user: userBubble
        case .assistant: assistantText
        case .thought: ThoughtView(text: item.text, isActive: isActive)
        case .tool: toolRow
        case .plan: PlanCard(steps: item.planSteps)
        case .notice: noticeRow
        case .approval: ApprovalCard(item: item) { onApproval(item.id, $0) }
        case .image: GeneratedImages(item: item)
        case .shell: ShellBlock(item: item)
        case .questions: QuestionCard(item: item, agent: agent) { onAnswer(item.id, $0) }
        }
    }

    @ViewBuilder
    private var userBubble: some View {
        if item.automatic == true {
            // A check-in Chatterbox sent Dot: its label, not the instructions behind it.
            Label(item.detail ?? "Check-in", systemImage: "clock.arrow.circlepath")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .help(item.text)
        } else {
            typedBubble
        }
    }

    private var typedBubble: some View {
        VStack(alignment: .trailing, spacing: 3) {
            if item.queued == true {
                HStack(spacing: 8) {
                    Label("Queued", systemImage: "clock")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help("Sent while the agent is working. It joins the reply at the agent's next step.")
                    Button("Send Now") { onSendNow(item.id) }
                        .buttonStyle(.link)
                        .font(.caption2.weight(.semibold))
                        .help("Stop what the agent is doing and take this message now (\u{2318}\u{21A9} when sending)")
                }
            } else if item.steered {
                Label("Sent while working", systemImage: "arrow.turn.down.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let attachments = item.attachments, !attachments.isEmpty {
                SentAttachments(attachments: attachments)
            }
            if !item.text.isEmpty {
                Text(item.text)
                    .font(style.body)
                    .lineSpacing(style.lineSpacing)
                    .textSelection(.enabled)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 14).fill(style.color(for: agent).opacity(style.bubbleStrength)))
                    .contextMenu { Button("Copy Message") { MessageClipboard.copy(item.text) } }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 80)
        .padding(.top, 6)
    }

    @ViewBuilder
    private var assistantText: some View {
        if item.phase == .commentary {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Circle().frame(width: 4, height: 4).foregroundStyle(.tertiary)
                Text(MarkdownText.inline(item.text, style: style, paths: PathLinks.context(for: item.text, folder: chatFolder)))
                    .font(style.secondary)
                    .lineSpacing(style.lineSpacing)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                MarkdownText(text: item.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // Animations the reply points to (made with a command, say), playing.
                if item.phase == .final {
                    ForEach(ChatSession.referencedMedia(in: item.text, folder: chatFolder), id: \.self) { url in
                        if let kind = MediaKind.of(url) { MediaPreview(url: url, kind: kind).frame(maxWidth: 640, alignment: .leading) }
                    }
                    ReplyImages(urls: ChatSession.referencedImages(in: item.text, folder: chatFolder))
                }
                if item.phase == .final {
                    HStack(spacing: 12) {
                        if let seconds = item.workedSeconds {
                            Label("Worked for \(ChatSession.durationText(seconds))", systemImage: "clock")
                        }
                        CopyMessageButton(text: item.text)
                    }
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                }
            }
            // Text selection stops at each paragraph, so the whole reply copies from here.
            .contextMenu {
                Button("Copy Message") { MessageClipboard.copy(item.text) }
                Button("Copy as Plain Text") { MessageClipboard.copy(MessageClipboard.plain(item.text)) }
            }
        }
    }

    private var toolRow: some View {
        HStack(spacing: 7) {
            Group {
                switch item.toolState {
                case .running: ProgressView().controlSize(.small)
                case .done:
                    Image(systemName: "checkmark.circle").foregroundStyle(.green)
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                case .failed:
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                }
            }
            .frame(width: 16)
            Text(item.text)
                .lineLimit(1)
                .truncationMode(.middle)
                .shimmering(item.toolState == .running)
        }
        .font(style.secondary)
        .foregroundStyle(.secondary)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: item.toolState)
    }

    private var noticeRow: some View {
        Text(item.text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
    }
}

private struct ApprovalCard: View {
    let item: DisplayItem
    let decide: (DisplayItem.ApprovalState) -> Void
    @Environment(\.cardFillsWidth) private var fillsWidth

    private var isPlan: Bool { item.approvalStyle == .plan }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(item.text, systemImage: "hand.raised")
                .font(.callout.weight(.medium))
            if let detail = item.detail, !detail.isEmpty {
                if isPlan {
                    ScrollView {
                        MarkdownText(text: detail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 320)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.6)))
                } else {
                    Text(detail)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(6)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.6)))
                }
            }
            switch item.approvalState ?? .expired {
            case .pending:
                HStack {
                    Button(isPlan ? "Start Building" : "Allow") { decide(.approved) }
                    Button(isPlan ? "Start and Accept Edits" : "Allow for This Chat") { decide(.approvedForSession) }
                    Button(isPlan ? "Keep Planning" : "Deny", role: .destructive) { decide(.denied) }
                }
                .controlSize(.small)
            case .approved:
                outcome(isPlan ? "Building, asking before edits" : "Allowed", "checkmark.circle", .green)
            case .approvedForSession:
                outcome(isPlan ? "Building, accepting edits" : "Allowed for this chat", "checkmark.circle", .green)
            case .denied:
                outcome(isPlan ? "Kept planning" : "Denied", "xmark.circle", .orange)
            case .expired:
                outcome("No longer needed", "clock", .secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: fillsWidth ? .infinity : 520, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.highlight.opacity(item.approvalState == .pending ? 0.6 : 0.2)))
    }

    private func outcome(_ text: String, _ icon: String, _ color: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.caption)
            .foregroundStyle(color)
    }
}

private struct ThoughtView: View {
    let text: String
    var isActive = false
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.top, 4)
        } label: {
            Label(isActive ? "Thinking\u{2026}" : "Thought", systemImage: "sparkle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .shimmering(isActive)
        }
    }
}

private struct PlanCard: View {
    let steps: [PlanStep]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Plan")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                HStack(spacing: 8) {
                    icon(for: step.status)
                    Text(step.step)
                        .strikethrough(step.status == "completed", color: .secondary)
                        .foregroundStyle(step.status == "completed" ? .secondary : .primary)
                        .fontWeight(step.status == "in_progress" ? .medium : .regular)
                }
                .font(.callout)
            }
        }
        .padding(12)
        .frame(maxWidth: 420, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
        .animation(.easeInOut(duration: 0.2), value: steps)
    }

    @ViewBuilder
    private func icon(for status: String) -> some View {
        switch status {
        case "completed": Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case "in_progress": Image(systemName: "circle.dotted.circle").foregroundStyle(Color.highlight)
        default: Image(systemName: "circle").foregroundStyle(.tertiary)
        }
    }
}

/// Attachments on a sent message: images as previews, other files as chips. Click to open.
/// Copies a whole message. Selecting text only reaches across one paragraph, since each is
/// its own block.
enum MessageClipboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Markdown without its marks: what the reply reads as.
    static func plain(_ markdown: String) -> String {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return markdown.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            var text = String(line)
            if let range = text.range(of: #"^\s*#{1,6}\s+"#, options: .regularExpression) { text.removeSubrange(range) }
            if let range = text.range(of: #"^\s*[-*+]\s+"#, options: .regularExpression) { text.replaceSubrange(range, with: "• ") }
            return (try? AttributedString(markdown: text, options: options)).map { String($0.characters) } ?? text
        }.joined(separator: "\n")
    }
}

/// "Copy" under a reply, which says "Copied" for a moment.
private struct CopyMessageButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            MessageClipboard.copy(text)
            copied = true
            Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
        } label: {
            Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
        }
        .buttonStyle(.plain)
        .help("Copy the whole reply")
    }
}

/// An image an agent made, shown in the reply. Click to open it for review.
private struct GeneratedImages: View {
    let item: DisplayItem
    @Environment(\.reviewImage) private var review

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(item.attachments ?? []) { image in
                if ["html", "htm", "svg"].contains(image.url.pathExtension.lowercased()) {
                    HTMLPreview(source: .file(image.url))
                } else if let media = MediaKind.of(image.url) {
                    MediaPreview(url: image.url, kind: media)
                } else {
                    picture(image)
                }
            }
            if !item.text.isEmpty {
                Text(item.text).font(.caption).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
            }
        }
    }

    private func picture(_ image: Attachment) -> some View {
                Button { review.open(image) } label: {
                    AttachmentThumbnail(attachment: image, size: 360)
                }
                .buttonStyle(.plain)
                .help("Click to view larger and mark up")
                .overlay(alignment: .bottomTrailing) {
                    HStack(spacing: 6) {
                        CopyImageButton(url: image.url)
                        Button { review.open(image) } label: {
                            Label("Review", systemImage: "pencil.and.scribble").imageOverlayPill()
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(8)
                }
                .contextMenu {
                    Button("Copy Image") { ImageClipboard.copy(image.url) }
                    Button("Open in Preview") { NSWorkspace.shared.open(image.url) }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([image.url]) }
                }
    }
}

/// Puts an image on the clipboard, ready to paste into another app.
enum ImageClipboard {
    @discardableResult
    static func copy(_ url: URL) -> Bool {
        guard let image = NSImage(contentsOf: url) else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        // PNG as well as the default TIFF, which some apps (and the web) paste more reliably.
        var ok = pasteboard.writeObjects([image])
        if let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            ok = pasteboard.setData(png, forType: .png) || ok
        }
        return ok
    }
}

/// "Copy" on an image, which says "Copied" for a moment.
private struct CopyImageButton: View {
    let url: URL
    @State private var copied = false

    var body: some View {
        Button {
            guard ImageClipboard.copy(url) else { return NSSound.beep() }
            copied = true
            Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
        } label: {
            Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc").imageOverlayPill()
        }
        .buttonStyle(.plain)
        .help("Copy the image to the clipboard")
    }
}

private extension View {
    /// The small frosted pill that sits on an image.
    func imageOverlayPill() -> some View {
        font(.caption.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.ultraThinMaterial, in: Capsule())
    }
}

private struct SentAttachments: View {
    let attachments: [Attachment]
    @Environment(\.openURL) private var openURL
    @Environment(\.reviewImage) private var review

    var body: some View {
        // GIFs and videos play; other images are thumbnails; the rest are file chips.
        let media = attachments.filter { MediaKind.of($0.url) != nil }
        let images = attachments.filter { $0.kind == .image && MediaKind.of($0.url) == nil }
        let files = attachments.filter { $0.kind != .image && MediaKind.of($0.url) == nil }
        VStack(alignment: .trailing, spacing: 6) {
            ForEach(media) { file in
                if let kind = MediaKind.of(file.url) {
                    MediaPreview(url: file.url, kind: kind).frame(maxWidth: 420)
                }
            }
            if !images.isEmpty {
                HStack(spacing: 6) {
                    ForEach(images) { image in
                        Button { review.open(image) } label: {
                            AttachmentThumbnail(attachment: image, size: images.count == 1 ? 240 : 120)
                        }
                        .buttonStyle(.plain)
                        .help(image.name)
                        .contextMenu {
                            Button("Copy Image") { ImageClipboard.copy(image.url) }
                            Button("Open in Preview") { NSWorkspace.shared.open(image.url) }
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([image.url]) }
                        }
                    }
                }
            }
            ForEach(files) { file in
                Button { openURL(file.url) } label: {
                    HStack(spacing: 6) {
                        AttachmentThumbnail(attachment: file, size: 22)
                        Text(file.name).lineLimit(1).truncationMode(.middle)
                    }
                    .font(.callout)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.7)))
                }
                .buttonStyle(.plain)
                .help("Open \(file.name)")
            }
        }
    }
}

/// A square preview of an image attachment, or the file's icon for anything else.
struct AttachmentThumbnail: View {
    let attachment: Attachment
    let size: CGFloat
    @State private var image: NSImage?
    /// The picture's shape, from its metadata, held by the placeholder while it loads.
    @State private var aspect: CGFloat?

    init(attachment: Attachment, size: CGFloat) {
        self.attachment = attachment
        self.size = size
        _image = State(initialValue: attachment.kind == .image ? TranscriptImages.cachedThumbnail(attachment.url, maxPixels: Self.pixels(size)) : nil)
    }

    /// Thumbnails are made at twice the drawn size, for retina screens.
    private static func pixels(_ size: CGFloat) -> Int { max(64, Int(size * 2)) }

    var body: some View {
        Group {
            if attachment.kind == .image, image == nil {
                RoundedRectangle(cornerRadius: size > 60 ? 10 : 5).fill(.quaternary.opacity(0.5))
                    .aspectRatio(size > 60 ? (aspect ?? 4 / 3) : 1, contentMode: .fit)
                    .frame(maxWidth: size, maxHeight: size)
                    .frame(width: size > 60 ? nil : size, height: size > 60 ? nil : size)
            } else if attachment.kind == .image, let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: size > 60 ? .fit : .fill)
                    .frame(maxWidth: size, maxHeight: size)
                    .frame(width: size > 60 ? nil : size, height: size > 60 ? nil : size)
                    .clipShape(RoundedRectangle(cornerRadius: size > 60 ? 10 : 5))
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: attachment.path))
                    .resizable()
                    .frame(width: size, height: size)
            }
        }
        .task(id: attachment.path) {
            guard attachment.kind == .image, image == nil else { return }
            let url = attachment.url
            if let size = await TranscriptImages.loadSize(of: url), size.height > 0 { aspect = size.width / size.height }
            image = await TranscriptImages.thumbnail(url, maxPixels: Self.pixels(size))
        }
    }
}

/// A soft highlight that sweeps across text while the agent is working on it.
/// Core Animation runs the sweep, so SwiftUI does no work per frame. Off with Reduce Motion.
private struct Shimmer: ViewModifier {
    var active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if active && !reduceMotion {
            content.overlay { SheenView().mask(content).allowsHitTesting(false) }
        } else {
            content
        }
    }
}

/// A bright band sliding left to right, forever, drawn by a CAGradientLayer.
private struct SheenView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { SheenNSView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class SheenNSView: NSView {
    private let gradient = CAGradientLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        gradient.colors = [NSColor.clear.cgColor, NSColor.white.withAlphaComponent(0.55).cgColor, NSColor.clear.cgColor]
        gradient.locations = [-0.4, -0.2, 0]
        layer?.addSublayer(gradient)

        let sweep = CABasicAnimation(keyPath: "locations")
        sweep.fromValue = [-0.4, -0.2, 0]
        sweep.toValue = [1, 1.2, 1.4]
        sweep.duration = 1.6
        sweep.repeatCount = .infinity
        gradient.add(sweep, forKey: "sweep")
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        gradient.frame = bounds
    }
}

extension View {
    func shimmering(_ active: Bool) -> some View { modifier(Shimmer(active: active)) }
}

/// Questions from the agent, one at a time: pick options or type an answer, then submit.
/// Once answered it shows a short summary of what you chose.
private struct QuestionCard: View {
    let item: DisplayItem
    /// The agent that asked, which picks the color of your answers' bubble.
    let agent: Backend
    let submit: ([String: [String]]?) -> Void
    @Environment(\.cardFillsWidth) private var fillsWidth
    @Environment(\.readerStyle) private var style

    @State private var index = 0
    @State private var picks: [String: Set<String>]
    @State private var other: [String: String]
    @FocusState private var otherFocused: Bool

    private var questions: [AgentQuestion] { item.questions ?? [] }

    /// Opens with Golem's suggestion already picked, if he made one.
    init(item: DisplayItem, agent: Backend, submit: @escaping ([String: [String]]?) -> Void) {
        self.item = item
        self.agent = agent
        self.submit = submit
        let seeded = Self.seed(item)
        _picks = State(initialValue: seeded.picks)
        _other = State(initialValue: seeded.other)
    }

    /// Golem's suggestion as card state: options he named are picked, anything else is typed.
    private static func seed(_ item: DisplayItem) -> (picks: [String: Set<String>], other: [String: String]) {
        var picks: [String: Set<String>] = [:], other: [String: String] = [:]
        for question in item.questions ?? [] {
            guard let values = item.suggested?[question.id] else { continue }
            let labels = Set(question.options.map(\.label))
            picks[question.id] = Set(values.filter(labels.contains))
            let typed = values.filter { !labels.contains($0) }
            if !typed.isEmpty { other[question.id] = typed.joined(separator: ", ") }
        }
        return (picks, other)
    }

    var body: some View {
        if item.approvalState == .pending, questions.indices.contains(index) {
            asking(questions[index])
                .task(id: item.suggested) { seedSuggestion() }
                .padding(14)
                .frame(maxWidth: fillsWidth ? .infinity : 560, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.highlight.opacity(0.07)))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.highlight.opacity(0.5)))
        } else {
            answered
        }
    }

    private func asking(_ question: AgentQuestion) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(question.header.isEmpty ? "Question" : question.header, systemImage: "questionmark.bubble")
                    .font(.caption.weight(.semibold)).foregroundStyle(Color.highlight)
                Spacer()
                if questions.count > 1 {
                    Text("\(index + 1) of \(questions.count)").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let suggested = item.suggested { suggestion(suggested) }
            Text(question.question).font(.body.weight(.medium)).fixedSize(horizontal: false, vertical: true)
            if question.multiSelect {
                Text("Choose any that apply").font(.caption).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(question.options.enumerated()), id: \.offset) { number, option in
                    optionRow(option, number: number + 1, question: question)
                }
            }

            Group {
                if question.isSecret {
                    SecureField("Type your answer", text: binding(for: question))
                } else {
                    TextField(question.options.isEmpty ? "Type your answer" : "Other\u{2026}", text: binding(for: question), axis: .vertical)
                        .lineLimit(1...4)
                }
            }
            .textFieldStyle(.roundedBorder)
            .focused($otherFocused)
            .onSubmit(advance)

            HStack {
                Button("Skip") { submit(nil) }.help("Don't answer; the agent carries on without these")
                Spacer()
                if index > 0 { Button("Back") { index -= 1 } }
                Button(index == questions.count - 1 ? "Submit" : "Next", action: advance)
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(HighlightButtonStyle())
                    .disabled(answer(for: question).isEmpty)
            }
            .controlSize(.small)
        }
        .id(question.id)
    }

    /// Golem's suggested answers: who, what, why, and one button to send exactly that.
    private func suggestion(_ suggested: [String: [String]]) -> some View {
        let name = item.suggestedBy ?? "Golem"
        let picked = questions.compactMap { question in
            suggested[question.id].map { (questions.count > 1 ? question.header + ": " : "") + $0.joined(separator: ", ") }
        }
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName:"sparkles").frame(width:20,height:20)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(name) suggests \(picked.joined(separator: " \u{00B7} "))")
                    .font(.callout.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let reason = item.suggestedReason, !reason.isEmpty {
                    Text(reason).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Button("Send \(name)\u{2019}s Answer") { submit(suggestedAnswers) }
                .buttonStyle(HighlightButtonStyle())
                .controlSize(.small)
                .help("Sends exactly what \(name) picked. Or choose something else below.")
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.highlight.opacity(0.10)))
    }

    /// The suggestion for every question on the card, so one tap answers them all.
    private var suggestedAnswers: [String: [String]] {
        Dictionary(uniqueKeysWithValues: questions.compactMap { question in item.suggested?[question.id].map { (question.id, $0) } })
    }

    /// Picks Golem's suggestion on the card (options he named, the rest as typed text), unless
    /// you've already started choosing.
    private func seedSuggestion() {
        let seeded = Self.seed(item)
        for question in questions where picks[question.id, default: []].isEmpty && (other[question.id] ?? "").isEmpty {
            if let set = seeded.picks[question.id] { picks[question.id] = set }
            if let typed = seeded.other[question.id] { other[question.id] = typed }
        }
    }

    private func optionRow(_ option: AgentQuestion.Option, number: Int, question: AgentQuestion) -> some View {
        let selected = picks[question.id, default: []].contains(option.label)
        return Button {
            var set = picks[question.id, default: []]
            if question.multiSelect {
                if selected { set.remove(option.label) } else { set.insert(option.label) }
            } else {
                set = selected ? [] : [option.label]
            }
            // Selecting only marks the choice; Next or Submit sends it.
            picks[question.id] = set
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: question.multiSelect ? (selected ? "checkmark.square.fill" : "square") : (selected ? "largecircle.fill.circle" : "circle"))
                    .foregroundStyle(selected ? Color.highlight : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.label)
                    if !option.detail.isEmpty, option.detail != option.label {
                        Text(option.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Color.highlight.opacity(0.14) : Color.primary.opacity(0.04)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Your answers, styled and placed like your own messages: right-aligned, in the bubble
    /// color of the agent that asked.
    private var answered: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Label(item.approvalState == .approved ? "Answered" : item.approvalState == .denied ? "Skipped" : "No longer needed",
                  systemImage: item.approvalState == .approved ? "checkmark.circle" : "questionmark.bubble")
                .font(.caption2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(questions) { question in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(question.question).font(style.secondary).foregroundStyle(.secondary)
                        if let answer = item.answers?[question.id] {
                            Text(question.isSecret ? "\u{2022}\u{2022}\u{2022}\u{2022}" : answer.joined(separator: ", "))
                                .font(style.body.weight(.medium))
                        }
                    }
                }
            }
            .lineSpacing(style.lineSpacing)
            .textSelection(.enabled)
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 14).fill(style.color(for: agent).opacity(style.bubbleStrength)))
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 80)
        .padding(.top, 6)
    }

    private func binding(for question: AgentQuestion) -> Binding<String> {
        Binding(get: { other[question.id] ?? "" }, set: { other[question.id] = $0 })
    }

    /// Picked options, plus anything typed.
    private func answer(for question: AgentQuestion) -> [String] {
        let chosen = question.options.map(\.label).filter { picks[question.id, default: []].contains($0) }
        let typed = (other[question.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return chosen + (typed.isEmpty ? [] : [typed])
    }

    private func advance() {
        guard questions.indices.contains(index), !answer(for: questions[index]).isEmpty else { return }
        if index < questions.count - 1 {
            index += 1
        } else {
            submit(Dictionary(uniqueKeysWithValues: questions.map { ($0.id, answer(for: $0)) }))
        }
    }
}

/// Cards in the tray above the message box span its full width instead of their usual cap.
private struct CardFillsWidthKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var cardFillsWidth: Bool {
        get { self[CardFillsWidthKey.self] }
        set { self[CardFillsWidthKey.self] = newValue }
    }
}

/// A "!" command you ran: the command, its output (the last lines, with the rest one click
/// away), and the exit code when it failed.
private struct ShellBlock: View {
    let item: DisplayItem
    @Environment(\.readerStyle) private var style
    @State private var expanded = false

    private var lines: [Substring] { (item.detail ?? "").split(separator: "\n", omittingEmptySubsequences: false) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("$ " + item.text).font(style.code.weight(.semibold)).textSelection(.enabled).lineLimit(2)
                Spacer(minLength: 8)
                switch item.toolState {
                case .running: ProgressView().controlSize(.small)
                case .done: Image(systemName: "checkmark").font(.caption).foregroundStyle(.secondary)
                case .failed: Text("failed").font(.caption.weight(.medium)).foregroundStyle(.orange)
                }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.detail ?? "", forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .help("Copy output")
            }
            let output = (item.detail ?? "").trimmingCharacters(in: .newlines)
            if !output.isEmpty {
                let shown = expanded || lines.count <= 14 ? output : lines.suffix(14).joined(separator: "\n")
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(shown).font(style.code).foregroundStyle(.secondary).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if lines.count > 14 {
                    Button(expanded ? "Show less" : "Show all \(lines.count) lines") { expanded.toggle() }
                        .buttonStyle(.link).font(.caption)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
    }
}
