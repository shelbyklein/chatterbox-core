import AppKit
import SwiftUI

struct MobilePushSettings: View {
    @AppStorage("mobilePushEnabled") private var enabled = true
    @AppStorage("mobilePushKeyID") private var keyID = ""
    @AppStorage("mobilePushTeamID") private var teamID = "9F3MKVW9C5"
    @AppStorage("mobilePushPreviews") private var previews = true
    @AppStorage("mobilePushSound") private var sound = true
    @AppStorage("mobilePush_needs") private var needs = true
    @AppStorage("mobilePush_replies") private var replies = true
    @AppStorage("mobilePush_golem") private var golem = true
    @AppStorage("mobilePush_email") private var email = true
    @State private var error: String?
    /// What the background service said about its own Keychain access.
    @State private var serviceStatus: String?
    @State private var authorizing = false
    private var push: MobilePush { .shared }
    /// Pushes are signed by whichever process sends them. With the background service that's
    /// chatterboxd, whose Keychain access is its own, so it asks (and shows the prompt) itself.
    private func authorizeKeychain() {
        guard RuntimeClient.usesDaemon else { push.authorizeKeychain(); return }
        authorizing = true
        serviceStatus = "macOS may ask for your login password for \u{201C}chatterboxd\u{201D}. Choose Always Allow."
        Task {
            defer { authorizing = false }
            do {
                let reply = try await RuntimeClient.shared.request("authorizePush", timeout: .seconds(180))
                serviceStatus = reply["status"]?.string ?? "The background service didn't say."
            } catch {
                let text = error.localizedDescription
                serviceStatus = text.contains("unsupported") || text.contains("unknown")
                    ? "The background service is out of date. Restart it, then try again." : text
            }
        }
    }

    var body: some View {
        Section {
            Toggle("Send updates to my iPhone and iPad", isOn: $enabled)
            TextField("APNs Key ID", text: $keyID)
            TextField("Apple Team ID", text: $teamID)
            HStack {
                Button(push.configured ? "Replace APNs Key…" : "Import APNs Key…") { importKey() }
                    .disabled(!PushCredentials.validID(keyID.uppercased()) || !PushCredentials.validID(teamID.uppercased()))
                if push.configured { Button("Remove Key", role: .destructive) { push.removeKey() } }
            }
            Text(push.configured ? "Signing key stored in this Mac’s Keychain." : "Create an APNs key in your Apple Developer account, then import its .p8 file.")
                .font(.caption).foregroundStyle(.secondary)
            if push.configured {
                Button(authorizing ? "Waiting for Keychain\u{2026}" : "Authorize Keychain Access") { authorizeKeychain() }
                    .disabled(authorizing)
                if let serviceStatus { Text(serviceStatus).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                Toggle("Approvals and questions", isOn: $needs)
                Toggle("Finished replies", isOn: $replies)
                Toggle("Golem briefings", isOn: $golem)
                Toggle("Important email", isOn: $email)
                Toggle("Include message previews", isOn: $previews)
                Toggle("Sound", isOn: $sound)
                Text(push.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                ForEach(CompanionServer.shared.devices) { device in
                    HStack {
                        Text(device.name)
                        Spacer()
                        if device.push?.enabled == true {
                            Button("Send Test") { push.test(device.id) }.disabled(push.sending || !enabled)
                        } else { Text("Enable on device").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            if let error { Text(error).foregroundStyle(.orange) }
        } header: { Text("Push notifications") } footer: {
            Text("Apple delivers alerts over Wi-Fi or cellular. This Mac must be awake with Chatterbox open to send them. Opening a chat still needs Wi-Fi or Tailscale. Notification previews pass through Apple; switch them off for generic alerts.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private func importKey() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = "Choose the APNs AuthKey .p8 file. It will be stored in Keychain."
        guard panel.runModal() == .OK, let file = panel.url else { return }
        do { try push.configure(file: file, keyID: keyID, teamID: teamID); error = nil }
        catch { self.error = error.localizedDescription }
    }
}
