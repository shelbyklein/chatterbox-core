import SwiftUI

/// The accounts' usage from the Mac: Claude's and Codex's limit windows (how much is used,
/// and when each resets), and each EasyCLIProxy account's remaining quota.
struct MobileUsageView: View {
    @Environment(MobileStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var usage: Companion.Usage?
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            List {
                if let problem { Section { Label(problem, systemImage: "wifi.exclamationmark").foregroundStyle(.orange) } }
                if let usage {
                    limits("Claude", usage.claude)
                    limits("Codex", usage.codex)
                    if let accounts = usage.proxyAccounts {
                        Section {
                            if let note = usage.proxyProblem { Text(note).font(.footnote).foregroundStyle(.orange) }
                            if accounts.isEmpty { Text("No accounts yet").foregroundStyle(.secondary) }
                            ForEach(accounts, id: \.self) { account in
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text(account.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                                        Spacer()
                                        Text(account.status).font(.caption).foregroundStyle(account.status == "Available" ? Color.secondary : Color.orange)
                                    }
                                    ForEach(account.windows, id: \.self) { window in meter(window, remaining: true) }
                                    if let note = account.problem { Text(note).font(.caption).foregroundStyle(.secondary) }
                                }
                                .padding(.vertical, 4)
                            }
                        } header: { Text("Proxy accounts") } footer: {
                            if let checked = usage.proxyChecked { Text("Checked \(checked.formatted(.relative(presentation: .named)))") }
                        }
                    }
                } else if problem == nil {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Usage").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .refreshable { await load(refresh: true) }
            .task { await load(refresh: false) }
        }
    }

    @ViewBuilder
    private func limits(_ agent: String, _ windows: [Companion.Usage.Window]) -> some View {
        Section(agent) {
            if windows.isEmpty {
                Text("No limits reported yet. They show after \(agent) answers on the Mac.").font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(windows, id: \.self) { meter($0, remaining: false) }
        }
    }

    /// A labelled bar: how much of a limit is used, or how much of a quota is left.
    private func meter(_ window: Companion.Usage.Window, remaining: Bool) -> some View {
        let fraction = min(1, max(0, window.fraction ?? 0))
        let used = remaining ? 1 - fraction : fraction
        let tint: Color = used >= 0.9 ? .red : used >= 0.75 ? .orange : .accentColor
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(window.label).font(.subheadline)
                Spacer()
                Text(window.fraction == nil ? "Unknown" : "\(Int((fraction * 100).rounded()))% \(remaining ? "left" : "used")")
                    .font(.subheadline.monospacedDigit()).foregroundStyle(used >= 0.75 ? tint : .secondary)
            }
            ProgressView(value: used).tint(tint)
            if let reset = window.resetsAt, reset > Date() {
                Text("Resets \(reset.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func load(refresh: Bool) async {
        do {
            usage = try await store.usage(refresh: refresh)
            problem = nil
            // A refreshed proxy check lands a moment later.
            if refresh {
                try? await Task.sleep(for: .seconds(3))
                usage = try await store.usage()
            }
        } catch {
            problem = error.localizedDescription
        }
    }
}
