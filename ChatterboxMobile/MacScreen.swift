#if canImport(RoyalVNCKit) && !GOLEM_APP
import RoyalVNCKit
import Security
import SwiftUI
import UIKit

// Mac Screen: see and control the Mac from the phone, through macOS's own Screen Sharing (VNC
// with Apple's sign-in), over the address the app already reaches the Mac at (home Wi-Fi, or
// Tailscale away). See plans/mobile-remote-desktop.md.

/// The Mac's user name and password for Screen Sharing, kept in this phone's Keychain only.
enum MacScreenLogin {
    private static let service = "com.shelbyklein.Chatterbox.macscreen"
    private struct Stored: Codable { var user: String; var password: String }

    static func load() -> (user: String, password: String)? {
        var value: CFTypeRef?
        let status = SecItemCopyMatching([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: "login",
                                          kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne] as CFDictionary, &value)
        guard status == errSecSuccess, let data = value as? Data, let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return nil }
        return (stored.user, stored.password)
    }

    static func save(user: String, password: String) {
        forget()
        guard let data = try? JSONEncoder().encode(Stored(user: user, password: password)) else { return }
        SecItemAdd([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: "login", kSecValueData: data,
                    kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] as CFDictionary, nil)
    }

    static func forget() {
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: "login"] as CFDictionary)
    }
}

/// One Screen Sharing connection and what it shows.
@MainActor
@Observable
final class MacScreenSession: NSObject {
    enum State: Equatable { case idle, signingIn, connecting, connected, failed(String) }
    enum Quality: String, CaseIterable, Identifiable {
        case sharp, fast
        var id: String { rawValue }
        var title: String { self == .sharp ? "Sharper" : "Faster" }
    }

    private(set) var state = State.idle
    private(set) var image: UIImage?
    private(set) var screenSize = CGSize.zero
    var quality: Quality = Quality(rawValue: UserDefaults.standard.string(forKey: "macScreenQuality") ?? "") ?? .sharp {
        didSet { UserDefaults.standard.set(quality.rawValue, forKey: "macScreenQuality"); if state == .connected { reconnect() } }
    }

    @ObservationIgnored private var connection: VNCConnection?
    @ObservationIgnored private var host = ""
    @ObservationIgnored private var attempts = 0
    /// Frames arrive on RoyalVNC's own queue; one redraw at a time is queued for the main thread.
    @ObservationIgnored nonisolated(unsafe) private var redrawQueued = false
    @ObservationIgnored private let redrawLock = NSLock()

    /// Signs in with the saved login, if there is one; otherwise asks for it.
    func connect(to host: String) {
        self.host = host
        guard MacScreenLogin.load() != nil else { state = .signingIn; return }
        attempts = 0
        open()
    }

    func reconnect() {
        disconnect()
        attempts = 0
        open()
    }

    func disconnect() {
        connection?.delegate = nil
        connection?.disconnect()
        connection = nil
        if state != .signingIn { state = .idle }
    }

    func signIn(user: String, password: String) {
        MacScreenLogin.save(user: user, password: password)
        attempts = 0
        open()
    }

    func signOut() {
        disconnect()
        MacScreenLogin.forget()
        image = nil
        state = .signingIn
    }

    private func open() {
        guard !host.isEmpty else { state = .failed("Chatterbox doesn't know the Mac's address yet. Connect to the Mac first."); return }
        attempts += 1
        state = .connecting
        let settings = VNCConnection.Settings(isDebugLoggingEnabled: false, hostname: host, port: 5900, isShared: true,
                                              isScalingEnabled: false, useDisplayLink: false, inputMode: .none,
                                              isClipboardRedirectionEnabled: false,
                                              colorDepth: quality == .sharp ? .depth24Bit : .depth16Bit, frameEncodings: .default)
        let connection = VNCConnection(settings: settings)
        connection.delegate = self
        self.connection = connection
        connection.connect()
    }

    fileprivate func ended(_ error: Error?, from closing: VNCConnection) {
        guard closing === connection else { return }
        connection = nil
        let message = "\(error.map { String(describing: $0) } ?? "")"
        // RoyalVNC sometimes fails a good sign-in (its issue #42): try twice more before saying so.
        if message.contains("closedDuringHandshake"), attempts < 3 {
            open()
            return
        }
        if message.contains("closedDuringHandshake") || message.lowercased().contains("authentication") {
            state = .failed("The Mac didn't accept that user name and password.")
        } else if message.isEmpty {
            state = .idle
        } else {
            state = .failed("Couldn't reach the Mac's Screen Sharing (\(host)). It needs to be on: System Settings → General → Sharing → Screen Sharing.")
        }
    }

    fileprivate func show(_ frame: VNCFramebuffer) {
        guard let cgImage = frame.cgImage else { return }
        image = UIImage(cgImage: cgImage)
        screenSize = CGSize(width: Int(frame.size.width), height: Int(frame.size.height))
        if state != .connected { state = .connected }
    }

    // MARK: - Input (framebuffer pixels)

    private func xy(_ point: CGPoint) -> (UInt16, UInt16) {
        let x = min(max(point.x, 0), max(screenSize.width - 1, 0)), y = min(max(point.y, 0), max(screenSize.height - 1, 0))
        return (UInt16(x), UInt16(y))
    }

    func click(at point: CGPoint, button: VNCMouseButton = .left, count: Int = 1) {
        let (x, y) = xy(point)
        for _ in 0..<count {
            connection?.mouseButtonDown(button, x: x, y: y)
            connection?.mouseButtonUp(button, x: x, y: y)
        }
    }

    func press(at point: CGPoint) { let (x, y) = xy(point); connection?.mouseButtonDown(.left, x: x, y: y) }
    func move(to point: CGPoint) { let (x, y) = xy(point); connection?.mouseMove(x: x, y: y) }
    func release(at point: CGPoint) { let (x, y) = xy(point); connection?.mouseButtonUp(.left, x: x, y: y) }

    func scroll(at point: CGPoint, up: Bool, steps: UInt32) {
        let (x, y) = xy(point)
        connection?.mouseWheel(up ? .up : .down, x: x, y: y, steps: steps)
    }

    /// Typed text, with any held modifiers around each key.
    func type(_ text: String, modifiers: [VNCKeyCode] = []) {
        for character in text {
            let codes = character == "\n" ? [VNCKeyCode.return] : VNCKeyCode.keyCodesFrom(characters: String(character))
            press(codes, modifiers: modifiers)
        }
    }

    func press(_ keys: [VNCKeyCode], modifiers: [VNCKeyCode] = []) {
        guard let connection else { return }
        for modifier in modifiers { connection.keyDown(modifier) }
        for key in keys { connection.keyDown(key); connection.keyUp(key) }
        for modifier in modifiers.reversed() { connection.keyUp(modifier) }
    }
}

extension MacScreenSession: VNCConnectionDelegate {
    nonisolated func connection(_ connection: VNCConnection, stateDidChange connectionState: VNCConnection.ConnectionState) {
        guard connectionState.status == .disconnected else { return }
        let error = connectionState.error
        DispatchQueue.main.async { MainActor.assumeIsolated { self.ended(error, from: connection) } }
    }

    nonisolated func connection(_ connection: VNCConnection, credentialFor authenticationType: VNCAuthenticationType,
                                completion: @escaping (VNCCredential?) -> Void) {
        guard let login = MacScreenLogin.load() else { completion(nil); return }
        completion(authenticationType.requiresUsername ? VNCUsernamePasswordCredential(username: login.user, password: login.password)
                                                       : VNCPasswordCredential(password: login.password))
    }

    nonisolated func connection(_ connection: VNCConnection, didCreateFramebuffer framebuffer: VNCFramebuffer) {}
    nonisolated func connection(_ connection: VNCConnection, didResizeFramebuffer framebuffer: VNCFramebuffer) {}
    nonisolated func connection(_ connection: VNCConnection, didUpdateCursor cursor: VNCCursor) {}

    nonisolated func connection(_ connection: VNCConnection, didUpdateFramebuffer framebuffer: VNCFramebuffer,
                                x: UInt16, y: UInt16, width: UInt16, height: UInt16) {
        redrawLock.lock()
        let queued = redrawQueued
        redrawQueued = true
        redrawLock.unlock()
        guard !queued else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.redrawLock.lock(); self.redrawQueued = false; self.redrawLock.unlock()
                self.show(framebuffer)
            }
        }
    }
}

// MARK: - The view

/// Full screen: the Mac's screen, controls on top, sign-in when needed.
struct MacScreenView: View {
    let host: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var session = MacScreenSession()
    @State private var typing = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let image = session.image {
                MacScreenCanvas(image: image, session: session, typing: $typing)
                    .ignoresSafeArea(edges: .bottom)
            }
            switch session.state {
            case .signingIn: MacScreenSignIn(session: session)
            case .connecting where session.image == nil: ProgressView("Connecting to the Mac\u{2026}").tint(.white).foregroundStyle(.white)
            case .failed(let message): failure(message)
            default: EmptyView()
            }
        }
        .overlay(alignment: .topTrailing) { controls }
        .statusBarHidden(session.image != nil)
        .onAppear { session.connect(to: host) }
        .onDisappear { session.disconnect() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { session.disconnect() }
            else if phase == .active, session.state == .idle, MacScreenLogin.load() != nil { session.reconnect() }
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            if session.state == .connected {
                Button { typing.toggle() } label: { Image(systemName: typing ? "keyboard.chevron.compact.down" : "keyboard") }
                    .accessibilityLabel(typing ? "Hide Keyboard" : "Keyboard")
            }
            Menu {
                Picker("Quality", selection: $session.quality) {
                    ForEach(MacScreenSession.Quality.allCases) { Text($0.title).tag($0) }
                }
                Button("Reconnect", systemImage: "arrow.clockwise") { session.reconnect() }
                Button("Forget Mac Sign-In", systemImage: "key.slash", role: .destructive) { session.signOut() }
            } label: { Image(systemName: "ellipsis") }
            .accessibilityLabel("Mac Screen Options")
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .accessibilityLabel("Close Mac Screen")
        }
        .font(.body.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(.black.opacity(0.55), in: Capsule())
        .padding(12)
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "display.trianglebadge.exclamationmark").font(.largeTitle)
            Text(message).multilineTextAlignment(.center).accessibilityIdentifier("mac-screen-error")
            HStack {
                Button("Try Again") { session.reconnect() }.buttonStyle(.borderedProminent)
                Button("Change Sign-In") { session.signOut() }.buttonStyle(.bordered)
            }
        }
        .foregroundStyle(.white).padding(30)
    }
}

/// The Mac's user name and password, the first time (or after Forget).
private struct MacScreenSignIn: View {
    let session: MacScreenSession
    @State private var user = MacScreenLogin.load()?.user ?? ""
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sign in to your Mac").font(.title2.weight(.semibold))
            Text("Your Mac's user name and password, the ones you log in with. They stay on this phone. Screen Sharing needs to be on: System Settings → General → Sharing.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("User name", text: $user)
                .textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                .textFieldStyle(.roundedBorder).accessibilityIdentifier("mac-screen-user")
            SecureField("Password", text: $password)
                .textContentType(.password).textFieldStyle(.roundedBorder).accessibilityIdentifier("mac-screen-password")
                .onSubmit(signIn)
            Button("Sign In", action: signIn)
                .buttonStyle(.borderedProminent).frame(maxWidth: .infinity, alignment: .trailing)
                .disabled(user.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty)
        }
        .padding(22)
        .frame(maxWidth: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .padding()
        .environment(\.colorScheme, .dark)
    }

    private func signIn() {
        guard !user.isEmpty, !password.isEmpty else { return }
        session.signIn(user: user.trimmingCharacters(in: .whitespaces), password: password)
    }
}

/// The screen, zoomable, with touch turned into mouse and keyboard input.
struct MacScreenCanvas: UIViewRepresentable {
    let image: UIImage
    let session: MacScreenSession
    @Binding var typing: Bool

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    func makeUIView(context: Context) -> MacScreenScrollView {
        let view = MacScreenScrollView(coordinator: context.coordinator)
        context.coordinator.view = view
        return view
    }

    func updateUIView(_ view: MacScreenScrollView, context: Context) {
        context.coordinator.session = session
        view.show(image)
        if typing != view.keyInput.isFirstResponder {
            if typing { view.keyInput.becomeFirstResponder() } else { view.keyInput.resignFirstResponder() }
        }
        view.keyInput.onDismiss = { typing = false }
    }

    @MainActor final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var session: MacScreenSession
        weak var view: MacScreenScrollView?
        private var lastScroll: CGFloat = 0
        init(session: MacScreenSession) { self.session = session }

        private func point(_ gesture: UIGestureRecognizer) -> CGPoint { gesture.location(in: view?.imageView) }

        @objc func tap(_ g: UITapGestureRecognizer) { session.click(at: point(g)) }
        @objc func doubleTap(_ g: UITapGestureRecognizer) { session.click(at: point(g), count: 2) }
        @objc func rightClick(_ g: UITapGestureRecognizer) { session.click(at: point(g), button: .right) }

        /// Touch and hold, then move: a drag (select text, move a window).
        @objc func drag(_ g: UILongPressGestureRecognizer) {
            switch g.state {
            case .began: UIImpactFeedbackGenerator(style: .light).impactOccurred(); session.press(at: point(g))
            case .changed: session.move(to: point(g))
            default: session.release(at: point(g))
            }
        }

        /// Two fingers up or down, with the whole screen showing: the scroll wheel.
        @objc func scroll(_ g: UIPanGestureRecognizer) {
            let y = g.translation(in: view).y
            if g.state == .began { lastScroll = 0 }
            let step: CGFloat = 18
            let moved = y - lastScroll
            guard abs(moved) >= step else { return }
            session.scroll(at: point(g), up: moved > 0, steps: UInt32(abs(moved) / step))
            lastScroll += CGFloat(Int(moved / step)) * step
        }

        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            // Scrolling the Mac only when zoomed out; zoomed in, two fingers pan the view.
            guard let pan = g as? UIPanGestureRecognizer, pan.minimumNumberOfTouches == 2, let view else { return true }
            return view.zoomScale <= view.minimumZoomScale + 0.01
        }
    }
}

/// The screen image in a zooming scroll view; sized in Mac pixels, so a touch's point in the
/// image view is the Mac's screen point.
final class MacScreenScrollView: UIScrollView, UIScrollViewDelegate {
    let imageView = UIImageView()
    let keyInput = MacScreenKeyInput()
    private var imageSize = CGSize.zero

    init(coordinator: MacScreenCanvas.Coordinator) {
        super.init(frame: .zero)
        delegate = self
        backgroundColor = .black
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        bouncesZoom = true
        imageView.isUserInteractionEnabled = true
        addSubview(imageView)
        addSubview(keyInput)
        keyInput.session = coordinator.session

        let doubleTap = UITapGestureRecognizer(target: coordinator, action: #selector(MacScreenCanvas.Coordinator.doubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        let tap = UITapGestureRecognizer(target: coordinator, action: #selector(MacScreenCanvas.Coordinator.tap(_:)))
        tap.require(toFail: doubleTap)
        let right = UITapGestureRecognizer(target: coordinator, action: #selector(MacScreenCanvas.Coordinator.rightClick(_:)))
        right.numberOfTouchesRequired = 2
        let drag = UILongPressGestureRecognizer(target: coordinator, action: #selector(MacScreenCanvas.Coordinator.drag(_:)))
        drag.minimumPressDuration = 0.35
        let scroll = UIPanGestureRecognizer(target: coordinator, action: #selector(MacScreenCanvas.Coordinator.scroll(_:)))
        scroll.minimumNumberOfTouches = 2
        scroll.maximumNumberOfTouches = 2
        scroll.delegate = coordinator
        for gesture in [doubleTap, tap, right, drag, scroll] as [UIGestureRecognizer] { imageView.addGestureRecognizer(gesture) }
        panGestureRecognizer.require(toFail: drag)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ image: UIImage) {
        imageView.image = image
        guard image.size != imageSize else { return }
        imageSize = image.size
        imageView.frame = CGRect(origin: .zero, size: image.size)
        contentSize = image.size
        fit()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let fitScale = fitScale
        if abs(minimumZoomScale - fitScale) > 0.0001 { fit() }
        center()
    }

    private var fitScale: CGFloat {
        guard imageSize.width > 0, bounds.width > 0 else { return 1 }
        return min(bounds.width / imageSize.width, bounds.height / imageSize.height)
    }

    private func fit() {
        let scale = fitScale
        minimumZoomScale = scale
        maximumZoomScale = max(scale * 6, 2)
        zoomScale = scale
        center()
    }

    /// Keeps the screen centered while it's smaller than the view.
    private func center() {
        let x = max((bounds.width - contentSize.width) / 2, 0), y = max((bounds.height - contentSize.height) / 2, 0)
        contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { center() }
}

/// Takes the iOS keyboard's typing for the Mac, with a key row above it.
final class MacScreenKeyInput: UIView, UIKeyInput {
    weak var session: MacScreenSession?
    var onDismiss: () -> Void = {}
    /// Modifiers tapped on the key row, held for the next key.
    private var held: [VNCKeyCode] = []
    private var buttons: [(key: VNCKeyCode, button: UIButton)] = []

    override var canBecomeFirstResponder: Bool { true }
    var hasText: Bool { true }
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no

    func insertText(_ text: String) { session?.type(text, modifiers: takeHeld()) }
    func deleteBackward() { session?.press([.delete], modifiers: takeHeld()) }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onDismiss() }
        return resigned
    }

    private func takeHeld() -> [VNCKeyCode] {
        let modifiers = held
        held = []
        refresh()
        return modifiers
    }

    override var inputAccessoryView: UIView? { keyRow }

    private lazy var keyRow: UIView = {
        let bar = UIInputView(frame: CGRect(x: 0, y: 0, width: 0, height: 46), inputViewStyle: .keyboard)
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: bar.topAnchor, constant: 5),
            stack.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -5),
        ])
        let keys: [(String, VNCKeyCode, Bool)] = [
            ("esc", .escape, false), ("tab", .tab, false),
            ("⌘", .commandForARD, true), ("⌥", .optionForARD, true), ("⌃", .control, true), ("⇧", .shift, true),
            ("←", .leftArrow, false), ("↑", .upArrow, false), ("↓", .downArrow, false), ("→", .rightArrow, false),
        ]
        for (title, key, isModifier) in keys {
            var configuration = UIButton.Configuration.gray()
            configuration.title = title
            configuration.contentInsets = .init(top: 4, leading: 2, bottom: 4, trailing: 2)
            let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in
                guard let self else { return }
                if isModifier {
                    if let index = held.firstIndex(of: key) { held.remove(at: index) } else { held.append(key) }
                    refresh()
                } else {
                    session?.press([key], modifiers: takeHeld())
                }
            })
            button.accessibilityLabel = ["⌘": "Command", "⌥": "Option", "⌃": "Control", "⇧": "Shift", "←": "Left Arrow",
                                         "↑": "Up Arrow", "↓": "Down Arrow", "→": "Right Arrow"][title] ?? title
            if isModifier { buttons.append((key, button)) }
            stack.addArrangedSubview(button)
        }
        return bar
    }()

    private func refresh() {
        for (key, button) in buttons {
            let on = held.contains(key)
            var configuration = button.configuration
            configuration?.baseBackgroundColor = on ? UIColor.tintColor : nil
            configuration?.baseForegroundColor = on ? UIColor.white : nil
            button.configuration = configuration
            button.accessibilityTraits = on ? [UIAccessibilityTraits.button, .selected] : UIAccessibilityTraits.button
        }
    }
}
#endif
