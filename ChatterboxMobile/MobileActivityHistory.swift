import SwiftUI

/// A history of completed turns, shared by the Mac so it works while the phone is away.
struct MobileActivityView: View {
    @Environment(MobileStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    /// The turn you tapped: the list opens its chat once this sheet has closed.
    var open: (UUID) -> Void = { MobilePushNotifications.shared.pendingChat = $0 }

    var body: some View {
        NavigationStack {
            List {
                if let activity = store.chatList?.activity {
                    if activity.isEmpty {
                        ContentUnavailableView("No finished turns yet", systemImage: "clock",
                                               description: Text("Turns that end after this update will appear here."))
                    }
                    ForEach(activity) { event in
                        Button {
                            open(event.chatID)
                            dismiss()
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(event.title).font(.headline).foregroundStyle(.primary)
                                    Text("Turn ended · \(event.backend == "claude" ? "Claude" : "Codex")")
                                        .font(.subheadline).foregroundStyle(.secondary)
                                    Text(event.endedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }.padding(.vertical, 6)
                        }.buttonStyle(.plain).accessibilityLabel("\(event.title), turn ended")
                    }
                } else {
                    ContentUnavailableView("Waiting for activity", systemImage: "clock",
                                           description: Text("Connect to the updated Mac service to load finished turns."))
                }
                if let problem = store.problem { Text(problem).font(.footnote).foregroundStyle(.secondary) }
            }
            .navigationTitle("Activity").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .refreshable { await store.loadChats() }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                while !Task.isCancelled {
                    await store.loadChats()
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                }
            }
        }
    }
}
