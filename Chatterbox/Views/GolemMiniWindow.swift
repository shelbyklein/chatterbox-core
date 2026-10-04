#if GOLEM_APP
import AppKit
import Observation
import SwiftUI

/// One native panel for the existing assistant. It never owns an agent or a transcript.
@MainActor
@Observable
final class GolemMiniWindow: NSObject, NSWindowDelegate {
    static let visibleKey = "golemMiniVisible"
    static let expandedFrameKey = "golemMiniExpandedFrame"
    static let avatarFrameKey = "golemMiniAvatarFrame"
    static let collapsedKey = "dotCollapsed"
    static let sizeKey = "golemMiniSize"
    static let sizes: [(label: String, scale: CGFloat)] = [("Small", 0.75), ("Medium", 1), ("Large", 1.4), ("Extra Large", 1.85)]
    /// How big Golem is on screen, minimized and open.
    var scale: CGFloat = CGFloat(AppPreferences.defaults.object(forKey: GolemMiniWindow.sizeKey) as? Double ?? 1)
    /// Minimized, he stays the size he is open, with room for his pill underneath.
    var avatarSize: CGFloat { characterSize + 12 }
    /// The bar under him: the dot or pill when minimized, the message box when open. Same
    /// height either way, so he never moves between states.
    static let barHeight: CGFloat = 50
    static let transition = 0.34
    var collapsedSize: NSSize { NSSize(width: max(characterSize + 24, 170), height: 12 + Self.barHeight - 10 * scale + characterSize + 12) }
    /// Golem's middle in a panel of this size, from its bottom-left: the layout is bottom-up.
    func characterCenter(in size: NSSize) -> CGPoint { CGPoint(x: size.width / 2, y: 12 + Self.barHeight + gapBelow + characterSize / 2) }
    /// His frame has empty room around him, so the bubble and the bar sit into it a little.
    var gapBelow: CGFloat { -10 * scale }
    var bubbleOverlap: CGFloat { 26 * scale }
    /// Golem's middle in the minimized panel, from its bottom-left.
    var collapsedCenter: CGPoint { characterCenter(in: collapsedSize) }
    var characterSize: CGFloat { 124 * scale }
    /// Where Golem's middle sits in the open panel, from its bottom-left (measured as it draws).
    @ObservationIgnored var characterCenter: CGPoint?
    /// Where Golem should end up on screen once the open layout has measured him.
    @ObservationIgnored private var pendingCenter: NSPoint?

    private func landCharacter() {
        guard let target = pendingCenter, let offset = characterCenter, let panel, !collapsed else { return }
        pendingCenter = nil
        let origin = NSPoint(x: target.x - offset.x, y: target.y - offset.y)
        guard abs(origin.x - panel.frame.minX) > 0.5 || abs(origin.y - panel.frame.minY) > 0.5 else { return }
        configure(frame: NSRect(origin: origin, size: panel.frame.size))
    }
    private(set) var collapsed: Bool
    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private(set) var panel: GolemPanel?
    @ObservationIgnored private var expandedSize = NSSize(width: 400, height: 420)
    @ObservationIgnored private var positioning = false
    @ObservationIgnored private var screenObserver: NSObjectProtocol?
    @ObservationIgnored private var hoveredReply: UUID?
    @ObservationIgnored private var acknowledgement: Task<Void, Never>?

    /// One hover region covers the bubble, body and composer, including their gaps.
    /// Only a completed reply actually hovered by the reader can be acknowledged.
    func replyHoverChanged(inside: Bool, replyID: UUID?) {
        acknowledgement?.cancel()
        acknowledgement = nil
        if inside {
            hoveredReply = collapsed ? nil : replyID
            return
        }
        guard !collapsed, let replyID, hoveredReply == replyID else {
            hoveredReply = nil
            return
        }
        hoveredReply = nil
        acknowledgement = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            guard let self, !Task.isCancelled, !self.collapsed, NSApp.modalWindow == nil,
                  let dot = self.model?.dot, !dot.isRunning, !dot.isWaitingOnYou,
                  dot.items.last(where: { $0.kind == .assistant && $0.phase != .commentary && !$0.text.isEmpty })?.id == replyID
            else { return }
            Attention.shared.markSeen(dot.id)
            self.setCollapsed(true)
        }
    }

    private func cancelAcknowledgement() {
        acknowledgement?.cancel()
        acknowledgement = nil
        hoveredReply = nil
    }

    init(model: AppModel, defaults: UserDefaults = AppPreferences.defaults) {
        self.model = model
        self.defaults = defaults
        collapsed = defaults.bool(forKey: Self.collapsedKey)
        super.init()
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                 object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.keepOnScreen() }
        }
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }

    var isReading: Bool { panel?.isVisible == true && panel?.isKeyWindow == true && !collapsed }

    func show() {
        guard let model else { return }
        let dot = model.ensureDot()
        if panel == nil {
            let panel = GolemPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.delegate = self
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.isMovableByWindowBackground = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.animationBehavior = .none
            panel.becomesKeyOnlyIfNeeded = true
            panel.title = dot.title
            let host = NSHostingView(rootView: GolemMiniContent(session: dot, controller: self).environment(model))
            // Keep window clipping in AppKit, including any WebKit preview layers.
            host.wantsLayer = true
            host.layer?.cornerRadius = 14
            host.layer?.masksToBounds = true
            host.sizingOptions = []
            panel.contentView = host
            self.panel = panel
            if let saved = savedFrame(Self.expandedFrameKey) { expandedSize = saved.size }
            let area = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
            let size = collapsed ? collapsedSize : expandedSize
            let fallback = NSRect(x: area.maxX - size.width - 24, y: area.minY + 24, width: size.width, height: size.height)
            configure(frame: savedFrame(collapsed ? Self.avatarFrameKey : Self.expandedFrameKey) ?? fallback)
        }
        keepOnScreen()
        if collapsed { panel?.orderFrontRegardless() }
        else { panel?.makeKeyAndOrderFront(nil) }
        if isReading { Attention.shared.markSeen(dot.id) }
    }

    func hide() {
        cancelAcknowledgement()
        rememberFrame()
        panel?.orderOut(nil)
        // Release hosted chat/media views while hidden. Drafts belong to the session.
        panel?.contentView = nil
        panel = nil
    }

    /// Golem's middle, in the open panel: measured, or where the layout puts him.
    private var openCharacterCenter: CGPoint { characterCenter(in: expandedSize) }

    func toggleCollapsed() { setCollapsed(!collapsed) }

    /// Opens or minimizes in one motion: the window glides to its new size around Golem, who
    /// stays exactly where he is, while the bar under him morphs and the bubble rises.
    func setCollapsed(_ value: Bool) {
        guard value != collapsed, let panel else { return }
        cancelAcknowledgement()
        if !collapsed { expandedSize = panel.frame.size }
        rememberFrame()
        let here = characterCenter(in: panel.frame.size)
        let center = NSPoint(x: panel.frame.minX + here.x, y: panel.frame.minY + here.y)
        let size = value ? collapsedSize : expandedSize
        let there = characterCenter(in: size)
        let frame = NSRect(origin: NSPoint(x: center.x - there.x, y: center.y - there.y), size: size)
        withAnimation(.smooth(duration: Self.transition)) { collapsed = value }
        defaults.set(value, forKey: Self.collapsedKey)
        configure(frame: frame, animated: true)
        if value { panel.resignKey(); panel.orderFrontRegardless() }
        else { panel.makeKeyAndOrderFront(nil) }
        if isReading, let dot = model?.dot { Attention.shared.markSeen(dot.id) }
    }

    func closeMini() { model?.showingDot = false }

    /// A new size keeps Golem centered where he is.
    func setScale(_ value: CGFloat) {
        guard value != scale else { return }
        defaults.set(Double(value), forKey: Self.sizeKey)
        guard let panel else { scale = value; return }
        let here = characterCenter(in: panel.frame.size)
        let center = NSPoint(x: panel.frame.minX + here.x, y: panel.frame.minY + here.y)
        let grow = (124 * value) - characterSize
        withAnimation(.smooth(duration: Self.transition)) { scale = value }
        if !collapsed { expandedSize.height = max(360, expandedSize.height + grow) }
        let size = collapsed ? collapsedSize : expandedSize
        let there = characterCenter(in: size)
        configure(frame: NSRect(origin: NSPoint(x: center.x - there.x, y: center.y - there.y), size: size), animated: true)
    }

    func openFullChat() {
        guard let model else { return }
        model.openDot()
        model.showingSettings = false
        model.webPage = nil
        revealMainWindow()
    }

    /// Follow-up links from the mini must also reveal the main window, even in another app.
    func revealMainWindow() {
        guard let model else { return }
        if let window = model.mainChatWindow, window.isVisible || window.isMiniaturized {
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
        } else {
            model.revealMainChatWindow?()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func configure(frame: NSRect, animated: Bool = false) {
        guard let panel else { return }
        positioning = true
        panel.acceptsTyping = !collapsed
        panel.hasShadow = false
        if collapsed { panel.styleMask.remove(.resizable) } else { panel.styleMask.insert(.resizable) }
        let extra = characterSize - 124
        let minSize = collapsed ? collapsedSize : NSSize(width: 320, height: 360 + max(0, extra))
        let maxSize = collapsed ? collapsedSize : NSSize(width: 560, height: 480 + max(0, extra))
        var fitted = frame
        fitted.size.width = min(max(fitted.width, minSize.width), maxSize.width)
        fitted.size.height = min(max(fitted.height, minSize.height), maxSize.height)
        let target = Self.clamped(fitted, to: NSScreen.screens.map(\.visibleFrame))
        let settle = { [weak self] in
            panel.minSize = minSize
            panel.maxSize = maxSize
            self?.positioning = false
            self?.rememberFrame()
        }
        guard animated else {
            panel.minSize = minSize; panel.maxSize = maxSize
            panel.setFrame(target, display: true)
            settle()
            return
        }
        // Let the frame pass through any size on the way.
        panel.minSize = NSSize(width: 1, height: 1)
        panel.maxSize = NSSize(width: 10_000, height: 10_000)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.transition
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
            context.allowsImplicitAnimation = true
            panel.animator().setFrame(target, display: true)
        }, completionHandler: { MainActor.assumeIsolated { settle() } })
    }

    func keepOnScreen() {
        guard let panel else { return }
        panel.setFrame(Self.clamped(panel.frame, to: NSScreen.screens.map(\.visibleFrame)), display: true)
        rememberFrame()
    }

    /// Restore onto an attached display, even when the previous display was unplugged.
    static func clamped(_ frame: NSRect, to screens: [NSRect]) -> NSRect {
        guard let screen = screens.max(by: { a, b in
            let x = a.intersection(frame), y = b.intersection(frame)
            return (x.isNull ? 0 : x.width * x.height) < (y.isNull ? 0 : y.width * y.height)
        }) else { return frame }
        let size = NSSize(width: min(frame.width, screen.width), height: min(frame.height, screen.height))
        return NSRect(x: min(max(frame.minX, screen.minX), screen.maxX - size.width),
                      y: min(max(frame.minY, screen.minY), screen.maxY - size.height), width: size.width, height: size.height)
    }

    private func savedFrame(_ key: String) -> NSRect? {
        guard let string = defaults.string(forKey: key) else { return nil }
        let frame = NSRectFromString(string)
        guard frame.width.isFinite, frame.height.isFinite, frame.minX.isFinite, frame.minY.isFinite,
              frame.width >= 60, frame.height >= 60 else { return nil }
        return frame
    }

    private func rememberFrame() {
        guard !positioning, let panel else { return }
        defaults.set(NSStringFromRect(panel.frame), forKey: collapsed ? Self.avatarFrameKey : Self.expandedFrameKey)
        if !collapsed { expandedSize = panel.frame.size }
    }

    func windowDidMove(_ notification: Notification) { rememberFrame() }
    func windowDidResize(_ notification: Notification) { rememberFrame() }
    func windowDidEndLiveResize(_ notification: Notification) { keepOnScreen() }
    func windowDidBecomeKey(_ notification: Notification) {
        if !collapsed, let dot = model?.dot { Attention.shared.markSeen(dot.id) }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { closeMini(); return false }
}

final class GolemPanel: NSPanel {
    var acceptsTyping = true
    override var canBecomeKey: Bool { acceptsTyping }
    override var canBecomeMain: Bool { false }
}

/// The mini, open or minimized, as one view so every change is a single motion. It's laid
/// out from the bottom: the bar (dot, pill, or message box), then Golem, then his bubble.
/// The bar is the same height in every state, so Golem never moves.
private struct GolemMiniContent: View {
    let session: ChatSession
    let controller: GolemMiniWindow
    @AppStorage(Theme.backgroundKey) private var background = "standard"
    @AppStorage(Theme.schemeKey) private var scheme = "system"
    @AppStorage(Theme.highlightKey) private var highlight = "default"
    @AppStorage("golemBubbleTextSize") private var bubbleTextSize = 14.0
    @AppStorage("golemBubbleStyle") private var bubbleStyle = "solid"
    @AppStorage("golemBubbleShow") private var bubbleShow = true
    @Namespace private var bar
    @State private var hovering = false
    @State private var draft: String
    @State private var attachments: [Attachment]
    @State private var attachmentError: String?
    @State private var showingModels = false
    @State private var composerWidth: CGFloat = 300
    @State private var focused = false

    init(session: ChatSession, controller: GolemMiniWindow) {
        self.session = session
        self.controller = controller
        _draft = State(initialValue: session.draft)
        _attachments = State(initialValue: session.draftAttachments)
    }

    private var open: Bool { !controller.collapsed }
    private var unread: Int { Attention.shared.dotUnreadCount(session) }
    private var latestReply: DisplayItem? {
        session.items.last { $0.kind == .assistant && $0.phase != .commentary && !$0.text.isEmpty }
    }
    private var updateText: String? {
        if session.isWaitingOnYou { return session.lastActionSummary }
        if session.isRunning { return "Replying\u{2026}" }
        return latestReply?.text
    }
    private var canSend: Bool { !session.isRestartingThread && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty) }
    private var spring: Animation { .smooth(duration: GolemMiniWindow.transition) }
    private var acknowledgementReply: UUID? {
        guard open, bubbleShow, !showingModels, !session.isRestartingThread, !session.isRunning, !session.isWaitingOnYou else { return nil }
        return latestReply?.id
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                if open, bubbleShow, let text = updateText {
                    bubble(text, maxHeight: max(48, min(140, geometry.size.height - 260)))
                        // Tucked down behind his top stone, like a speech bubble.
                        .padding(.bottom, -controller.bubbleOverlap)
                        .zIndex(0)
                        .transition(.asymmetric(insertion: .scale(scale: 0.6, anchor: .bottom).combined(with: .opacity),
                                                removal: .scale(scale: 0.8, anchor: .bottom).combined(with: .opacity)))
                }
                if open, !attachments.isEmpty { attachmentStrip.padding(.bottom, 8).transition(.opacity) }
                if open, let attachmentError { Text(attachmentError).font(.caption).foregroundStyle(.orange).lineLimit(2).padding(.bottom, 8) }
                if open, session.isRestartingThread || session.threadRestartStatus != nil {
                    ThreadRestartStatus(session: session).padding(.bottom, 8)
                }
                character
                    .padding(.bottom, controller.gapBelow)
                    .zIndex(1)
                bottomBar.frame(height: GolemMiniWindow.barHeight).zIndex(2)
            }
            .padding(12)
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .bottom)
        }
        .preferredColorScheme(Theme.colorScheme(background: background, scheme: scheme))
        .tint(highlight == "default" ? nil : Color.highlight)
        .onHover { inside in
            withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) { hovering = inside }
            controller.replyHoverChanged(inside: inside, replyID: acknowledgementReply)
        }
        .onChange(of: acknowledgementReply) { _, replyID in
            controller.replyHoverChanged(inside: hovering, replyID: hovering ? replyID : nil)
        }
        .onChange(of: session.title) { _, title in controller.panel?.title = title }
        .onChange(of: draft) { _, value in session.draft = value }
        .onChange(of: attachments) { _, value in session.draftAttachments = value }
        .onChange(of: controller.collapsed) { _, collapsed in
            if collapsed { focused = false }
            if !collapsed { DispatchQueue.main.asyncAfter(deadline: .now() + GolemMiniWindow.transition) {
                if !controller.collapsed { focused = true }
            } }
        }
        .onChange(of: latestReply?.id) { if controller.isReading { Attention.shared.markSeen(session.id) } }
        .onChange(of: ChatCommands.shared.modelPopoverRequests) {
            if showingModels || controller.panel?.isKeyWindow == true { showingModels.toggle() }
        }
        .popover(isPresented: $showingModels) {
            ModelPopover(session: session) { showingModels = false }
                .task {
                    await ClaudeModels.shared.refresh()
                    if CodexAppServer.shared.models.isEmpty { try? await CodexAppServer.shared.refreshModels() }
                }
        }
        .onKeyPress(.escape) {
            if session.canStop { session.interrupt(); return .handled }
            if open { controller.setCollapsed(true); return .handled }
            return .ignored
        }
    }

    // MARK: - Golem

    private var character: some View {
        GolemAnimated(mood: GolemAvatar.mood(of: session))
            .frame(width: controller.characterSize, height: controller.characterSize)
            .background(Circle().fill(session.isWaitingOnYou ? Color.yellow.opacity(0.18) : .clear).padding(4))
            // Watching you type: he leans and turns toward the end of your text.
            .rotationEffect(.degrees(gaze * 9), anchor: .bottom)
            .offset(x: gaze * 14 * controller.scale)
            .animation(.spring(response: 0.45, dampingFraction: 0.7), value: gaze)
            .overlay {
                // Click him to open or minimize; drag to move him; right-click for more.
                MiniDragRegion(onClick: controller.toggleCollapsed, onDragEnd: controller.keepOnScreen,
                               onOpenFull: controller.openFullChat, onHide: controller.closeMini,
                               sizes: GolemMiniWindow.sizes.map { ($0.label, $0.scale) }, currentScale: controller.scale,
                               onSize: controller.setScale)
            }
            .help(open ? "Click to minimize \(session.title). Drag to move." : "Click to talk to \(session.title). Drag to move; right-click for more.")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(session.title)\(unread > 0 ? ", \(unread) unread" : "")")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { controller.toggleCollapsed() }
    }

    /// -1 (looking left) … 1 (looking right): where the end of the draft sits in the box,
    /// while you're typing; 0 otherwise.
    private var gaze: CGFloat {
        guard open, focused, !draft.isEmpty else { return 0 }
        let lastLine = draft.split(separator: "\n", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        let width = (lastLine as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 14)]).width
        let field = max(composerWidth - 130, 80)
        let caret = 46 + width.truncatingRemainder(dividingBy: field)
        return max(-1, min(1, (caret / max(composerWidth, 1)) * 2 - 1))
    }

    // MARK: - The bar: dot → pill → message box, one shape morphing

    @ViewBuilder
    private var bottomBar: some View {
        if open {
            composer
        } else if hovering {
            quickActions
        } else {
            dot
        }
    }

    private func barShape(_ fill: some ShapeStyle) -> some View {
        Capsule().fill(fill).matchedGeometryEffect(id: "bar", in: bar)
    }

    private var dot: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { controller.setCollapsed(false) }
    }

    private var quickActions: some View {
        HStack(spacing: 0) {
            Button { controller.setCollapsed(false) } label: {
                Image(systemName: "square.and.pencil").font(.system(size: 15, weight: .medium)).frame(width: 48, height: 36)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).help("Message \(session.title)")
            Divider().frame(height: 18)
            Button(action: controller.openFullChat) {
                Image(systemName: "arrow.up.right").font(.system(size: 14, weight: .medium)).frame(width: 48, height: 36)
                    .overlay(alignment: .topTrailing) {
                        if unread > 0 { Circle().fill(.white).frame(width: 6, height: 6).padding(7) }
                    }
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).help(unread > 0 ? "\(unread) new: open \(session.title)" : "Open \(session.title)")
        }
        .foregroundStyle(.primary)
        .background(barShape(Color(nsColor: .windowBackgroundColor)))
        .overlay(Capsule().strokeBorder(.primary.opacity(0.15)))
        .transition(.opacity)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var composer: some View {
        HStack(alignment: .center, spacing: 8) {
            Menu {
                RestartThreadControl(session: session)
                Divider()
                Button("Attach Files\u{2026}", action: chooseFiles)
                Button("Paste Image") { if let files = Attachments.fromPasteboard() { attachments += files } }
                Divider()
                Button("Model and Effort\u{2026}") { showingModels = true }
                Menu("\(session.title)'s Size") { sizeOptions }
                Button("Open Full Chat", action: controller.openFullChat)
                Button("Hide Mini", action: controller.closeMini)
            } label: {
                Image(systemName: "plus").font(.system(size: 16, weight: .medium))
                    .frame(width: 30, height: 30).contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .foregroundStyle(.secondary)
            .accessibilityLabel("More options")
            // Up to four lines, then scrolls. Return sends, Shift-Return starts a new line, ⌘↩ sends now.
            ComposerBox(text: $draft, placeholder: "Message \(session.title)", isFocused: $focused,
                        font: .systemFont(ofSize: 14), maxHeight: 4 * 18,
                        onKey: { key, modifiers in
                            guard key == .return, modifiers.contains(.command) else { return false }
                            send(now: true)
                            return true
                        },
                        onSubmit: { send() })
                .frame(maxWidth: .infinity).padding(.vertical, 6)
            if session.canStop && !canSend {
                Button { session.interrupt() } label: { Image(systemName: "stop.fill").frame(width: 30, height: 30) }
                    .buttonStyle(.plain).accessibilityLabel("Stop").help("Stop (Esc)")
            } else {
                Button { send() } label: {
                    Image(systemName: "arrow.up").font(.system(size: 14, weight: .semibold))
                        .frame(width: 30, height: 30)
                        .foregroundStyle(canSend ? Color.onHighlight : Color.secondary)
                        .background(Circle().fill(canSend ? Color.highlight : Color.primary.opacity(0.06)))
                }.buttonStyle(.plain).disabled(!canSend).accessibilityLabel("Send")
            }
            Button { controller.setCollapsed(true) } label: {
                Image(systemName: "chevron.down").font(.system(size: 12, weight: .semibold)).frame(width: 24, height: 30)
            }.buttonStyle(.plain).foregroundStyle(.secondary).help("Minimize (Esc)").accessibilityLabel("Minimize")
        }
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { composerWidth = $0 }
        .background(barShape(Color(nsColor: .windowBackgroundColor)))
        .overlay(Capsule().strokeBorder(.primary.opacity(0.12)))
        .transition(.opacity)
    }

    @ViewBuilder private var sizeOptions: some View {
        ForEach(GolemMiniWindow.sizes, id: \.label) { size in
            Button { controller.setScale(size.scale) } label: {
                if controller.scale == size.scale { Label(size.label, systemImage: "checkmark") } else { Text(size.label) }
            }
        }
    }

    // MARK: - His bubble

    private var bubbleFill: AnyShapeStyle {
        switch bubbleStyle {
        case "glass": AnyShapeStyle(.regularMaterial)
        case "tinted": AnyShapeStyle(Color.highlight.opacity(0.18))
        default: AnyShapeStyle(Color(nsColor: .windowBackgroundColor))
        }
    }

    private func bubble(_ text: String, maxHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(session.isWaitingOnYou ? "Needs you" : session.isRunning ? "Working" : session.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(session.isWaitingOnYou ? Color.yellow : .secondary)
                Spacer()
                Button(action: controller.openFullChat) {
                    Label(session.isWaitingOnYou ? "Answer in chat" : "Open chat", systemImage: "arrow.up.right").font(.system(size: 11))
                }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
            ScrollView {
                Text(MessageClipboard.plain(String(text.prefix(8_000))))
                    .font(.system(size: bubbleTextSize))
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxHeight: maxHeight)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 20).fill(bubbleFill))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.primary.opacity(0.12)))
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(attachments) { file in
                    Button { attachments.removeAll { $0.id == file.id } } label: {
                        Label(file.name, systemImage: "xmark.circle.fill").lineLimit(1)
                    }.buttonStyle(.plain).help("Remove \(file.name)")
                }
            }.font(.caption).padding(8)
        }
        .frame(height: 30)
        .background(.regularMaterial, in: Capsule())
    }

    private func send(now: Bool = false) {
        guard canSend else { return }
        let text = draft, files = attachments
        draft = ""; attachments = []; session.draft = ""; session.draftAttachments = []
        if now { session.sendNow(text, attachments: files) } else { session.send(text, attachments: files) }
    }

    private func chooseFiles() {
        let picker = NSOpenPanel()
        picker.allowsMultipleSelection = true
        picker.canChooseDirectories = false
        guard picker.runModal() == .OK else { return }
        do { attachments += try picker.urls.map(Attachments.importFile); attachmentError = nil }
        catch { attachmentError = error.localizedDescription }
    }
}

/// AppKit owns drag gestures, so selecting chat text cannot move the window and a drag
/// of the avatar never also expands it. A nonactivating panel accepts the first click.
struct MiniDragRegion: NSViewRepresentable {
    var onClick: (() -> Void)?
    var onDragEnd: (() -> Void)?
    var onOpenFull: (() -> Void)?
    var onHide: (() -> Void)?
    var sizes: [(String, CGFloat)] = []
    var currentScale: CGFloat = 1
    var onSize: ((CGFloat) -> Void)?

    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {
        view.onClick = onClick; view.onDragEnd = onDragEnd
        view.onOpenFull = onOpenFull; view.onHide = onHide
        view.sizes = sizes; view.currentScale = currentScale; view.onSize = onSize
    }

    final class DragView: NSView {
        var onClick: (() -> Void)?
        var onDragEnd: (() -> Void)?
        var onOpenFull: (() -> Void)?
        var onHide: (() -> Void)?
        var sizes: [(String, CGFloat)] = []
        var currentScale: CGFloat = 1
        var onSize: ((CGFloat) -> Void)?
        private var start: NSPoint?
        private var origin = NSPoint.zero
        private var dragged = false
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            start = window.convertPoint(toScreen: event.locationInWindow)
            origin = window.frame.origin; dragged = false
        }
        override func mouseDragged(with event: NSEvent) {
            guard let start, let window else { return }
            let point = window.convertPoint(toScreen: event.locationInWindow)
            let dx = point.x - start.x, dy = point.y - start.y
            if hypot(dx, dy) > 3 { dragged = true }
            if dragged { window.setFrameOrigin(NSPoint(x: origin.x + dx, y: origin.y + dy)) }
        }
        override func mouseUp(with event: NSEvent) {
            guard start != nil else { return }
            start = nil
            if dragged { onDragEnd?() } else { onClick?() }
        }
        override func rightMouseDown(with event: NSEvent) {
            guard onClick != nil else { return }
            let menu = NSMenu()
            for (title, action) in [("Open Chat", #selector(openChat)), ("Open in Chatterbox", #selector(openFull)), ("Hide Mini", #selector(hideMini))] {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = self; menu.addItem(item)
            }
            if !sizes.isEmpty {
                menu.addItem(.separator())
                let sizeMenu = NSMenu()
                for (index, size) in sizes.enumerated() {
                    let item = NSMenuItem(title: size.0, action: #selector(pickSize(_:)), keyEquivalent: "")
                    item.target = self; item.tag = index; item.state = size.1 == currentScale ? .on : .off
                    sizeMenu.addItem(item)
                }
                let parent = NSMenuItem(title: "Size", action: nil, keyEquivalent: "")
                parent.submenu = sizeMenu
                menu.addItem(parent)
            }
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
        @objc private func openChat() { onClick?() }
        @objc private func openFull() { onOpenFull?() }
        @objc private func hideMini() { onHide?() }
        @objc private func pickSize(_ item: NSMenuItem) { onSize?(sizes[item.tag].1) }
    }
}

/// Find the hosting window for main-window activation and per-window keyboard handling.

#endif
