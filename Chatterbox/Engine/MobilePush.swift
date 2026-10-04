import CryptoKit
import Foundation
import Observation
import Security

struct PushCredentials: Codable, Sendable {
    var keyID: String
    var teamID: String
    var pem: String
    // The app creates this entry, so its stable signing identity owns the ACL.
    // The original entry may have been created by a one-off setup helper.
    static let service = "com.shelbyklein.Chatterbox.apns.app"
    private static let accessLock = NSLock()
    static func read(allowInteraction: Bool = false) throws -> PushCredentials {
        accessLock.lock()
        defer { accessLock.unlock() }
        // This item lives in the login keychain. Its legacy ACL dialogs also need
        // the classic Keychain switch; authentication UI options alone aren't enough.
        var previousInteraction: DarwinBoolean = true
        if !allowInteraction {
            guard SecKeychainGetUserInteractionAllowed(&previousInteraction) == errSecSuccess,
                  SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else {
                throw PushFailure.message("Couldn't safely access Keychain without prompting.")
            }
        }
        defer { if !allowInteraction { SecKeychainSetUserInteractionAllowed(previousInteraction.boolValue) } }
        var value: CFTypeRef?
        var query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
            kSecAttrAccount: "provider", kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne,
            kSecUseAuthenticationUI: allowInteraction ? kSecUseAuthenticationUIAllow : kSecUseAuthenticationUIFail]
        var status = SecItemCopyMatching(query as CFDictionary, &value)
        let migrating = status == errSecItemNotFound
        if migrating {
            query[kSecAttrService] = "com.shelbyklein.Chatterbox.apns"
            status = SecItemCopyMatching(query as CFDictionary, &value)
        }
        guard status == errSecSuccess, let data = value as? Data else {
            throw PushFailure.message(status == errSecItemNotFound ? "Import your APNs key first." : "Keychain access needs attention. In Settings → iPhone → Push notifications, click Authorize Keychain Access.")
        }
        let credentials = try JSONDecoder().decode(Self.self, from: data)
        if migrating { try credentials.save() }
        return credentials
    }
    func save() throws {
        _ = try P256.Signing.PrivateKey(pemRepresentation: pem)
        guard Self.validID(keyID), Self.validID(teamID) else { throw PushFailure.message("Key ID and Team ID must each be 10 letters or digits.") }
        let data = try JSONEncoder().encode(self)
        let query = [kSecClass: kSecClassGenericPassword, kSecAttrService: Self.service, kSecAttrAccount: "provider"] as CFDictionary
        var status = SecItemUpdate(query, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd([kSecClass: kSecClassGenericPassword, kSecAttrService: Self.service,
                kSecAttrAccount: "provider", kSecValueData: data,
                kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw PushFailure.message("Couldn’t store the APNs key in Keychain (\(status)).") }
    }
    static func remove() {
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: "provider"] as CFDictionary)
    }
    static func validID(_ text: String) -> Bool {
        text.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil
    }
}

enum PushFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}

enum APNsJWT {
    static func base64(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func make(_ credentials: PushCredentials, now: Date = Date()) throws -> String {
        let header = try JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": credentials.keyID])
        let body = try JSONSerialization.data(withJSONObject: ["iss": credentials.teamID, "iat": Int(now.timeIntervalSince1970)])
        let input = base64(header) + "." + base64(body)
        let key = try P256.Signing.PrivateKey(pemRepresentation: credentials.pem)
        return input + "." + base64(try key.signature(for: Data(input.utf8)).rawRepresentation)
    }
}

/// Serial, bounded delivery; URLSession negotiates HTTP/2 with Apple over TLS.
actor APNsProvider {
    static let shared = APNsProvider()
    private var cachedJWT: String?
    private var cachedAt = Date.distantPast
    private var cachedKey = ""
    static let topic = "com.shelbyklein.Chatterbox.mobile"
    static func request(token: String, environment: String, jwt: String, payload: Data, collapse: String,product:String="chatterbox") -> URLRequest {
        let host = environment == "production" ? "api.push.apple.com" : "api.sandbox.push.apple.com"
        var request = URLRequest(url: URL(string: "https://\(host)/3/device/\(token)")!, timeoutInterval: 20)
        request.httpMethod = "POST"; request.httpBody = payload
        request.setValue("bearer \(jwt)", forHTTPHeaderField: "authorization")
        request.setValue(product=="golem" ? "com.shelbyklein.Golem.mobile":topic, forHTTPHeaderField: "apns-topic")
        request.setValue("alert", forHTTPHeaderField: "apns-push-type")
        request.setValue("10", forHTTPHeaderField: "apns-priority")
        request.setValue(String(Int(Date().addingTimeInterval(3600).timeIntervalSince1970)), forHTTPHeaderField: "apns-expiration")
        request.setValue(String(collapse.prefix(64)), forHTTPHeaderField: "apns-collapse-id")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        return request
    }
    func send(token: String, environment: String, payload: Data, collapse: String,product:String="chatterbox") async throws -> Int {
        let credentials = try PushCredentials.read()
        // Include key contents only in a local hash, so replacing a key resets the cache.
        let fingerprint = APNsJWT.base64(Data(SHA256.hash(data: Data(credentials.pem.utf8)))) + credentials.keyID + credentials.teamID
        if cachedJWT == nil || cachedKey != fingerprint || Date().timeIntervalSince(cachedAt) > 3000 {
            cachedJWT = try APNsJWT.make(credentials); cachedAt = Date(); cachedKey = fingerprint
        }
        let request = Self.request(token: token, environment: environment, jwt: cachedJWT!, payload: payload, collapse: collapse,product:product)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw PushFailure.message("Apple returned an invalid response.") }
        if response.statusCode == 200 || response.statusCode == 410 { return response.statusCode }
        let reason = (try? JSONSerialization.jsonObject(with: data) as? [String: String])?["reason"] ?? "Unknown"
        throw PushFailure.message("Apple rejected the push (\(response.statusCode): \(reason)).")
    }
}

@MainActor @Observable final class MobilePush {
    static let shared = MobilePush()
    private(set) var status = "No pushes sent yet." {
        didSet {
            AppPreferences.defaults.set(status, forKey: "mobilePushLastStatus")
            RuntimeHooks.note("Mobile push: \(status)")
        }
    }
    private(set) var sending = false
    @ObservationIgnored private var queue: [Event] = []
    struct Event {
        var title: String; var body: String; var chat: UUID?; var kind: String
        var id = UUID().uuidString
        var target: UUID? = nil
    }
    var configured: Bool { AppPreferences.defaults.bool(forKey: "mobilePushConfigured") }
    var enabled: Bool { configured && (AppPreferences.defaults.object(forKey: "mobilePushEnabled") as? Bool ?? true) && CompanionServer.shared.isEnabled }
    func configure(file: URL, keyID: String, teamID: String) throws {
        let pem = try String(contentsOf: file, encoding: .utf8)
        try PushCredentials(keyID: keyID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
            teamID: teamID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(), pem: pem).save()
        AppPreferences.defaults.set(true, forKey: "mobilePushConfigured")
        AppPreferences.defaults.set(keyID.uppercased(), forKey: "mobilePushKeyID")
        status = "Key saved. Enable notifications on each phone or iPad."
    }
    func removeKey() { PushCredentials.remove(); AppPreferences.defaults.set(false, forKey: "mobilePushConfigured"); status = "Key removed." }
    static func payload(_ event: Event, previews: Bool, sound: Bool) throws -> Data {
        let product=event.kind=="golem" ? "Golem":"Chatterbox"
        var aps: [String: Any] = ["alert": ["title": previews ? String(event.title.prefix(120)) : product,
            "body": previews ? String(event.body.prefix(650)) : "Open \(product) to see your update."],
            "thread-id": event.chat?.uuidString ?? "chatterbox"]
        if sound { aps["sound"] = "default" }
        var body: [String: Any] = ["aps": aps, "kind": event.kind, "event": event.id]
        if let chat = event.chat { body["chat"] = chat.uuidString }
        return try JSONSerialization.data(withJSONObject: body)
    }
    func post(title: String, body: String, chat: UUID?, kind: String,identity:String?=nil) {
        guard enabled, AppPreferences.defaults.object(forKey: "mobilePush_\(kind)") as? Bool ?? true else { return }
        var event=Event(title:title,body:body,chat:chat,kind:kind)
        if let identity{event.id=identity}
        enqueue(event)
    }
    func test(_ device: UUID) {
        guard enabled else { status = "Import a key and turn on mobile notifications first."; return }
        enqueue(Event(title: "Chatterbox test notification", body: "This test was sent by Chatterbox on your Mac. Tap to open Chatterbox.", chat: nil, kind: "test", target: device))
    }
    #if DEBUG
    @ObservationIgnored private var ranSetup = false
    /// Local, explicitly requested setup and end-to-end checks through the real app identity.
    func runRequestedSetup() {
        guard !ranSetup else { return }
        ranSetup = true
        let args = CommandLine.arguments
        func argument(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), args.indices.contains(i + 1) else { return nil }
            return args[i + 1]
        }
        do {
            if let path = argument("--import-push-key") {
                let defaults = AppPreferences.defaults
                try configure(file: URL(fileURLWithPath: path), keyID: defaults.string(forKey: "mobilePushKeyID") ?? "",
                              teamID: defaults.string(forKey: "mobilePushTeamID") ?? "")
                _ = try PushCredentials.read()
                status = "App-owned Keychain entry verified without prompting."
            }
            if args.contains("--check-push-keychain") {
                _ = try PushCredentials.read()
                status = "App-owned Keychain entry verified without prompting."
            }
            if let value = argument("--test-push-device"), let id = UUID(uuidString: value) { test(id) }
        } catch { status = error.localizedDescription }
    }
    #endif
    /// Only a deliberate Settings action may bring up a system authorization dialog.
    func authorizeKeychain() {
        do {
            _ = try PushCredentials.read(allowInteraction: true)
            status = "Keychain access verified. Choose Always Allow in the system prompt to keep future sends automatic."
        } catch { status = error.localizedDescription }
    }
    private func enqueue(_ event: Event) {
        guard queue.count < 100 else { status = "Too many updates waiting; a push was skipped."; return }
        queue.append(event)
        if !sending { sending = true; Task { await drain() } }
    }
    private func drain() async {
        defer { sending = false }
        while !queue.isEmpty {
            let event = queue.removeFirst()
            guard enabled else { queue.removeAll(); return }
            let defaults = AppPreferences.defaults
            let payload: Data
            do { payload = try Self.payload(event, previews: defaults.object(forKey: "mobilePushPreviews") as? Bool ?? true,
                sound: defaults.object(forKey: "mobilePushSound") as? Bool ?? true) }
            catch { status = error.localizedDescription; continue }
            let product=["golem","email"].contains(event.kind) ? "golem":"chatterbox"
            let targets = CompanionServer.shared.devices.filter { ($0.product ?? "chatterbox")==product && $0.push?.enabled == true && (event.target == nil || $0.id == event.target) }
            if targets.isEmpty { status = "No paired device has enabled notifications yet." }
            for device in targets {
                guard let push = device.push else { continue }
                do {
                    let code = try await APNsProvider.shared.send(token: push.token, environment: push.environment, payload: payload, collapse: event.id,product:product)
                    if code == 410 { CompanionServer.shared.clearPush(device.id, token: push.token); status = "\(device.name) needs to register notifications again." }
                    else { status = "Apple accepted the push to \(device.name) at \(Date().formatted(date: .omitted, time: .shortened))." }
                } catch { status = error.localizedDescription }
            }
        }
    }
}
