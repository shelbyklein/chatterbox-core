import SwiftUI

/// Settings > iPhone: turn on the Chatterbox iPhone app, pair a phone, and see paired phones.
struct CompanionSettingsView: View {
    @AppStorage(CompanionServer.enabledKey) private var enabled = false
    private var server: CompanionServer { .shared }

    var body: some View {
        Form {
            Section {
                Toggle("Let the Chatterbox iPhone app connect", isOn: $enabled)
                    .onChange(of: enabled) { _, on in server.setEnabled(on) }
                if enabled {
                    LabeledContent("Status") {
                        if let problem = server.problem {
                            Text(problem).foregroundStyle(.orange)
                        } else {
                            Text(server.isRunning ? "Ready" : "Starting\u{2026}").foregroundStyle(.secondary)
                        }
                    }
                }
            } footer: {
                Text("Your iPhone can read your chats and send messages while Chatterbox’s background service runs on this Mac, even with the app closed. It connects over your home Wi-Fi, or through Tailscale.")
                    .foregroundStyle(.secondary)
            }

            if enabled {
                Section("Pair an iPhone") {
                    LabeledContent("Pairing code") {
                        HStack {
                            Text(server.pairingCode.chunked)
                                .font(.system(.title2, design: .monospaced).weight(.semibold))
                                .textSelection(.enabled)
                            Button("New Code") { server.newPairingCode() }
                        }
                    }
                    LabeledContent("Addresses") {
                        VStack(alignment: .trailing, spacing: 2) {
                            let addresses = CompanionServer.addresses
                            if addresses.isEmpty { Text("Not on a network").foregroundStyle(.secondary) }
                            ForEach(addresses, id: \.self) { ip in
                                Text("\(ip)  \(CompanionServer.isTailscale(ip) ? "Tailscale" : "Wi-Fi")")
                                    .font(.callout.monospaced()).textSelection(.enabled)
                            }
                        }
                    }
                    Text("Open Chatterbox on your iPhone. On the same Wi-Fi it finds this Mac by itself; otherwise enter the Tailscale address. Then type the code.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                MobilePushSettings()

                Section("Paired iPhones") {
                    if server.devices.isEmpty {
                        Text("None yet.").foregroundStyle(.secondary)
                    }
                    ForEach(server.devices) { device in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(device.name)
                                Text(device.lastSeen.map { "Last used \($0.formatted(.relative(presentation: .named)))" }
                                     ?? "Paired \(device.pairedAt.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Remove", role: .destructive) { server.forget(device) }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 640)
        .task {
            while !Task.isCancelled {
                await server.refreshProjection()
                try? await Task.sleep(for:.seconds(3))
            }
        }
    }
}

private extension String {
    /// "123 456"
    var chunked: String { count == 6 ? prefix(3) + " " + suffix(3) : self }
}
