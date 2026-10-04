import SwiftUI

/// Mounts a new keyed chat only after the outgoing transcript has faded away.
/// Owned above ChatView, so changing its identity cannot reset the transition.
@MainActor @Observable
final class ChatSwitchTransition {
    private(set) var initialized = false
    private(set) var displayedID: UUID?
    private(set) var opacity = 1.0
    private(set) var offset = 0.0
    private(set) var switching = false
    private var generation = 0
    private var mountedID: UUID?

    func didMount(_ id: UUID) { mountedID = id }

    func show(_ id: UUID?, reduceMotion: Bool, waitForMount: Bool = false) async {
        generation += 1
        let ticket = generation
        if !initialized || id == nil || displayedID == nil || id == displayedID {
            initialized = true
            displayedID = id
            opacity = 1; offset = 0; switching = false
            return
        }
        switching = true
        withAnimation(.easeIn(duration: 0.06)) {
            opacity = 0
            offset = reduceMotion ? 0 : -6
        }
        do {
            try await Task.sleep(for: .milliseconds(70))
            guard ticket == generation, !Task.isCancelled else { return }
            // No crossfade: old and new composers/transcripts are never mounted together.
            mountedID = nil
            displayedID = id
            offset = reduceMotion ? 0 : 6
            while waitForMount && mountedID != id {
                try await Task.sleep(for: .milliseconds(10))
                guard ticket == generation, !Task.isCancelled else { return }
            }
            // One frame after mounting, rather than a fixed transcript-settling pause.
            // Let the incoming composer accept input as soon as it is visible.
            try await Task.sleep(for: .milliseconds(16))
            guard ticket == generation, !Task.isCancelled else { return }
            switching = false
            withAnimation(.easeOut(duration: 0.10)) { opacity = 1; offset = 0 }
        } catch {
            // The next task owns presentation. A cancelled older switch must not reveal it.
        }
    }
}

private struct ChatSwitchCoordinatorKey: EnvironmentKey {
    static let defaultValue: ChatSwitchTransition? = nil
}
extension EnvironmentValues {
    var chatSwitchCoordinator: ChatSwitchTransition? {
        get { self[ChatSwitchCoordinatorKey.self] }
        set { self[ChatSwitchCoordinatorKey.self] = newValue }
    }
}

/// Animation updates are observed here, outside the expensive transcript/column builders.
struct ChatSwitchSurface: View {
    let content: AnyView
    @Environment(\.chatSwitchCoordinator) private var transition
    var body: some View {
        content.opacity(transition?.opacity ?? 1).offset(x: transition?.offset ?? 0)
            .disabled(transition?.switching ?? false)
            .allowsHitTesting(!(transition?.switching ?? false))
            .accessibilityHidden(transition?.switching ?? false)
    }
}
