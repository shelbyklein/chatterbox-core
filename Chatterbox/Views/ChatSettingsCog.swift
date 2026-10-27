import SwiftUI

/// Shared by the Chat menu and sidebar menus.
struct RestartThreadControl: View {
    let session: ChatSession
    var beforeRestart: () -> Void = {}
    var body: some View {
        Button {
            beforeRestart()
            Task { await session.restartThread() }
        } label: {
            Label(session.isRestartingThread ? "Restarting Thread…" : session.isRunning ? "Stop and Restart Thread" : "Restart Thread",
                  systemImage: "arrow.clockwise")
        }
        .disabled(session.isRestartingThread || session.awaitingHostResume)
        .help("Reconnect this thread, keeping its history and draft. Stops its current reply without resending anything.")
    }
}

struct ThreadRestartStatus: View {
    let session: ChatSession
    var body: some View {
        if session.isRestartingThread || session.threadRestartStatus != nil {
            HStack(alignment: .top, spacing: 8) {
                if session.isRestartingThread { ProgressView().controlSize(.small) }
                Text(session.isRestartingThread ? "Restarting thread…" : session.threadRestartStatus ?? "")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if !session.isRestartingThread {
                    Button { session.threadRestartStatus = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).accessibilityLabel("Dismiss restart status")
                }
            }
        }
    }
}
