import SwiftUI

struct ProxyQuotaView: View {
    var route: String? = nil
    var store = ProxyQuotaStore.shared
    var compact = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Account Usage").font(.title2.bold())
                    Text("Subscription quota via EasyCLIProxy").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if store.refreshing { ProgressView().controlSize(.small).accessibilityLabel("Refreshing account usage") }
                Button { Task { await store.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .disabled(store.refreshing)
            }
            if let route {
                Label(route, systemImage: "arrow.triangle.branch").font(.callout)
                Text("Configured route; the active process and account can differ until the next launch. Quota cards show the whole proxy pool.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let problem = store.problem {
                Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                if !store.accounts.isEmpty { Text("Showing the previous results.").font(.caption).foregroundStyle(.secondary) }
            }
            if store.accounts.isEmpty && !store.refreshing && store.problem == nil {
                ContentUnavailableView("No Claude or Codex accounts", systemImage: "person.crop.circle.badge.questionmark", description: Text("Add accounts in EasyCLIProxyAPI, then refresh."))
            }
            forProvider("claude", title: "Claude")
            forProvider("codex", title: "Codex")
            if let date = store.lastRefresh {
                Text("Last refreshed \(date.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary)
            }
            Text("Read-only. Manage accounts and quota resets in EasyCLIProxyAPI.").font(.caption).foregroundStyle(.secondary)
        }
        .task { await store.refreshIfNeeded() }
    }
    @ViewBuilder private func forProvider(_ provider: String, title: String) -> some View {
        let accounts = store.accounts.filter { $0.provider == provider }
        if !accounts.isEmpty {
            HStack { Text(title).font(.headline); Text("\(accounts.count) accounts").font(.caption).foregroundStyle(.secondary) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: compact ? 240 : 260), spacing: 12, alignment: .top)], spacing: 12) {
                ForEach(accounts) { account in
                    VStack(alignment: .leading, spacing: 12) {
                        Text(account.name).font(.subheadline.weight(.semibold)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        Label(account.status, systemImage: account.status == "Available" ? "checkmark.circle" : account.status == "Limited" ? "clock" : "info.circle")
                            .font(.caption).foregroundStyle(account.status == "Limited" ? .orange : .secondary)
                        if let problem = account.problem { Text(problem).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                        if account.windows.isEmpty && account.problem == nil { Text(store.refreshing ? "Checking quota…" : "No quota windows reported.").font(.caption).foregroundStyle(.secondary) }
                        ForEach(account.windows) { window in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(window.title).font(.caption).fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 6)
                                    Text(window.remaining.map { "\(Int($0.rounded()))% remaining" } ?? "Unknown").font(.caption.weight(.semibold)).monospacedDigit()
                                }
                                if let remaining = window.remaining {
                                    GeometryReader { geometry in
                                        ZStack(alignment: .leading) {
                                            Capsule().fill(.primary.opacity(0.12))
                                            Capsule().fill(remaining <= 10 ? Color.orange : Color.accentColor)
                                                .frame(width: geometry.size.width * remaining / 100)
                                        }
                                    }
                                    .frame(height: 6)
                                    .accessibilityElement().accessibilityLabel(window.title).accessibilityValue("\(Int(remaining)) percent remaining")
                                }
                                if let reset = window.reset {
                                    Text("Resets \(reset.formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .padding(14).frame(maxWidth: .infinity, alignment: .topLeading)
                    .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.1)))
                }
            }
        }
    }
}

struct ProxyQuotaToolbarButton: View {
    let bridge: ChatToolbarBridge
    @State private var showing = false
    private var route: String? {
        guard let session = bridge.session else { return nil }
        if session.isDot { return "Golem · Direct connection" }
        if session.record.backend == .claude {
            return EasyCLIProxy.shared.claudeOn ? "Claude · Proxy enabled (direct fallback if unavailable)" : "Claude · Direct connection"
        }
        if session.codexRoute == .direct { return "Codex · Direct requested" }
        if session.codexRoute == .proxy || EasyCLIProxy.shared.codexOn { return "Codex · Proxy requested" }
        let provider = EasyCLIProxy.directCodexProvider
        return provider == "openai" ? "Codex · Direct connection" : "Codex · Global provider: \(provider)"
    }
    var body: some View {
        Button { showing.toggle() } label: { Image(systemName: "chart.bar.xaxis") }
            .help("Account usage and connection route").accessibilityLabel("Account Usage")
            .popover(isPresented: $showing) {
                ScrollView { ProxyQuotaView(route: route, compact: true).padding(20) }
                    .frame(width: 580, height: 580)
            }
    }
}
