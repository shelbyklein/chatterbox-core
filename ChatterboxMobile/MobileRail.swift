import SwiftUI

// The open iPhone Duo's side rail. Closed, iOS runs a page's bar buttons down the rail by
// itself; open, it doesn't (the list's buttons sit over the list, and a session's were folded
// into a pill), so the top of the rail stood empty under the clock. Shelby (2026-11-20) wanted
// buttons there: this column, drawn in the rail's strip (the window's trailing safe area).
// A session shows Back, Session Settings, its ⋯ menu and Feedback; no session open, the page's
// ⋯ menu and Feedback.

@MainActor @Observable
final class MobileRail {
    static let shared = MobileRail()

    struct Session {
        let chat: UUID
        let back: () -> Void
        let settings: () -> Void
        let backend: String
        let menu: AnyView
    }

    /// The open session in each tab (by tab tag), while it shows in the open layout.
    private(set) var sessions: [String: Session] = [:]
    /// Each tab's own ⋯ menu.
    private(set) var pageMenus: [String: AnyView] = [:]

    func show(_ session: Session, in tab: String) { sessions[tab] = session }
    /// Only the session that registered takes itself away (another may have replaced it).
    func hide(_ chat: UUID, in tab: String) { if sessions[tab]?.chat == chat { sessions[tab] = nil } }
    func setPageMenu(_ menu: AnyView, in tab: String) { pageMenus[tab] = menu }
}

/// Which tab a view is in, so its rail buttons go to that tab.
private struct RailTabKey: EnvironmentKey { static let defaultValue = "" }
extension EnvironmentValues {
    var railTab: String {
        get { self[RailTabKey.self] }
        set { self[RailTabKey.self] = newValue }
    }
}

/// The column, in the trailing strip, below the clock and above the tab icons. Only when the
/// window is wide (the open Duo) and has a strip on its trailing side.
struct MobileRailColumn: View {
    let tab: String
    /// The tab icons' group, measured from Shelby's screenshot: 48 points wide, centered 6
    /// points left of the strip's middle.
    static let width: CGFloat = 48
    static let nudge: CGFloat = 6
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var rail: MobileRail { .shared }

    var body: some View {
        GeometryReader { geometry in
            let strip = geometry.safeAreaInsets.trailing
            if sizeClass == .regular, strip >= 40 {
                let fullHeight = geometry.size.height + geometry.safeAreaInsets.top + geometry.safeAreaInsets.bottom
                // Below the clock and battery, as in Shelby's screenshots (~16% down the screen).
                let top = fullHeight * 0.16 - geometry.safeAreaInsets.top
                column
                    .frame(width: strip)
                    .fixedSize(horizontal: false, vertical: true)
                    .offset(x: geometry.size.width, y: top)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("open-rail")
            }
        }
    }

    @ViewBuilder private var column: some View {
        let session = rail.sessions[tab]
        let menu = session?.menu ?? rail.pageMenus[tab]
        if session != nil || menu != nil {
            VStack(spacing: 6) {
                if let session {
                    railButton("chevron.left", label: "Back", id: "rail-back", action: session.back)
                    Button(action: session.settings) {
                        Image(session.backend == "codex" ? "AgentCodex" : "AgentClaude")
                            .resizable().renderingMode(.template).scaledToFit()
                            .frame(width: 22, height: 22)
                            .foregroundStyle(MobileConversationStyle.accent(for: session.backend))
                            .frame(width: 44, height: 48)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Session Settings")
                    .accessibilityIdentifier("rail-open-settings")
                }
                if let menu {
                    menu
                        .font(.title3.weight(.semibold))
                        .frame(width: 44, height: 48)
                        .contentShape(Rectangle())
                        .accessibilityIdentifier("rail-menu")
                }
                FeedbackButton()
                    .font(.title3)
                    .frame(width: 44, height: 48)
                    .contentShape(Rectangle())
            }
            .foregroundStyle(.primary)
            .padding(.vertical, 8)
            .frame(width: Self.width)
            .modifier(RailGlass())
            // On the tab icons' center line, which sits a little left of the strip's middle
            // (Shelby's screenshot, 2026-11-20).
            .frame(maxWidth: .infinity)
            .offset(x: -Self.nudge)
        }
    }

    private func railButton(_ symbol: String, label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .frame(width: 44, height: 48)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }
}

/// The same glass as iOS's own tab group below it; a plain dark capsule before iOS 26.
private struct RailGlass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.glassEffect(.regular, in: Capsule(style: .continuous))
        } else {
            content.background(Capsule(style: .continuous).fill(Color(uiColor: .secondarySystemBackground)))
        }
    }
}
