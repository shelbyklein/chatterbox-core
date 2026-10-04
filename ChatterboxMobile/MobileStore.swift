import Foundation
import Network
import Observation
import Security
import UIKit

struct MobileError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

/// The connection to Chatterbox on the Mac: where it is, the token from pairing, and the
/// calls the app makes. It tries the address that last worked first, then the others (the
/// home network, Tailscale), so it keeps working when the phone leaves the house.
@MainActor
@Observable
final class MobileStore {
    struct Connection: Codable {
        var macName: String
        /// Addresses to try, most recently working first.
        var hosts: [String]
    }

    private(set) var connection: Connection?
    private(set) var chatList: Companion.ChatList?
    /// Why the last call failed, shown until one works again.
    private(set) var problem: String?
    @ObservationIgnored private var token: String?
    /// Persisted text per chat. The shared composer writes this synchronously while typing
    /// and when a submitted draft is consumed, before any network suspension.
    @ObservationIgnored private(set) var drafts: [UUID: String] = [:]
    /// Images waiting to go with each chat's next message.
    @ObservationIgnored var pendingImages: [UUID: [PendingImage]] = [:]

    @ObservationIgnored private var composers: [UUID: MobileComposerDraft<PendingImage>] = [:]

    func composer(for chat: UUID) -> MobileComposerDraft<PendingImage> {
        if let existing = composers[chat] { return existing }
        let state = MobileComposerDraft(text: drafts[chat] ?? "", images: pendingImages[chat] ?? [],
            persistText: { [weak self] in self?.saveDraft($0, for: chat) },
            persistImages: { [weak self] in self?.pendingImages[chat] = $0.isEmpty ? nil : $0 })
        composers[chat] = state
        return state
    }

    func saveDraft(_ text: String, for chat: UUID) {
        drafts[chat] = text.isEmpty ? nil : text
        AppPreferences.defaults.set(Dictionary(uniqueKeysWithValues: drafts.map { ($0.key.uuidString, $0.value) }), forKey: "drafts")
    }

    var isPaired: Bool { connection != nil && token != nil }

    init() {
        if let data = AppPreferences.defaults.data(forKey: "connection") {
            connection = try? JSONDecoder().decode(Connection.self, from: data)
        }
        token = Keychain.read("token")
        let saved = AppPreferences.defaults.dictionary(forKey: "drafts") as? [String: String] ?? [:]
        drafts = Dictionary(uniqueKeysWithValues: saved.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } })
    }

    // MARK: - Pairing

    func pair(host: String, code: String) async throws {
        #if GOLEM_APP
        let body = try JSONEncoder().encode(Companion.PairRequest(code:code,deviceName:UIDevice.current.name,product:"golem"))
        #else
        let body = try JSONEncoder().encode(Companion.PairRequest(code: code, deviceName: UIDevice.current.name))
        #endif
        let (data, response) = try await URLSession.shared.data(for: request(host: host, path: "/v1/pair", method: "POST", body: body, token: nil))
        try checkStatus(data, response)
        let reply = try Companion.decoder.decode(Companion.PairResponse.self, from: data)
        var hosts = [host]
        for address in reply.addresses where !hosts.contains(address) { hosts.append(address) }
        token = reply.token
        Keychain.save("token", reply.token)
        connection = Connection(macName: reply.macName, hosts: hosts)
        saveConnection()
        problem = nil
        syncedPush = nil
        await syncPushRegistration(force: true)
    }

    func forget() {
        // Capture the authenticated request before erasing pairing. Best effort; removing
        // the device on the Mac always revokes it, even when this phone is offline.
        if let host = connection?.hosts.first, let token {
            let revoke = request(host: host, path: "/v1/push", method: "DELETE", body: nil, token: token)
            URLSession.shared.dataTask(with: revoke).resume()
        }
        syncedPush = nil

        Keychain.delete("token")
        token = nil
        connection = nil
        chatList = nil
        AppPreferences.defaults.removeObject(forKey: "connection")
    }

    // MARK: - Calls

    func loadChats() async {
        do {
            chatList = try await call("/v1/chats")
            await syncPushRegistration()
            if Date().timeIntervalSince(addressesChecked) > 60 { await refreshAddresses() }
        } catch {
            note(error)
        }
    }

    @ObservationIgnored private var syncedPush: Companion.PushRegistration?
    @ObservationIgnored private var pushSyncing = false
    @ObservationIgnored private var pushChecked = Date.distantPast
    func syncPushRegistration(force: Bool = false) async {
        guard isPaired, !pushSyncing else { return }
        let service = MobilePushNotifications.shared
        guard let registration = service.registration,
              force || registration != syncedPush && Date().timeIntervalSince(pushChecked) > 30 else { return }
        pushSyncing = true; pushChecked = Date()
        defer { pushSyncing = false }
        do {
            let body = try JSONEncoder().encode(registration)
            _ = try await raw("/v1/push", method: "POST", body: body)
            syncedPush = registration
            service.synced()
        } catch { service.syncFailed(error) }
    }

    @ObservationIgnored private var addressesChecked = Date.distantPast

    /// Learns the Mac's current addresses, such as its Tailscale one if Tailscale was off when
    /// this phone paired, so it can still reach the Mac away from home.
    static func isTailscale(_ host: String) -> Bool {
        let parts = host.split(separator: ".").compactMap { Int($0) }
        return (parts.count == 4 && parts[0] == 100 && (64...127).contains(parts[1])) || host.lowercased().hasPrefix("fd7a:115c:a1e0")
    }

    private func refreshAddresses() async {
        addressesChecked = Date()
        guard var connection, let reply: Companion.Addresses = try? await call("/v1/addresses") else { return }
        let new = reply.addresses.filter { !connection.hosts.contains($0) }
        guard !new.isEmpty else { return }
        connection.hosts += new
        self.connection = connection
        saveConnection()
    }

    enum DetailResult {
        case unchanged
        case detail(Companion.ChatDetail)
    }

    func detail(_ id: UUID, since revision: Int?) async throws -> DetailResult {
        let path = "/v1/chats/\(id.uuidString)" + (revision.map { "?since=\($0)" } ?? "")
        let data = try await raw(path)
        if let unchanged = try? Companion.decoder.decode(Companion.Unchanged.self, from: data), unchanged.unchanged {
            return .unchanged
        }
        return .detail(try Companion.decoder.decode(Companion.ChatDetail.self, from: data))
    }

    /// `now` stops the agent and sends right away ("Send Now").
    func send(_ text: String, images: [Companion.Upload] = [], now: Bool = false, to id: UUID) async throws -> Companion.ChatDetail {
        let body = try JSONEncoder().encode(Companion.SendRequest(text: text, images: images.isEmpty ? nil : images, now: now ? true : nil))
        return try await call("/v1/chats/\(id.uuidString)/messages", method: "POST", body: body)
    }

    func stop(_ id: UUID) async throws -> Companion.ChatDetail {
        try await call("/v1/chats/\(id.uuidString)/stop", method: "POST", body: Data("{}".utf8))
    }

    /// "approved", "approvedForSession", or "denied".
    func decide(_ decision: String, item: UUID, in chat: UUID) async throws -> Companion.ChatDetail {
        let body = try JSONEncoder().encode(Companion.DecisionRequest(decision: decision))
        return try await call("/v1/chats/\(chat.uuidString)/approvals/\(item.uuidString)", method: "POST", body: body)
    }

    /// nil skips the questions.
    func answer(_ answers: [String: [String]]?, item: UUID, in chat: UUID) async throws -> Companion.ChatDetail {
        let body = try JSONEncoder().encode(Companion.AnswersRequest(answers: answers))
        return try await call("/v1/chats/\(chat.uuidString)/answers/\(item.uuidString)", method: "POST", body: body)
    }

    // MARK: Chat settings and management

    func newChat(in studio: UUID?, backend: String?) async throws -> Companion.ChatDetail {
        let body = try JSONEncoder().encode(Companion.NewChatRequest(studio: studio, backend: backend))
        return try await call("/v1/chats", method: "POST", body: body)
    }

    func change(_ settings: Companion.SettingsRequest, in chat: UUID) async throws -> Companion.ChatDetail {
        try await call("/v1/chats/\(chat.uuidString)/settings", method: "POST", body: try JSONEncoder().encode(settings))
    }

    func rename(_ chat: UUID, to title: String) async throws -> Companion.ChatDetail {
        try await call("/v1/chats/\(chat.uuidString)/rename", method: "POST", body: try JSONEncoder().encode(Companion.RenameRequest(title: title)))
    }

    func setArchived(_ archived: Bool, chat: UUID) async throws -> Companion.ChatDetail {
        try await call("/v1/chats/\(chat.uuidString)/\(archived ? "archive" : "unarchive")", method: "POST", body: Data("{}".utf8))
    }

    func fork(_ chat: UUID) async throws -> Companion.ChatDetail {
        try await call("/v1/chats/\(chat.uuidString)/fork", method: "POST", body: Data("{}".utf8))
    }

    /// Opens an app, file, or Shortcut pin on the Mac.
    func openOnMac(_ pin: Companion.Pin) async throws {
        _ = try await raw("/v1/pins/\(pin.id.uuidString)/open", method: "POST", body: Data("{}".utf8))
    }

    func setInstructions(_ text: String, studio: UUID) async throws {
        chatList = try await call("/v1/studios/\(studio.uuidString)/instructions", method: "POST",
                                  body: try JSONEncoder().encode(Companion.InstructionsRequest(text: text)))
    }

    func sendQueuedNow(_ item: UUID, in chat: UUID) async throws -> Companion.ChatDetail {
        try await call("/v1/chats/\(chat.uuidString)/queued/\(item.uuidString)/now", method: "POST", body: Data("{}".utf8))
    }

    func avatarList() async throws -> Companion.AvatarList {
        try Companion.decoder.decode(Companion.AvatarList.self, from: await raw("/v1/avatar"))
    }
    #if GOLEM_APP
    func golemJournal() async throws -> Data{try await raw("/v1/golem/journal")}
    func markGolemRead(_ item:UUID) async throws {
        _ = try await raw("/v1/golem/read",method:"POST",body:JSONSerialization.data(withJSONObject:["itemID":item.uuidString]))
    }
    func golemPaused() async throws -> Bool {
        let data=try await raw("/v1/golem/health")
        return (try JSONSerialization.jsonObject(with:data) as? [String:Any])?["paused"] as? Bool ?? false
    }
    func golemPreferences() async throws -> [String:Bool] {
        let data=try await raw("/v1/golem/health")
        return (try JSONSerialization.jsonObject(with:data) as? [String:Any])?["preferences"] as? [String:Bool] ?? [:]
    }
    func golemControl(_ operation:String,body:[String:Any]=[:]) async throws {
        let data=try JSONSerialization.data(withJSONObject:["id":UUID().uuidString,"operation":operation,"body":body])
        _ = try await raw("/v1/golem/control",method:"POST",body:data)
    }
    func golemAvailability() async throws -> Bool {
        let data=try await raw("/v1/golem/status")
        return (try JSONSerialization.jsonObject(with:data) as? [String:Bool])?["available"] ?? false
    }
    #endif

    func avatarFile(_ name: String) async throws -> Data {
        try await raw("/v1/avatar/" + (name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name))
    }

    func file(_ file: Companion.File, in chat: UUID) async throws -> Data {
        try await raw("/v1/chats/\(chat.uuidString)/files/\(file.id.uuidString)")
    }

    /// Writes the network response to disk, then atomically installs a validated local PDF.
    func downloadPDF(_ file: Companion.File, in chat: UUID,
                     progress: @escaping @MainActor @Sendable (Int64, Int64) -> Void) async throws -> MobilePDFCache.Entry {
        guard let connection, let token else { throw MobileError(message: "Pair this device with your Mac to download the PDF.") }
        var lastError: Error = MobileError(message: "Couldn't reach \(connection.macName).")
        for host in connection.hosts {
            try Task.checkCancellation()
            do {
                var req = request(host: host, path: "/v1/chats/\(chat.uuidString)/files/\(file.id.uuidString)", method: "GET", body: nil, token: token)
                req.timeoutInterval = 120
                let (temporary, response) = try await URLSession.shared.download(for: req, delegate: PDFDownloadProgress(update: progress))
                defer { try? FileManager.default.removeItem(at: temporary) }
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    if http.statusCode == 401 { forget() }
                    let handle = try? FileHandle(forReadingFrom: temporary)
                    let data = (try? handle?.read(upToCount: 65_536)) ?? Data()
                    try? handle?.close()
                    try checkStatus(data, response)
                }
                try Task.checkCancellation()
                let entry = try await Task.detached { try MobilePDFCache.save(temporary, file: file, chat: chat) }.value
                if host != connection.hosts.first { moveToFront(host) }
                return entry
            } catch let error as MobileError { throw error }
            catch {
                try Task.checkCancellation()
                lastError = error
            }
        }
        throw MobileError(message: "Couldn't download from \(connection.macName). Check that Chatterbox is open and Wi-Fi or Tailscale is connected. \(lastError.localizedDescription)")
    }

    // MARK: - Plumbing

    private func call<T: Decodable>(_ path: String, method: String = "GET", body: Data? = nil) async throws -> T {
        try CompanionRetry.decode(T.self, data: try await raw(path, method: method, body: body), method: method)
    }

    /// Tries each known address until one answers, and remembers the one that did.
    private func raw(_ path: String, method: String = "GET", body: Data? = nil) async throws -> Data {
        guard let connection, let token else { throw MobileError(message: "This iPhone isn't paired.") }
        do {
            let result = try await CompanionRetry.load(hosts: connection.hosts, method: method, request: { host, probe in
                request(host: host, path: probe ? "/v1/addresses" : path,
                        method: probe ? "GET" : method, body: probe ? nil : body, token: token)
            }, validate: { data, response in
                if let http = response as? HTTPURLResponse, http.statusCode == 401 {
                    forget()
                    throw MobileError(message: "This iPhone was removed from Chatterbox on the Mac. Pair it again.")
                }
                try checkStatus(data, response)
            })
            if result.host != connection.hosts.first { moveToFront(result.host) }
            if problem != nil { problem = nil }
            return result.data
        } catch let error as MobileError {
            throw error
        } catch let error as CompanionRetry.Failure {
            throw MobileError(message: error.message)
        } catch {
            try Task.checkCancellation()
            let away = connection.hosts.contains(where: Self.isTailscale)
                ? "Away from home, Tailscale has to be on, on this phone and on the Mac."
                : "To reach it away from home, turn on Tailscale on the Mac and this phone, then open Chatterbox at home once."
            throw MobileError(message: "Can't reach \(connection.macName). Make sure it's awake and Chatterbox is open. \(away) (\(error.localizedDescription))")
        }
    }

    private func request(host: String, path: String, method: String, body: Data?, token: String?) -> URLRequest {
        let address = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        var request = URLRequest(url: URL(string: "http://\(address):\(Self.port)\(path)")!)
        // The chat revision protocol controls freshness; URLSession's HTTP cache must
        // never substitute an earlier transcript for an explicit refresh.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpMethod = method
        request.httpBody = body
        // Images take longer to send than a message.
        request.timeoutInterval = (body?.count ?? 0) > 200_000 ? 60 : 6
        if let token { request.setValue(token, forHTTPHeaderField: Companion.tokenHeader) }
        #if GOLEM_APP
        request.setValue("golem",forHTTPHeaderField:"X-Chatterbox-Product")
        #endif
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return request
    }

    /// Throws the Mac's error message when a call didn't succeed.
    private func checkStatus(_ data: Data, _ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, http.statusCode != 200 else { return }
        let message = (try? Companion.decoder.decode(Companion.ErrorResponse.self, from: data))?.error
        throw MobileError(message: message ?? "Chatterbox answered with error \(http.statusCode).")
    }

    /// Simulator tests reach a test copy of the Mac app on its own port, never the real one.
    private static var port: UInt16 {
        #if DEBUG
        if let test = ProcessInfo.processInfo.environment["CHATTERBOX_TEST_PORT"].flatMap(UInt16.init) { return test }
        #endif
        return Companion.port
    }

    private func moveToFront(_ host: String) {
        guard var connection else { return }
        connection.hosts.removeAll { $0 == host }
        connection.hosts.insert(host, at: 0)
        self.connection = connection
        saveConnection()
    }

    private func saveConnection() {
        if let data = try? JSONEncoder().encode(connection) { AppPreferences.defaults.set(data, forKey: "connection") }
    }

    private func note(_ error: Error) {
        problem = error.localizedDescription
    }
}

/// Finds Chatterbox on the same Wi-Fi with Bonjour, and turns what it finds into an address.
@MainActor
@Observable
final class MacFinder {
    struct Found: Identifiable, Hashable {
        var id: String { name }
        var name: String
        var endpoint: NWEndpoint
    }

    private(set) var found: [Found] = []
    @ObservationIgnored private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: Companion.serviceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.compactMap { result -> Found? in
                guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                return Found(name: name, endpoint: result.endpoint)
            }
            Task { @MainActor in self?.found = found.sorted { $0.name < $1.name } }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }

    /// Connects briefly to learn the Mac's IPv4 address.
    func address(of mac: Found) async -> String? {
        let parameters = NWParameters.tcp
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
        let connection = NWConnection(to: mac.endpoint, using: parameters)
        return await withCheckedContinuation { continuation in
            let once = Once(continuation, connection: connection)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if case .hostPort(let host, _) = connection.currentPath?.remoteEndpoint {
                        var text = "\(host)"
                        if let percent = text.firstIndex(of: "%") { text = String(text[..<percent]) }
                        once.finish(text)
                    } else {
                        once.finish(nil)
                    }
                case .failed, .cancelled:
                    once.finish(nil)
                default:
                    break
                }
            }
            connection.start(queue: .main)
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { once.finish(nil) }
        }
    }
}

/// Resumes a lookup once, whichever comes first: an answer, a failure, or the timeout.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String?, Never>?
    private let connection: NWConnection

    init(_ continuation: CheckedContinuation<String?, Never>, connection: NWConnection) {
        self.continuation = continuation
        self.connection = connection
    }

    func finish(_ value: String?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        guard let pending else { return }
        connection.cancel()
        pending.resume(returning: value)
    }
}

/// The pairing token, kept in the Keychain.
enum Keychain {
    #if GOLEM_APP
    private static let service="com.shelbyklein.Golem.mobile"
    #else
    private static let service = "com.shelbyklein.Chatterbox.mobile"
    #endif

    static func save(_ key: String, _ value: String) {
        delete(key)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: key, kSecValueData as String: Data(value.utf8),
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func read(_ key: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: key, kSecReturnData as String: true]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ key: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: key]
        SecItemDelete(query as CFDictionary)
    }
}

/// One open transcript, owned by navigation rather than the detail view's transient
/// SwiftUI tasks. Selecting a row always starts a request, even if the view is retained.
@MainActor
@Observable
final class MobileChatHistory {
    let id: UUID
    private(set) var detail: Companion.ChatDetail?
    private(set) var problem: String?
    private(set) var refreshing = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()

    init(id: UUID) { self.id = id }

    func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
        refreshing = false
    }

    /// A mutation's returned transcript supersedes any older GET still in flight.
    func apply(_ fresh: Companion.ChatDetail) {
        cancel()
        detail = fresh
        problem = nil
    }

    @discardableResult
    func refresh(in store: MobileStore, force: Bool = false) -> Task<Void, Never> {
        if let task, !force { return task }
        cancel()
        let token = UUID()
        generation = token
        refreshing = true
        let request = Task { @MainActor in
            defer {
                if generation == token { task = nil; refreshing = false }
            }
            do {
                let response = try await store.detail(id, since: force ? nil : detail?.revision)
                guard !Task.isCancelled, generation == token else { return }
                if case .detail(let fresh) = response { detail = fresh }
                problem = nil
            } catch {
                guard !Task.isCancelled, generation == token else { return }
                problem = error.localizedDescription
            }
        }
        task = request
        return request
    }
}
