import ImageIO
import UniformTypeIdentifiers
import CryptoKit
import CoreGraphics
import Foundation
import Network
import Observation

/// Serves the Chatterbox iPhone app: the chat list, each chat's transcript, and sending
/// messages. It answers only the home network and Tailscale, only phones paired with the
/// code shown in Settings, and only while it's turned on there. It runs while Chatterbox is open.
@MainActor
@Observable
final class CompanionServer {
    static let shared = CompanionServer()

    struct Device: Codable, Identifiable, Equatable {
        var id = UUID()
        var name: String
        /// SHA-256 of the phone's token; the token itself isn't kept.
        var tokenHash: String
        var pairedAt = Date()
        var lastSeen: Date?
        var push: Companion.PushRegistration? = nil
        /// Which app paired, on pairings saved by older versions. Only Chatterbox's are kept.
        var product: String? = nil
    }

    static let enabledKey = "companionEnabled"
    private static let devicesKey = "companionDevices"

    private(set) var isRunning = false
    private(set) var problem: String?
    private(set) var devices: [Device] = []
    /// The code a phone enters to pair. A new one comes after each pairing and after
    /// too many wrong tries.
    private(set) var pairingCode = CompanionServer.newCode()

    @ObservationIgnored weak var model: AppModel?
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var failedPairings = 0
    @ObservationIgnored private let mutations = CompanionMutationLedger()

    private init() {
        if let data = AppPreferences.defaults.data(forKey: Self.devicesKey),
           let saved = try? JSONDecoder().decode([Device].self, from: data) {
            devices = Self.chatterboxDevices(saved)
        }
    }

    var isEnabled: Bool { AppPreferences.defaults.bool(forKey: Self.enabledKey) }

    /// Pairings another app made in older versions are dropped.
    static func chatterboxDevices(_ saved: [Device]) -> [Device] {
        saved.filter { ($0.product ?? "chatterbox") == "chatterbox" }
    }

    #if !CHATTERBOX_HEADLESS
    func refreshProjection() async {
        guard RuntimeClient.usesDaemon else{return}
        do {
            let status=try await RuntimeClient.shared.request("companionStatus")
            isRunning=status["running"]?.bool ?? false;problem=status["problem"]?.string
            pairingCode=status["pairingCode"]?.string ?? ""
            devices=try status["devices"]?.decode([Device].self) ?? []
            AppPreferences.defaults.set(status["enabled"]?.bool ?? false,forKey:Self.enabledKey)
        }catch{problem=error.localizedDescription;isRunning=false}
    }
    #endif

    /// CHATTERBOX_COMPANION_PORT keeps tests off the port the real app uses.
    static var port: UInt16 {
        ProcessInfo.processInfo.environment["CHATTERBOX_COMPANION_PORT"].flatMap(UInt16.init) ?? Companion.port
    }

    func setEnabled(_ on: Bool) {
        #if !CHATTERBOX_HEADLESS
        if RuntimeClient.usesDaemon {RuntimeClient.shared.command("companion",body:["enabled":.bool(on)]);return}
        #endif
        AppPreferences.defaults.set(on, forKey: Self.enabledKey)
        #if CHATTERBOX_HEADLESS
        try? RuntimePreferences.persistCurrent()
        #endif
        on ? start() : stop()
    }

    func start() {
        guard listener == nil else { return }
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: Self.port)!)
            // A test copy on its own port stays off Bonjour, so phones don't see a second Mac.
            if Self.port == Companion.port {
                listener.service = NWListener.Service(name: Host.current().localizedName ?? "Chatterbox", type: Companion.serviceType)
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in self?.listenerChanged(state) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            problem = "Couldn't start: \(error.localizedDescription)"
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    func newPairingCode() {
        #if !CHATTERBOX_HEADLESS
        if RuntimeClient.usesDaemon {RuntimeClient.shared.command("companion",body:["newCode":true]);return}
        #endif
        pairingCode = Self.newCode(); failedPairings = 0
    }

    func forget(_ device: Device) {
        #if !CHATTERBOX_HEADLESS
        if RuntimeClient.usesDaemon {RuntimeClient.shared.command("companion",body:["forget":.string(device.id.uuidString)]);return}
        #endif
        devices.removeAll { $0.id == device.id }
        saveDevices()
    }

    /// Where a phone can reach this Mac: its home-network and Tailscale addresses.
    static var addresses: [String] {
        var result: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let address = pointer.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            if ip != "127.0.0.1", allowed(ipv4: ip) { result.append(ip) }
        }
        // Tailscale (100.64.0.0/10) first: it works away from home too.
        return result.sorted { isTailscale($0) && !isTailscale($1) }
    }

    static func isTailscale(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        return parts.count == 4 && parts[0] == 100 && (64...127).contains(parts[1])
    }

    // MARK: - Connections

    private func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            isRunning = true
            problem = nil
        case .failed(let error):
            isRunning = false
            problem = "Stopped: \(error.localizedDescription)"
            listener = nil
        case .cancelled:
            isRunning = false
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        guard Self.isAllowed(connection.endpoint) else {
            connection.cancel()
            return
        }
        connection.start(queue: .main)
        receive(on: connection, buffer: Data())
    }

    /// Reads one request (headers, then a body up to its Content-Length), answers it, and closes.
    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return connection.cancel() }
                var buffer = buffer
                if let data { buffer.append(data) }
                if buffer.count > Companion.maxRequestBytes || error != nil { return connection.cancel() }
                switch HTTPRequest.parse(buffer) {
                case .request(let request):
                    let response = await self.respondAsync(to: request)
                    if let file = response.fileURL {
                        HTTPFileTransfer(connection: connection, url: file, contentType: response.contentType).start()
                    } else {
                        connection.send(content: response.data, completion: .contentProcessed { _ in connection.cancel() })
                    }
                case .invalid:
                    let response = HTTPResponse.error(400, "Bad request.")
                    connection.send(content: response.data, completion: .contentProcessed { _ in connection.cancel() })
                case .incomplete where isComplete:
                    connection.cancel()
                case .incomplete:
                    self.receive(on: connection, buffer: buffer)
                }
            }
        }
    }

    // MARK: - Routes

    func respondAsync(to request:HTTPRequest) async -> HTTPResponse {
        if request.method == "GET", request.path == "/v1/project-folders" {
            guard authorize(request) != nil else { return .error(401, "Pair this device again.") }
            let path = request.query["path"]
            return await Task.detached(priority: .userInitiated) {
                do { return HTTPResponse.json(try ChatPromotion.folders(at: path)) }
                catch { return HTTPResponse.error(400, error.localizedDescription) }
            }.value
        }
        let restartParts = request.path.split(separator: "/").map(String.init)
        if request.method == "POST", restartParts.count == 4,
           restartParts[0] == "v1", restartParts[1] == "chats", restartParts[3] == "restart" {
            guard let device = authorize(request) else { return .error(401, "Pair this device again.") }
            guard let model, let id = UUID(uuidString: restartParts[2]), let target = model.sessions.first(where: { $0.id == id }) else {
                return .error(404, "That session is gone.")
            }
            var response = await mutations.respondAsync(device: device.id, request: request) {
                guard !target.isRestartingThread, !target.awaitingHostResume else { return .error(409, "This thread is reconnecting. Try again shortly.") }
                await target.restartThread()
                guard target.threadRestartStatus?.hasPrefix("Thread restarted.") == true else {
                    return .error(409, target.threadRestartStatus ?? "Couldn't restart. History and draft are kept.")
                }
                return .json(CompanionMapper.detail(target, model: model))
            }
            response.headers.merge(mutations.headers()) { _, new in new }
            return response
        }
        let response = respond(to:request)
        guard let source = response.thumbnailSource else { return response }
        let side = response.thumbnailSize
        let fallback = response.fallbackFile
        let resized = await Task.detached(priority: .utility) { () -> (Data, String)? in
            guard let image = CGImageSourceCreateWithURL(source as CFURL, nil) else { return nil }
            let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any]
            let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
            let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
            // Already small enough: the original goes as it is.
            if fallback, width > 0, max(width, height) <= side { return nil }
            guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(image, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: side,
                  ] as CFDictionary) else { return nil }
            // Transparency (a logo, an icon) stays: PNG. Everything else: JPEG, much smaller.
            let alpha = properties?[kCGImagePropertyHasAlpha] as? Bool ?? false
            let type = alpha ? UTType.png : UTType.jpeg
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, thumbnail, alpha ? nil : [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { return nil }
            return (data as Data, alpha ? "image/png" : "image/jpeg")
        }.value
        if let (data, type) = resized { return HTTPResponse(status: 200, contentType: type, body: data) }
        if fallback { return HTTPResponse(status: 200, contentType: response.contentType, body: Data(), fileURL: source) }
        return .error(404, "That image preview is unavailable.")

    }

    func respond(to request: HTTPRequest) -> HTTPResponse {
        var response: HTTPResponse
        let mutation = request.method != "GET" && request.method != "HEAD"
        if mutation, request.path != "/v1/pair", let device = authorize(request) {
            response = mutations.respond(device: device.id, request: request) {
                route(request)
            }
        } else {
            response = route(request)
        }
        response.headers.merge(mutations.headers()) { _, new in new }
        return response
    }

    private func route(_ request: HTTPRequest) -> HTTPResponse {
        let parts = request.path.split(separator: "/").map(String.init)
        guard parts.first == "v1" else { return .error(404, "Not found") }
        if request.method == "POST", parts == ["v1", "pair"] { return pair(request) }
        guard let device = authorize(request) else { return .error(401, "This iPhone isn't paired. Pair it again in the app.") }
        if let index = devices.firstIndex(where: { $0.id == device.id }) {
            devices[index].lastSeen = Date()
        }
        if parts == ["v1", "push"] {
            if request.method == "DELETE" {
                clearPush(device.id)
                return .json(["ok": true])
            }
            if request.method == "POST" {
                guard var registration = try? Companion.decoder.decode(Companion.PushRegistration.self, from: request.body), registration.valid else {
                    return .error(400, "Invalid push registration.")
                }
                registration.token = registration.token.lowercased()
                guard let index = devices.firstIndex(where: { $0.id == device.id }) else { return .error(401, "Device revoked.") }
                devices[index].push = registration
                saveDevices()
                return .json(["ok": true])
            }
        }
        guard let model else { return .error(503, "Chatterbox is starting.") }

        switch (request.method, parts.count) {
        case ("GET", 2) where parts[1] == "chats":
            return .json(CompanionMapper.chatList(model))
        case ("GET", 3) where parts[1] == "chats":
            guard let session = session(parts[2]) else { return .error(404, "That session is gone.") }
            let since = request.query["since"].flatMap(Int.init)
            let revision = model.companionRevision(of: session.id)
            if let since, since == revision { return .json(Companion.Unchanged(revision: revision)) }
            return .json(CompanionMapper.detail(session, model: model))
        case ("DELETE", 3) where parts[1] == "chats":
            guard let session = session(parts[2]) else { return .error(404, "That session is gone.") }
            #if CHATTERBOX_HEADLESS
            do { try model.runtime.remove(session.id) }
            catch { return .error(503, "Couldn't delete the chat. Try again after reconnecting.") }
            #else
            model.delete(session)
            #endif
            return .json(["ok": true])
        case ("POST", 4) where parts[1] == "chats" && parts[3] == "messages":
            guard let session = session(parts[2]) else { return .error(404, "That session is gone.") }
            guard !session.isRestartingThread else { return .error(409, "This thread is reconnecting. Your message wasn't sent; try again when it's ready.") }
            guard let body = try? Companion.decoder.decode(Companion.SendRequest.self, from: request.body) else {
                return .error(400, "Bad request.")
            }
            var images: [Attachment] = []
            for upload in body.images ?? [] {
                do { images.append(try Attachments.importImageData(upload.data, name: upload.name)) } catch {
                    return .error(400, "Couldn't read \(upload.name): \(error.localizedDescription)")
                }
            }
            guard !body.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty else {
                return .error(400, "Nothing to send.")
            }
            if body.now == true { session.sendNow(body.text, attachments: images) } else { session.send(body.text, attachments: images) }
            return .json(CompanionMapper.detail(session, model: model))
        case ("POST", 2) where parts[1] == "chats":
            let body = (try? Companion.decoder.decode(Companion.NewChatRequest.self, from: request.body)) ?? .init()
            // Starting a chat from the phone leaves the Mac showing what it was (newSession).
            let session: ChatSession
            do { session = try newSession(project: body.project, studio: body.studio, backend: body.backend.flatMap(Backend.init(rawValue:))) }
            catch { return (error as? Failure)?.response ?? .error(503, "Could not save the new chat.") }
            if let id = body.preset {
                guard let preset = ModelPresets.shared.presets.first(where: { $0.id == id }) else { return .error(404, "That preset is gone.") }
                ModelPresets.shared.apply(preset, to: session)
            }
            if let settings = body.settings { CompanionMapper.apply(settings, to: session) }
            if let title = body.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { session.setTitle(title) }
            if body.desk == true {
                // Put on the Desk: a task linked to it, named from its first message.
                do { _ = try DeskStore.shared.makeTask(.init(chatID: session.id, follow: true)) }
                catch { RuntimeHooks.note("The new chat couldn't go on the Desk: \(error.localizedDescription)") }
            }
            return .json(CompanionMapper.detail(session, model: model))
        case ("GET", 2) where parts[1] == "desk":
            return .json(DeskStore.shared.snapshot())
        case ("POST", 2) where parts[1] == "desk":
            guard let body = try? Companion.decoder.decode(Companion.DeskAddRequest.self, from: request.body) else { return .error(400, "Say what needs doing.") }
            do { try DeskStore.shared.add(body) } catch { return failure(error) }
            return .json(DeskStore.shared.snapshot())
        case ("GET", 3) where parts[1] == "desk" && parts[2] == "places":
            return .json(DeskStore.shared.places())
        case ("POST", 3) where parts[1] == "desk" && (parts[2] == "silence" || parts[2] == "unsilence"):
            guard let body = try? Companion.decoder.decode(Companion.DeskSilenceRequest.self, from: request.body) else {
                return .error(400, "Say what to \(parts[2]).")
            }
            if parts[2] == "silence" { DeskStore.shared.silence(body) } else { DeskStore.shared.unsilence(body) }
            return .json(DeskStore.shared.snapshot())
        case ("POST", 3) where parts[1] == "desk" && (parts[2] == "complete" || parts[2] == "reopen"):
            // The board's Mark complete (archives, into Done) and Reopen (unarchives).
            guard let body = try? Companion.decoder.decode(Companion.DeskSessionRequest.self, from: request.body) else { return .error(400, "Say which session.") }
            do {
                if parts[2] == "complete" { try DeskStore.shared.complete(body.chatID) } else { try DeskStore.shared.reopen(body.chatID) }
            } catch { return failure(error) }
            return .json(DeskStore.shared.snapshot())
        case ("POST", 3) where parts[1] == "desk" && parts[2] == "origin":
            // What a task's source (ClickUp, an email) says now (plans/source-linked-tasks.md).
            guard let body = try? Companion.decoder.decode(Companion.DeskOriginReport.self, from: request.body) else { return .error(400, "Say which source and its status.") }
            do { try DeskStore.shared.reportOrigin(body) } catch { return failure(error) }
            return .json(DeskStore.shared.snapshot())
        case ("POST", 3) where parts[1] == "desk" && parts[2] == "check-sources":
            do {
                try DeskStore.shared.checkSources()
                return .json(DeskStore.shared.snapshot())
            } catch { return failure(error) }
        case ("POST", 3) where parts[1] == "desk" && parts[2] == "task":
            // Make this a task (from a thread): a new task, already linked to it.
            guard let body = try? Companion.decoder.decode(Companion.DeskTaskRequest.self, from: request.body) else { return .error(400, "Say which session.") }
            do { try DeskStore.shared.makeTask(body) } catch { return failure(error) }
            return .json(DeskStore.shared.snapshot())
        case ("POST", 4) where parts[1] == "desk" && (parts[3] == "link" || parts[3] == "unlink" || parts[3] == "hold" || parts[3] == "resume"):
            // Link a thread to a task, or unlink it (back to To do).
            guard let id = UUID(uuidString: parts[2]) else { return .error(404, "That task is gone.") }
            do {
                if parts[3] == "hold" {
                    try DeskStore.shared.hold(id)
                } else if parts[3] == "resume" {
                    try DeskStore.shared.resume(id)
                } else if parts[3] == "unlink" {
                    try DeskStore.shared.unlink(id)
                } else {
                    guard let body = try? Companion.decoder.decode(Companion.DeskLinkRequest.self, from: request.body) else { return .error(400, "Say which session.") }
                    try DeskStore.shared.link(id, body)
                }
            } catch { return failure(error) }
            return .json(DeskStore.shared.snapshot())
        case ("GET", 4) where parts[1] == "chats" && parts[3] == "work":
            guard let session = session(parts[2]) else { return .error(404, "That session is gone.") }
            let front = session.record.workOf.flatMap { id in model.sessions.first { $0.id == id } } ?? session
            return .json(DeskStore.shared.workThreads(of: front))
        case ("POST", 4) where parts[1] == "chats" && parts[3] == "work":
            // Start a work thread (plans/work-threads.md): you stay in the front thread.
            guard let session = session(parts[2]) else { return .error(404, "That session is gone.") }
            guard let body = try? Companion.decoder.decode(Companion.WorkStartRequest.self, from: request.body) else {
                return .error(400, "Name the work thread and give it a brief.")
            }
            do { return .json(CompanionMapper.detail(try DeskStore.shared.startWork(from: session, body, source: "you"), model: model)) }
            catch { return failure(error) }
        case ("GET", 4) where parts[1] == "desk" && parts[3] == "threads":
            // ?place=<a Studio's or project's id, or "loose">; else where it was proposed. all=1: every thread there.
            guard let id = UUID(uuidString: parts[2]) else { return .error(404, "That request is gone.") }
            var place: Companion.DeskPlace?
            if let wanted = request.query["place"] {
                guard let found = wanted == "loose" ? DeskStore.loose : DeskStore.shared.places().first(where: { $0.id?.uuidString.lowercased() == wanted.lowercased() }) else {
                    return .error(404, "That place is gone.")
                }
                place = found
            }
            do { return .json(try DeskStore.shared.threads(for: id, place: place, all: request.query["all"] == "1")) } catch { return failure(error) }
        case ("POST", 4) where parts[1] == "desk" && (parts[3] == "start" || parts[3] == "ignore" || parts[3] == "done" || parts[3] == "writeback"):
            guard let id = UUID(uuidString: parts[2]) else { return .error(404, "That request is gone.") }
            do {
                if parts[3] == "writeback" {
                    // A card's offer to change its source (ClickUp, an email reply): an agent does it.
                    return .json(CompanionMapper.detail(try DeskStore.shared.writeBack(id), model: model))
                }
                if parts[3] == "ignore" {
                    try DeskStore.shared.ignore(id)
                    return .json(DeskStore.shared.snapshot())
                }
                if parts[3] == "done" {
                    try DeskStore.shared.markDone(id)
                    return .json(DeskStore.shared.snapshot())
                }
                guard let body = request.body.isEmpty ? Companion.DeskStartRequest() : try? Companion.decoder.decode(Companion.DeskStartRequest.self, from: request.body) else {
                    return .error(400, "Bad place.")
                }
                return .json(CompanionMapper.detail(try DeskStore.shared.start(id, body), model: model))
            } catch { return failure(error) }
        case ("GET", 2) where parts[1] == "automations":
            return .json(CompanionMapper.automations(model))
        case ("POST", 3) where parts[1] == "automations":
            guard let id = UUID(uuidString: parts[2]) else { return .error(404, "That automation is gone.") }
            guard let body = try? Companion.decoder.decode(Companion.AutomationEdit.self, from: request.body) else { return .error(400, "Bad change.") }
            do { return .json(try editAutomation(id, body)) } catch { return failure(error) }
        case ("POST", 4) where parts[1] == "automations" && parts[3] == "session":
            guard let id = UUID(uuidString: parts[2]) else { return .error(404, "That automation is gone.") }
            #if CHATTERBOX_HEADLESS
            guard let automation = ProjectAutomations.load().first(where: { $0.id == id }) else { return .error(404, "That automation is gone.") }
            guard let runner = AutomationRunner.shared else { return .error(503, "Automations aren't running yet.") }
            do { return .json(["threadID": try runner.reportSession(for: automation).id.uuidString]) } catch { return failure(error) }
            #else
            return .error(503, "Automations need the background service.")
            #endif
        case ("POST", 4) where parts[1] == "automations" && parts[3] == "run":
            guard let id = UUID(uuidString: parts[2]) else { return .error(404, "That automation is gone.") }
            do { return .json(CompanionMapper.detail(try runAutomation(id), model: model)) } catch { return failure(error) }
        case ("GET", 2) where parts[1] == "new-chat-options":
            // What a new chat would start with, given the picks so far: nothing is created.
            let picks = Companion.SettingsRequest(backend: request.query["backend"], model: request.query["model"],
                                                  effort: request.query["effort"], mode: request.query["mode"],
                                                  preset: request.query["preset"].flatMap(UUID.init(uuidString:)),
                                                  fastMode: request.query["fastMode"].map { $0 == "true" },
                                                  openModel: request.query["openModel"])
            // A project's: as its new Sidechat would start.
            let project = request.query["project"].flatMap(UUID.init(uuidString:)).flatMap { id in
                model.sessions.first { $0.id == id && $0.record.archivedAt == nil && $0.record.projectFolder != nil }
            }
            // chat=<id>: as that session would be with the picks (the Desk's Continue); nothing changes.
            if let chat = request.query["chat"] {
                guard let session = session(chat) else { return .error(404, "That session is gone.") }
                return .json(CompanionMapper.options(CompanionMapper.draftChat(picks, like: session)))
            }
            return .json(CompanionMapper.options(CompanionMapper.draftChat(picks, studio: request.query["studio"].flatMap(UUID.init(uuidString:)).flatMap(model.studio),
                                                                           project: project)))
        case ("GET", 2) where parts[1] == "presets":
            return .json(ModelPresets.shared.presets.map {
                Companion.PresetInfo(id: $0.id, nickname: nil, title: $0.title, backend: $0.backend.rawValue, summary: ModelPresets.summary($0))
            })
        case ("POST", 4) where parts[1] == "chats" && parts[3] == "settings":
            guard let session = session(parts[2]) else { return .error(404, "That session is gone.") }
            guard !session.isRestartingThread else { return .error(409, "This thread is reconnecting. Try changing its settings when it's ready.") }
            guard let body = try? Companion.decoder.decode(Companion.SettingsRequest.self, from: request.body) else { return .error(400, "Bad settings.") }
            CompanionMapper.apply(body, to: session)
            return .json(CompanionMapper.detail(session, model: model))
        case ("POST", 4) where parts[1] == "chats" && parts[3] == "rename":
            guard let session = session(parts[2]) else { return .error(404, "That session is gone.") }
            guard let body = try? Companion.decoder.decode(Companion.RenameRequest.self, from: request.body) else { return .error(400, "Bad name.") }
            session.setTitle(body.title)
            return .json(CompanionMapper.detail(session, model: model))
        case ("GET", 2) where parts[1] == "displays":
            return .json(CompanionMapper.displays())
        case ("GET", 2) where parts[1] == "usage":
            return usageResponse(refresh: request.query["refresh"] == "1")
        case ("GET", 2) where parts[1] == "pressure":
            // How hard the Mac is working, and what's held back (PressureMonitor); 404 where nothing monitors.
            guard let pressure = PressureHooks.snapshot() else { return .error(404, "Nothing is watching the Mac's load here.") }
            return .json(pressure)
        case ("POST", 5) where parts[1] == "chats" && parts[3] == "work" && parts[4] == "start-now":
            // A work thread waiting while the Mac is under pressure: start it anyway.
            guard let session = session(parts[2]) else { return .error(404, "That session is gone.") }
            guard session.record.pressureHold != nil else { return .error(409, "That work thread isn't waiting.") }
            session.startHeldNow()
            return .json(CompanionMapper.detail(session, model: model))
        case ("POST", 4) where parts[1] == "chats" && parts[3] == "pin":
            guard let session = session(parts[2]) else { return .error(404, "That session is gone.") }
            guard let body = try? Companion.decoder.decode(Companion.PinRequest.self, from: request.body) else { return .error(400, "Bad pin.") }
            model.setPinned(session, body.pinned)
            return .json(CompanionMapper.detail(session, model: model))
        case ("POST", 4) where parts[1] == "chats" && parts[3] == "brief":
            guard let session = session(parts[2]) else { return .error(404, "That session is gone.") }
            guard let body = try? Companion.decoder.decode(Companion.BriefRequest.self, from: request.body) else { return .error(400, "Bad brief.") }
            session.setBrief(body.brief)
            return .json(CompanionMapper.detail(session, model: model))
        case ("GET", 4) where parts[1] == "chats" && parts[3] == "organization":
            guard let session = session(parts[2]) else { return .error(404, "That session is gone.") }
            guard ChatPromotion.eligible(session) else { return .error(409, "Only ordinary, unarchived sessions can be promoted.") }
            return .json(Companion.PromotionOptions(currentFolder: session.workingFolder,
                studios: model.activeStudios.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                    .map { .init(id: $0.id, name: $0.name, folder: $0.folder) }))
        case ("POST", 4) where parts[1] == "chats" && parts[3] == "promote":
            guard let session = session(parts[2]) else { return .error(404, "That session is gone.") }
            guard let body = try? Companion.decoder.decode(Companion.PromotionRequest.self, from: request.body) else { return .error(400, "Choose a Studio or Project destination.") }
            #if CHATTERBOX_HEADLESS
            do { try model.runtime.promote(session, using: body) }
            catch { return .error(409, error.localizedDescription) }
            return .json(CompanionMapper.detail(session, model: model))
            #else
            return .error(503, "Promotion requires the updated Chatterbox background service.")
            #endif
        case ("POST", 4) where parts[1] == "chats" && (parts[3] == "archive" || parts[3] == "unarchive"):
            guard let session = session(parts[2]) else { return .error(404, "That session is gone.") }
            let shown = model.selectedID
            if parts[3] == "archive" { model.archive(session) } else { session.setArchived(false) }
            if let shown, shown != session.id, model.sessions.contains(where: { $0.id == shown }) { model.selectedID = shown }
            return .json(CompanionMapper.detail(session, model: model))
        case ("POST", 4) where parts[1] == "chats" && parts[3] == "sidequest":
            guard let session = session(parts[2]), !session.isSidequest, session.record.archivedAt == nil else { return .error(404, "That session is gone.") }
            guard let body = try? Companion.decoder.decode(Companion.SidequestRequest.self, from: request.body),
                  !body.task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .error(400, "Say what the sidequest should do.") }
            let shown = model.selectedID
            #if CHATTERBOX_HEADLESS
            let quest: ChatSession
            do { quest = try model.newSidequest(of: session, task: body.task) } catch { return .error(503, "Couldn't start the sidequest.") }
            #else
            model.newSidequest(of: session, task: body.task)
            let quest = session
            #endif
            if let shown { model.selectedID = shown }
            return .json(CompanionMapper.detail(quest, model: model))
        case ("POST", 4) where parts[1] == "chats" && parts[3] == "fork":
            guard let session = session(parts[2]) else { return .error(404, "That session is gone.") }
            let shown = model.selectedID
            guard let fork = model.fork(session) else { return .error(409, "This session can't be forked right now.") }
            if let shown { model.selectedID = shown }
            return .json(CompanionMapper.detail(fork, model: model))
        case ("POST", 4) where parts[1] == "pins" && parts[3] == "open":
            guard let id = UUID(uuidString: parts[2]), let pin = PinStore.shared.pins.first(where: { $0.id == id }) else {
                return .error(404, "That pin is gone.")
            }
            // Opens on the Mac's screen, as clicking it there would.
            PinStore.shared.open(pin)
            return .json(Companion.Unchanged(unchanged: false, revision: 0))
        case ("POST", 4) where parts[1] == "studios" && parts[3] == "instructions":
            guard let id = UUID(uuidString: parts[2]), model.studio(id) != nil else { return .error(404, "That Studio is gone.") }
            guard let body = try? Companion.decoder.decode(Companion.InstructionsRequest.self, from: request.body) else { return .error(400, "Bad request.") }
            model.setInstructions(body.text, forStudio: id)
            return .json(CompanionMapper.chatList(model))
        case ("POST", 4) where parts[1] == "chats" && parts[3] == "stop":
            guard let session = session(parts[2]) else { return .error(404, "That session is gone.") }
            if session.canStop { session.interrupt() }
            return .json(CompanionMapper.detail(session, model: model))
        case ("POST", 5) where parts[1] == "chats" && parts[3] == "approvals":
            guard let session = session(parts[2]), let itemID = UUID(uuidString: parts[4]) else { return .error(404, "That session is gone.") }
            guard let body = try? Companion.decoder.decode(Companion.DecisionRequest.self, from: request.body),
                  let decision = DisplayItem.ApprovalState(rawValue: body.decision),
                  [.approved, .approvedForSession, .denied].contains(decision) else { return .error(400, "Bad decision.") }
            guard session.items.contains(where: { $0.id == itemID && $0.approvalState == .pending }) else {
                return .error(409, "That was already answered.")
            }
            session.resolveApproval(itemID, decision)
            return .json(CompanionMapper.detail(session, model: model))
        case ("POST", 5) where parts[1] == "chats" && parts[3] == "answers":
            guard let session = session(parts[2]), let itemID = UUID(uuidString: parts[4]) else { return .error(404, "That session is gone.") }
            guard let body = try? Companion.decoder.decode(Companion.AnswersRequest.self, from: request.body) else { return .error(400, "Bad answers.") }
            guard session.items.contains(where: { $0.id == itemID && $0.approvalState == .pending }) else {
                return .error(409, "Those questions were already answered.")
            }
            session.answerQuestions(itemID, answers: body.answers)
            return .json(CompanionMapper.detail(session, model: model))
        case ("POST", 6) where parts[1] == "chats" && parts[3] == "queued" && parts[5] == "now":
            guard let session = session(parts[2]), let itemID = UUID(uuidString: parts[4]) else { return .error(404, "That session is gone.") }
            guard !session.isRestartingThread else { return .error(409, "This thread is reconnecting. That message wasn't sent; try again when it's ready.") }
            session.sendQueuedNow(itemID)
            return .json(CompanionMapper.detail(session, model: model))
        case ("GET", 2) where parts[1] == "addresses":
            return .json(Companion.Addresses(addresses: Self.addresses))
        case ("GET", 5) where parts[1] == "chats" && parts[3] == "thumbnail":
            guard let session = session(parts[2]), let id = UUID(uuidString: parts[4]),
                  let url = session.latestThumbnailURL(), ChatSession.mediaID(url.path) == id else {
                return .error(404, "That image preview is gone.")
            }
            return HTTPResponse(status: 200, contentType: "image/jpeg", body: Data(), thumbnailSource: url)
        case ("GET", 5) where parts[1] == "chats" && parts[3] == "files":
            guard let session = session(parts[2]), let fileID = UUID(uuidString: parts[4]) else { return .error(404, "That file is gone.") }
            // ?max=1200: a still image at most that many pixels on its longer side, for showing in
            // the chat; the original comes without it (viewing full screen, marking up, saving).
            let maxSide = request.query["max"].flatMap(Int.init).map { min(4096, max(200, $0)) }
            func send(_ url: URL, type: String) -> HTTPResponse {
                // A .gltf goes with the files it points to folded in: the phone gets only this one.
                if url.pathExtension.lowercased() == "gltf", let data = MediaKind.selfContainedModel(url) {
                    return HTTPResponse(status: 200, contentType: "model/gltf+json", body: data)
                }
                if let maxSide, MediaKind.isStillImage(url.path) {
                    return HTTPResponse(status: 200, contentType: type, body: Data(), thumbnailSource: url, thumbnailSize: maxSide, fallbackFile: true)
                }
                return HTTPResponse(status: 200, contentType: type, body: Data(), fileURL: url)
            }
            if let file = session.allAttachments.first(where: { $0.id == fileID }) { return send(file.url, type: file.mediaType) }
            // A file a reply points to: found once, then remembered (see referencedFile).
            if let url = referencedFile(fileID, in: session) {
                return send(url, type: url.pathExtension.lowercased() == "pdf" ? "application/pdf" : "application/octet-stream")
            }
            return .error(404, "That file is gone.")
        default:
            return .error(404, "Not found")
        }
    }

    /// Each chat's files its replies point to, by the id the phone asks for. Built once per
    /// change to the chat, not by reading every reply for each image the phone loads.
    private var referencedFiles: [UUID: (key: String, files: [UUID: URL])] = [:]
    private func referencedFile(_ id: UUID, in session: ChatSession) -> URL? {
        let key = "\(session.items.count)|\(session.items.last?.id.uuidString ?? "")|\(session.items.last?.phase.rawValue ?? "")|\(session.workingFolder ?? "")"
        if let cached = referencedFiles[session.id], cached.key == key { return cached.files[id] }
        var files: [UUID: URL] = [:]
        for item in session.items where item.kind == .assistant {
            for url in ChatSession.referencedMedia(in: item.text, folder: session.workingFolder) + ChatSession.referencedImages(in: item.text, folder: session.workingFolder) + CompanionDocuments.referenced(in: item.text, folder: session.workingFolder) {
                files[ChatSession.mediaID(url.path)] = url
            }
        }
        referencedFiles[session.id] = (key, files)
        return files[id]
    }

    /// The usage the phone shows: the limits the agents last reported here, and EasyCLIProxy's
    /// account quotas when it's set up (refreshed in the background when asked or stale).
    private func usageResponse(refresh: Bool) -> HTTPResponse {
        func windows(_ list: [UsageWindow]) -> [Companion.Usage.Window] {
            list.map { .init(label: $0.label, fraction: $0.utilization, resetsAt: $0.resetsAt) }
        }
        let proxy = ProxyQuotaStore.shared
        let configured = (try? ProxyQuotaStore.connection()) != nil
        if configured, refresh || proxy.lastRefresh.map({ Date().timeIntervalSince($0) > 300 }) ?? true, !proxy.refreshing {
            Task { await proxy.refresh() }
        }
        let accounts: [Companion.Usage.Account]? = configured ? proxy.accounts.map { account in
            .init(provider: account.provider, name: account.name, status: account.status,
                  windows: account.windows.map { .quota(label: $0.title, remainingPercent: $0.remaining, resetsAt: $0.reset) },
                  problem: account.problem)
        } : nil
        return .json(Companion.Usage(claude: windows(UsageLimits.shared.claude), codex: windows(UsageLimits.shared.codex),
                                     proxyAccounts: accounts, proxyProblem: configured ? proxy.problem : nil, proxyChecked: proxy.lastRefresh))
    }

    private func session(_ id: String) -> ChatSession? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        return model?.sessions.first { $0.id == uuid }
    }

    private func failure(_ error: Error) -> HTTPResponse {
        (error as? Failure)?.response ?? .error(503, error.localizedDescription)
    }

    /// Why a request couldn't be done, as the phone is told.
    struct Failure: LocalizedError {
        var status: Int
        var message: String
        var errorDescription: String? { message }
        var response: HTTPResponse { .error(status, message) }
    }

    /// A new session: a Sidechat of a project's session, a chat in a Studio, or one on its own.
    /// The Mac keeps showing what it was. New chats from the phone and the Desk start here.
    func newSession(project: UUID?, studio: UUID?, backend: Backend?) throws -> ChatSession {
        guard let model else { throw Failure(status: 503, message: "Chatterbox is starting.") }
        let shown = model.selectedID
        defer { if let shown, model.sessions.contains(where: { $0.id == shown }) { model.selectedID = shown } }
        let saveFailed = Failure(status: 503, message: "Could not save the new chat.")
        if let parentID = project {
            guard let parent = model.sessions.first(where: { $0.id == parentID }), parent.record.archivedAt == nil else {
                throw Failure(status: 404, message: "That project's session is gone.")
            }
            #if CHATTERBOX_HEADLESS
            do{return try model.newSidechat(of:parent)}catch{throw saveFailed}
            #else
            return model.newSidechat(of: parent)
            #endif
        } else if let id = studio {
            guard let studio = model.studio(id), studio.archivedAt == nil else { throw Failure(status: 404, message: "That Studio is gone.") }
            #if CHATTERBOX_HEADLESS
            do{return try model.newChat(in:studio,backend:backend)}catch{throw saveFailed}
            #else
            return model.newChat(in: studio, backend: backend)
            #endif
        } else {
            #if CHATTERBOX_HEADLESS
            do{return try model.newChat(backend:backend)}catch{throw saveFailed}
            #else
            return model.newChat(backend: backend)
            #endif
        }
    }

    // MARK: - Automations

    /// Changes a routine from the phone: every day of it, saved where the Mac's runner and its
    /// Automations screens read them. The app is told, so it doesn't save over the change.
    func editAutomation(_ id: UUID, _ change: Companion.AutomationEdit) throws -> Companion.AutomationRoutine {
        guard let model else { throw Failure(status: 503, message: "Chatterbox is starting.") }
        var change = change
        change.title = change.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard change.title?.isEmpty != true else { throw Failure(status: 400, message: "Give the automation a name.") }
        guard (change.instructions?.count ?? 0) <= 100_000 else { throw Failure(status: 400, message: "Those instructions are too long.") }
        if let days = change.days, days.isEmpty || !days.allSatisfy((1...7).contains) {
            throw Failure(status: 400, message: "Pick at least one day.")
        }
        guard (0...23).contains(change.hour ?? 0), (0...59).contains(change.minute ?? 0) else { throw Failure(status: 400, message: "That isn't a time.") }
        guard change.agent.map({ Backend(rawValue: $0) != nil }) ?? true else { throw Failure(status: 400, message: "Pick Claude or Codex.") }
        var all = ProjectAutomations.load()
        // The agent it already has isn't a change: its model and effort stay.
        if let agent = change.agent, let routine = ProjectAutomations.routines(in: all).first(where: { $0.contains { $0.id == id } }),
           CompanionMapper.agent(of: routine[0], model: model) == agent { change.agent = nil }
        guard let ids = ProjectAutomations.edit(id, change, in: &all) else { throw Failure(status: 404, message: "That automation is gone.") }
        do { try ProjectAutomations.save(all) } catch { throw Failure(status: 503, message: "Couldn't save the automation: \(error.localizedDescription)") }
        model.automationsChanged()
        guard let routine = ProjectAutomations.routines(in: all).first(where: { $0.contains { ids.contains($0.id) } }) else {
            throw Failure(status: 404, message: "That automation is gone.")
        }
        return CompanionMapper.routine(routine, state: ProjectAutomations.loadState(), model: model)
    }

    /// Runs a routine now, as Run Now on the Mac does, in a new session reporting to its
    /// project's. The day that ran last is the one run, so a run of it still going is left alone.
    func runAutomation(_ id: UUID, deskSources: Bool = false, includeNew: Bool = true) throws -> ChatSession {
        guard let model else { throw Failure(status: 503, message: "Chatterbox is starting.") }
        guard let routine = ProjectAutomations.routines(in: ProjectAutomations.load()).first(where: { $0.contains { $0.id == id } }) else {
            throw Failure(status: 404, message: "That automation is gone.")
        }
        #if CHATTERBOX_HEADLESS
        guard let runner = AutomationRunner.shared else { throw Failure(status: 503, message: "Automations aren't running yet.") }
        let state = ProjectAutomations.loadState()
        var latest = routine.max { (state[$0.id.uuidString]?.lastRun ?? .distantPast) < (state[$1.id.uuidString]?.lastRun ?? .distantPast) } ?? routine[0]
        if deskSources { latest.instructions = ProjectAutomations.deskSourceInstructions(latest.instructions, includeNew: includeNew) }
        let thread: UUID
        do { thread = try runner.run(latest, manual: true) } catch { throw Failure(status: 409, message: error.localizedDescription) }
        model.automationsChanged()
        guard let run = model.sessions.first(where: { $0.id == thread }) else { throw Failure(status: 503, message: "The run started, but its session isn't there.") }
        return run
        #else
        throw Failure(status: 503, message: "Automations run in Chatterbox's background service, which isn't running.")
        #endif
    }

    private func pair(_ request: HTTPRequest) -> HTTPResponse {
        guard isEnabled else { return .error(403, "The iPhone app is turned off in Chatterbox's Settings.") }
        guard let body = try? Companion.decoder.decode(Companion.PairRequest.self, from: request.body) else {
            return .error(400, "Bad request.")
        }
        guard body.code.trimmingCharacters(in: .whitespaces) == pairingCode else {
            failedPairings += 1
            if failedPairings >= 5 { newPairingCode() }
            return .error(403, "That code doesn't match. Check Chatterbox → Settings → iPhone.")
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        let name = body.deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        devices.append(Device(name: name.isEmpty ? "iPhone" : String(name.prefix(60)), tokenHash: Self.hash(token)))
        saveDevices()
        newPairingCode()
        return .json(Companion.PairResponse(token: token, macName: Host.current().localizedName ?? "Mac", addresses: Self.addresses))
    }

    /// A token for a connector (Claude, through ConnectorServer): paired like a phone, listed
    /// with the phones in Settings, and removed the same way.
    func issueToken(name: String) -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        devices.append(Device(name: String(name.prefix(60)), tokenHash: Self.hash(token)))
        saveDevices()
        return token
    }

    func device(forToken token: String) -> Device? {
        guard !token.isEmpty else { return nil }
        let hash = Self.hash(token)
        return devices.first { $0.tokenHash == hash }
    }

    private func authorize(_ request: HTTPRequest) -> Device? {
        guard let token = request.headers[Companion.tokenHeader.lowercased()], !token.isEmpty else { return nil }
        let hash = Self.hash(token)
        return devices.first { $0.tokenHash == hash }
    }

    func clearPush(_ device: UUID, token: String? = nil) {
        guard let index = devices.firstIndex(where: { $0.id == device }),
              token == nil || devices[index].push?.token == token else { return }
        devices[index].push = nil
        saveDevices()
    }

    private func saveDevices() {
        defer {
            #if CHATTERBOX_HEADLESS
            try? RuntimePreferences.persistCurrent()
            #endif
        }
        if let data = try? JSONEncoder().encode(devices) { AppPreferences.defaults.set(data, forKey: Self.devicesKey) }
    }

    // MARK: - Helpers

    private static func newCode() -> String { String(format: "%06d", Int.random(in: 0...999_999)) }

    private static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Only this Mac, the home network, and Tailscale may connect.
    private static func isAllowed(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address):
            let b = [UInt8](address.rawValue)
            return allowed(ipv4Bytes: b)
        case .ipv6(let address):
            let b = [UInt8](address.rawValue)
            guard b.count == 16 else { return false }
            if b[0..<10].allSatisfy({ $0 == 0 }), b[10] == 0xff, b[11] == 0xff { return allowed(ipv4Bytes: Array(b[12..<16])) }
            if b.dropLast().allSatisfy({ $0 == 0 }), b[15] == 1 { return true }       // ::1
            if b[0] == 0xfe, b[1] & 0xc0 == 0x80 { return true }                       // fe80::/10 link-local
            if b[0] & 0xfe == 0xfc { return true }                                     // fc00::/7, includes Tailscale's fd7a:115c:a1e0::/48
            return false
        default:
            return false
        }
    }

    private static func allowed(ipv4 ip: String) -> Bool {
        allowed(ipv4Bytes: ip.split(separator: ".").compactMap { UInt8($0) })
    }

    private static func allowed(ipv4Bytes b: [UInt8]) -> Bool {
        guard b.count == 4 else { return false }
        return b[0] == 127 || b[0] == 10 || (b[0] == 172 && (16...31).contains(b[1])) || (b[0] == 192 && b[1] == 168)
            || (b[0] == 169 && b[1] == 254) || (b[0] == 100 && (64...127).contains(b[1]))
    }
}

/// Turns chats into what the phone shows.
@MainActor
enum CompanionMapper {
    private static var lastCodexModelsTry = Date.distantPast

    static func chatList(_ model: AppModel) -> Companion.ChatList {
        var groups: [Companion.ChatGroup] = []
        let pinned = AppPreferences.defaults.stringArray(forKey: "macPinnedThreads") ?? []
        func summary(_ session: ChatSession) -> Companion.ChatSummary {
            Self.summary(session, revision: model.companionRevision(of: session.id), pinned: pinned)
        }
        if summaries.count > model.sessions.count * 2 {
            let ids = Set(model.sessions.map(\.id))
            summaries = summaries.filter { ids.contains($0.key) }
        }
        let projects = model.sidebarProjects
        if !projects.isEmpty {
            // Each project followed by its worktrees, as nested under it in the sidebar.
            let chats = projects.flatMap { [$0] + model.sidechats(of: $0) + model.worktrees(of: $0).flatMap { [$0] + model.sidechats(of: $0) } }
            groups.append(.init(id: "projects", kind: .projects, title: "Projects", chats: chats.map(summary)))
        }
        for studio in model.activeStudios {
            let chats = model.chats(in: studio).flatMap { model.studioFamily(of: $0) }
            groups.append(.init(id: "studio-" + studio.id.uuidString, kind: .studio, title: studio.name, chats: chats.map(summary),
                                studioID: studio.id, instructions: studio.instructions,
                                pins: nil))
        }
        let chats = model.sidebarChats.filter { !$0.items.isEmpty || $0.record.sidechatOf != nil || !model.sidechats(of: $0).isEmpty }
            .flatMap { [$0] + model.sidechats(of: $0) }
        if !chats.isEmpty { groups.append(.init(id: "chats", kind: .chats, title: "Chats", chats: chats.map(summary))) }
        var activity: [Companion.TurnCompletion] = []
        for session in model.sessions {
            activity.append(contentsOf: session.record.turnCompletions ?? [])
        }
        activity.sort { a, b in
            if a.endedAt == b.endedAt { return a.id.uuidString < b.id.uuidString }
            return a.endedAt > b.endedAt
        }
        return Companion.ChatList(revision: model.companionListRevision, groups: groups,
                                  pins: nil, activity: Array(activity.prefix(500)), pressure: PressureHooks.snapshot())
    }

    // MARK: Automations

    /// Every project's routines: the soonest to run first, then those switched off, by name.
    static func automations(_ model: AppModel) -> [Companion.AutomationRoutine] {
        let state = ProjectAutomations.loadState()
        return ProjectAutomations.routines(in: ProjectAutomations.load()).map { routine($0, state: state, model: model) }.sorted { a, b in
            switch (a.nextRunAt, b.nextRunAt) {
            case let (x?, y?) where x != y: x < y
            case (_?, nil): true
            case (nil, _?): false
            default: (a.title + "\u{0}" + a.project).localizedStandardCompare(b.title + "\u{0}" + b.project) == .orderedAscending
            }
        }
    }

    /// A routine's days (ProjectAutomations.routines) as the phone shows it: when it runs, who
    /// runs it, and its last run.
    static func routine(_ days: [ProjectAutomation], state: [String: AutomationRunState], model: AppModel, now: Date = Date()) -> Companion.AutomationRoutine {
        let first = days[0]
        let agent = agent(of: first, model: model)
        let modelName = first.model.map { id in
            agent == Backend.codex.rawValue ? CodexAppServer.shared.models.first { $0.model == id }?.displayName ?? id
                : ClaudeModels.shared.models.first { $0.value == id }?.displayName ?? id
        }
        let last = days.compactMap { day in state[day.id.uuidString].flatMap { run in run.lastRun.map { (at: $0, thread: run.threadID) } } }
            .max { $0.at < $1.at }
        let run = last?.thread.flatMap { id in model.sessions.first { $0.id == id } }
        let on = days.filter(\.enabled)
        let paused = Array(Set(days.filter { !$0.enabled }.map(\.weekday))).sorted()
        return .init(id: first.id, ids: days.map(\.id), title: first.title, instructions: first.instructions,
                     project: first.projectFolder.map { projectSession($0, model: model)?.projectName ?? URL(fileURLWithPath: $0).lastPathComponent } ?? "General",
                     projectFolder: first.projectFolder ?? "", reportSessionID: first.reportSessionID, reportSessionTitle: first.isGeneral ? first.reportingTitle : nil, agent: agent, model: modelName, effort: first.effort.map(RuntimePaths.effortLabel),
                     days: Array(Set(days.map(\.weekday))).sorted(), hour: first.hour, minute: first.minute,
                     enabled: !on.isEmpty, pausedDays: on.isEmpty || paused.isEmpty ? nil : paused,
                     lastRunAt: last?.at, lastThreadID: run?.id, lastResult: run?.lastActionSummary, isRunning: run?.isRunning,
                     nextRunAt: on.compactMap { ProjectAutomations.nextOccurrence(of: $0, after: now) }.min())
    }

    /// Who does an automation's runs: its own agent, its preset's, or else its project's.
    static func agent(of automation: ProjectAutomation, model: AppModel) -> String {
        if let folder = automation.projectFolder, let project = projectSession(folder, model: model) {
            return ChatSession.automationBackend(automation, project: project).rawValue
        }
        if automation.isGeneral {
            if let id = automation.reportSessionID, let report = model.sessions.first(where: { $0.id == id }) {
                return ChatSession.automationBackend(automation, project: report).rawValue
            }
            return (automation.backend.flatMap(Backend.init(rawValue:))
                ?? (automation.model == nil ? automation.preset.flatMap { id in ModelPresets.shared.presets.first { $0.id == id }?.backend } : nil)
                ?? Backend(rawValue: AppPreferences.defaults.string(forKey: "defaultBackend") ?? "") ?? .claude).rawValue
        }
        return automation.backend.flatMap(Backend.init(rawValue:))?.rawValue ?? Backend.claude.rawValue
    }

    /// A project's own session, where its automations report.
    private static func projectSession(_ folder: String, model: AppModel) -> ChatSession? {
        model.activeSessions.first { $0.record.projectFolder == folder && $0.record.worktreeOf == nil && $0.record.sidechatOf == nil }
    }

    static func pin(_ pin: Pin) -> Companion.Pin {
        .init(id: pin.id, title: pin.title, kind: pin.kind.rawValue,
              target: pin.kind == .website ? (PinStore.normalizedURL(pin.target)?.absoluteString ?? pin.target) : pin.target)
    }

    /// A worktree's session: its branch, which the session list names it by.
    static func worktreeBranch(_ session: ChatSession) -> String? {
        session.record.worktreeOf != nil ? (session.record.worktreeBranch ?? session.projectName) : nil
    }

    /// A project's own session: the project's name (its nickname, or its folder's).
    static func projectName(_ session: ChatSession) -> String? {
        session.record.projectFolder != nil ? session.projectName : nil
    }

    /// A session's name as the phone's session list shows it: its worktree's branch, its
    /// project's name, or its own title. Under a project's (or branch's) name, the session's
    /// own title, when that says more. The Desk names its cards this way.
    static func heading(_ session: ChatSession) -> (title: String, subtitle: String?) {
        let project = projectName(session)
        let title = worktreeBranch(session) ?? project ?? session.title
        guard let project else { return (title, nil) }
        let own = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let repeats = own.isEmpty || own == "New chat" || [title, project].contains { own.caseInsensitiveCompare($0) == .orderedSame }
        return (title, repeats ? nil : own)
    }

    /// Each session's summary as of its revision (see AppModel.companionRevision), kept up to a
    /// minute: turn counts and the thumbnail's file can change without one. The phone asks for
    /// every session's on each refresh, and working them all out again held the main thread.
    private static var summaries: [UUID: (revision: Int, running: Bool, made: Date, summary: Companion.ChatSummary)] = [:]

    /// `revision` caches it; without one it's worked out afresh.
    static func summary(_ session: ChatSession, revision: Int? = nil, pinned: [String]? = nil) -> Companion.ChatSummary {
        let running = session.isRunning || session.hasBackgroundWork
        var summary: Companion.ChatSummary
        if let revision, let cached = summaries[session.id], cached.revision == revision, cached.running == running,
           Date().timeIntervalSince(cached.made) < 60 {
            summary = cached.summary
        } else {
            summary = makeSummary(session)
            if let revision { summaries[session.id] = (revision, running, Date(), summary) }
        }
        summary.pinnedRank = (pinned ?? AppPreferences.defaults.stringArray(forKey: "macPinnedThreads") ?? []).firstIndex(of: session.id.uuidString)
        return summary
    }

    private static func makeSummary(_ session: ChatSession) -> Companion.ChatSummary {
        let activity = activity(session)
        return .init(id: session.id, title: session.title,
                     project: projectName(session),
                     subtitle: session.lastActionSummary,
                     backend: session.record.backend.rawValue,
                     isRunning: session.isRunning || session.hasBackgroundWork,
                     isWaitingOnYou: session.isWaitingOnYou,
                     updatedAt: session.record.updatedAt,
                     pins: nil,
                     worktreeBranch: worktreeBranch(session),
                     sidechatOf: session.record.sidechatOf,
                     sidequestOf: session.record.sidequestOf, sidequestTask: session.record.sidequestTask,
                     sidequestReturned: session.record.sidequestOf != nil ? session.record.sidequestReturned != nil : nil,
                     tags: session.tags.isEmpty ? nil : session.tags,
                     turnsToday: activity.day, turnsThisWeek: activity.week, turnsPerDay: activity.perDay,
                     thumbnail: thumbnail(session), turnStartedAt: session.isRunning ? session.record.turnStartedAt : nil,
                     canPromote: ChatPromotion.eligible(session), brief: session.record.brief,
                     workOf: session.record.workOf)
    }

    private static func thumbnail(_ session: ChatSession) -> Companion.File? {
        guard let url = session.latestThumbnailURL(),
              let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else { return nil }
        return .init(id: ChatSession.mediaID(url.path), name: url.lastPathComponent,
                     mediaType: "image/jpeg", isImage: true,
                     revision: "\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(values.fileSize ?? 0)")
    }

    /// Turns in the last day and week (from recorded turn times), and the lifetime average a day.
    private static func activity(_ session: ChatSession) -> (day: Int, week: Int, perDay: Double) {
        let now = Date()
        let dates = session.record.turnDates ?? []
        let day = dates.filter { now.timeIntervalSince($0) < 86_400 }.count
        let week = dates.filter { now.timeIntervalSince($0) < 7 * 86_400 }.count
        let items = session.items
        var turns = 0
        for index in items.indices where items[index].kind == .user { turns += 1 }
        let days = max(1, now.timeIntervalSince(session.record.createdAt) / 86_400)
        return (day, week, (Double(turns) / days * 10).rounded() / 10)
    }

    static func detail(_ session: ChatSession, model: AppModel) -> Companion.ChatDetail {
        // The newest rows, without copying a long transcript to count the rest.
        let items = session.items
        var shown: [DisplayItem] = [], total = 0
        for index in items.indices.reversed() where !(items[index].kind == .thought && items[index].text.isEmpty) {
            total += 1
            if shown.count < Companion.itemLimit { shown.append(items[index]) }
        }
        shown.reverse()
        let folder = session.workingFolder
        let revision = model.companionRevision(of: session.id)
        return .init(revision: revision, summary: summary(session, revision: revision),
                     settings: session.settingsDescription,
                     items: shown.map { item($0, folder: folder) }, earlierCount: total - shown.count,
                     options: options(session), isArchived: session.record.archivedAt != nil,
                     canFork: model.canFork(session),
                     turnStartedAt: session.isRunning ? session.record.turnStartedAt : nil,
                     backgroundTasks: session.backgroundTasks.map {
                         .init(id: $0.id, kind: $0.kind.rawValue, title: $0.title, detail: $0.detail, startedAt: $0.startedAt)
                     },
                     contextFraction: session.contextUsage[session.record.backend]?.fraction,
                     contextTokens: session.contextUsage[session.record.backend]?.used,
                     folder: session.workingFolder,
                     commands: commands(session).map { .init(name: $0.name, detail: $0.description, argumentHint: $0.argumentHint) },
                     nextSteps: NextSteps.shared.suggestions(for: session).nilIfEmpty,
                     work: session.record.workOf == nil ? DeskStore.shared.workThreads(of: session).nilIfEmpty : nil,
                     workOfTitle: session.record.workOf.flatMap { id in model.sessions.first { $0.id == id }?.title },
                     branch: branch(session), machine: session.runMachine?.name,
                     studio: session.record.studioID.flatMap { model.studio($0) }?.name,
                     tools: ThreadTools.shared.chips(for: session),
                     pressureWaiting: session.pressureWaitingText)
    }

    /// When git was last asked about each folder for the phone: the service doesn't open chats,
    /// so nothing else keeps its git status current.
    private static var gitAsked: [String: Date] = [:]
    private static func branch(_ session: ChatSession) -> String? {
        guard let folder = session.record.projectFolder else { return nil }
        if Date().timeIntervalSince(gitAsked[folder] ?? .distantPast) > 60 {
            gitAsked[folder] = Date()
            Task { await GitStatusStore.shared.refresh(folder) }
        }
        return GitStatusStore.shared.status(for: folder)?.branch
    }

    /// The chat's slash commands, or its Codex skills, as the Mac's "/" menu lists them.
    static func commands(_ session: ChatSession) -> [SlashCommand] {
        if session.record.backend == .codex {
            return session.record.codex.map { CodexAppServer.shared.skills[$0.folder] ?? [] } ?? []
        }
        return session.claudeCommands ?? ClaudeModels.shared.commands
    }

    private static var lastClaudeModelsTry = Date.distantPast
    private static func claudeOptionID(_ model: String) -> String {
        let models = ClaudeModels.shared.models
        guard !models.isEmpty, !models.contains(where: { $0.value == model }) else { return model }
        let info = ClaudeModels.shared.info(model)
        return models.contains(where: { $0.value == info.value }) ? info.value : model
    }

    static func options(_ session: ChatSession) -> Companion.ChatOptions {
        let isCodex = session.record.backend == .codex
        // The phone asking is reason enough to learn Codex's models, if nothing has yet.
        if CodexAppServer.shared.models.isEmpty, Date().timeIntervalSince(lastCodexModelsTry) > 60 {
            lastCodexModelsTry = Date()
            Task { try? await CodexAppServer.shared.ensureStarted(); try? await CodexAppServer.shared.refreshModels() }
        }
        // Same for Claude's: only the Mac's own screens loaded them, so the background service,
        // which answers the phone, had none, and Claude chats showed no models or efforts there.
        if ClaudeModels.shared.models.isEmpty, Date().timeIntervalSince(lastClaudeModelsTry) > 60 {
            lastClaudeModelsTry = Date()
            Task { await ClaudeModels.shared.refresh() }
        }
        let claude = ClaudeModels.shared.models.map {
            // Full names ("Opus 5.5"), as the Mac's chip says them; the description without the name.
            Companion.ModelOption(id: $0.value, name: $0.fullName, detail: $0.summary, efforts: $0.efforts, defaultEffort: nil)
        }
        let codex = [Companion.ModelOption(id: "", name: "Codex default", detail: "Whatever Codex uses when none is picked", efforts: [], defaultEffort: nil)]
            + CodexModelCatalog.entries(CodexAppServer.shared.models, chosen: session.record.codex?.model)
                .filter { $0.isCurrent || $0.model.model == session.record.codex?.model }.map { entry in
                Companion.ModelOption(id: entry.model.model, name: entry.name,
                                      detail: entry.isClaude ? "Claude, through the proxy" : (entry.model.isDefault ? "Codex's default" : ""),
                                      efforts: entry.model.efforts, defaultEffort: entry.model.defaultEffort)
            }
        // The PC's list, as the Mac's picker loads it (at most once a minute).
        Task { await PCModels.shared.refresh() }
        let open = PCModels.shared.models.map {
            Companion.ModelOption(id: $0, name: $0, detail: $0 == PCModels.recommended ? "On \(RemoteMachine.pc.name); fits its graphics card, fastest" : "On \(RemoteMachine.pc.name)",
                                  efforts: [], defaultEffort: nil)
        }
        let modes = PermissionModes.modes(for: session.record.backend).map {
            Companion.ModeOption(id: $0.id, title: $0.title, detail: $0.detail, systemImage: $0.systemImage, isUnrestricted: $0.isUnrestricted)
        }
        let presets: [Companion.PresetOption] = []
        return .init(backend: session.record.backend.rawValue,
                     // The phone matches by id: name the chat's model as the list does
                     // ("claude-opus-5-5" and "opus" can be the same entry).
                     model: isCodex ? (session.record.codex?.model ?? "") : claudeOptionID(session.record.model),
                     effort: isCodex ? (session.record.codex?.effort ?? "") : session.record.effort,
                     claudeModels: claude, codexModels: codex, modes: modes, mode: session.mode.id, presets: presets,
                     fastMode: session.supportsFastMode ? session.fastMode : nil,
                     openModels: PCModels.enabled ? open : nil, openModel: session.record.openModel)
    }

    /// A chat that's never saved, set up as a new one would be, then with `picks` applied:
    /// the phone shows its options while you choose, before anything is created.
    /// The Mac's displays, left to right, measured from the top left of their union.
    static func displays() -> [Companion.MacDisplay] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        // Mirrored displays show the same picture: keep one of each set.
        let frames = ids.prefix(Int(count)).filter { CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }.map(CGDisplayBounds)
        let union = frames.reduce(CGRect.null) { $0.union($1) }
        return frames.sorted { ($0.minX, $0.minY) < ($1.minX, $1.minY) }.map {
            .init(x: $0.minX - union.minX, y: $0.minY - union.minY, width: $0.width, height: $0.height)
        }
    }

    static func draftChat(_ picks: Companion.SettingsRequest, studio: Studio?, project: ChatSession? = nil) -> ChatSession {
        if let project {
            // A project's new Sidechat starts on its project's agent and settings.
            let draft = ChatSession(record: ChatSession.sidechatRecord(of: project, anchor: project, number: 1))
            apply(picks, to: draft)
            return draft
        }
        let defaults = AppPreferences.defaults
        var record = ConversationRecord(model: defaults.string(forKey: "defaultModel") ?? "default",
                                        effort: defaults.string(forKey: "defaultEffort") ?? "", personality: .friendly)
        record.activeBackend = Backend(rawValue: defaults.string(forKey: "defaultBackend") ?? "") ?? .claude
        record.claudeMode = PermissionModes.defaultClaude
        record.studioID = studio?.id
        record.studioFolder = studio?.folder
        let draft = ChatSession(record: record)
        // What a new one of these last used, as a new session would start.
        ModelSelection.startLikeLast(draft, kind: studio == nil ? .chats : .studios)
        if let id = picks.preset, let preset = ModelPresets.shared.presets.first(where: { $0.id == id }) {
            ModelPresets.shared.apply(preset, to: draft)
        }
        var rest = picks
        rest.preset = nil
        apply(rest, to: draft)
        return draft
    }

    /// What `session` would run on with `picks` applied, on a copy: the session is untouched
    /// (the Desk's Continue, choosing its model before it's sent).
    static func draftChat(_ picks: Companion.SettingsRequest, like session: ChatSession) -> ChatSession {
        var record = session.record
        record.id = UUID()
        // Settings only: no transcript to hand over when the agent changes.
        record.items = []
        record.claudeSessionID = nil
        record.codex?.threadId = nil
        let draft = ChatSession(record: record)
        apply(picks, to: draft)
        return draft
    }

    /// Changes a chat's settings the way the Mac's controls do.
    static func apply(_ change: Companion.SettingsRequest, to session: ChatSession) {
        if let backend = change.backend.flatMap(Backend.init(rawValue:)), backend != session.record.backend {
            session.setBackend(backend)
        }
        if let open = change.openModel {
            session.setOpenModel(open.isEmpty ? nil : open)
        } else if change.model != nil, session.record.openModel != nil {
            session.setOpenModel(nil)
        }
        let isCodex = session.record.backend == .codex
        if let model = change.model {
            if isCodex { session.setCodexModel(model.isEmpty ? nil : model) } else if !model.isEmpty { session.setModel(model) }
        }
        if let effort = change.effort {
            if isCodex { session.setCodexEffort(effort.isEmpty ? nil : effort) } else { session.setEffort(effort) }
        }
        if let mode = change.mode { session.setMode(mode) }
        if let fast = change.fastMode { session.setFastMode(fast) }
        if let id = change.preset, let preset = ModelPresets.shared.presets.first(where: { $0.id == id }) {
            ModelPresets.shared.apply(preset, to: session)
        }
    }

    /// A file's modification time and size, which change when it does.
    static func fileRevision(_ url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else { return nil }
        return "\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(values.fileSize ?? 0)"
    }

    static func item(_ item: DisplayItem, folder: String? = nil) -> Companion.Item {
        var mapped = plainItem(item)
        // Animations a final reply points to travel with it, to play on the phone.
        if item.kind == .assistant, item.phase == .final {
            mapped.attachments += ChatSession.referencedMedia(in: item.text, folder: folder).map {
                .init(id: ChatSession.mediaID($0.path), name: $0.lastPathComponent, mediaType: "application/octet-stream", isImage: false)
            }
            // Screenshots and renders it names, as pictures to view.
            // Their revision changes when the file does (a render redone under the same name),
            // so the phone's saved copy is replaced.
            mapped.attachments += ChatSession.referencedImages(in: item.text, folder: folder).map {
                .init(id: ChatSession.mediaID($0.path), name: $0.lastPathComponent, mediaType: "image/" + $0.pathExtension.lowercased(), isImage: true,
                      revision: fileRevision($0))
            }
        }
        var documents: [(URL, UUID)] = []
        for attachment in item.attachments ?? [] where attachment.url.pathExtension.lowercased() == "pdf" {
            documents.append((attachment.url, attachment.id))
            if let index = mapped.attachments.firstIndex(where: { $0.id == attachment.id }) {
                mapped.attachments[index] = CompanionDocuments.metadata(id: attachment.id, url: attachment.url, name: attachment.name)
            }
        }
        if item.kind == .assistant {
            for url in CompanionDocuments.referenced(in: item.text, folder: folder) {
                let id = documents.first(where: { $0.0.resolvingSymlinksInPath() == url })?.1 ?? ChatSession.mediaID(url.path)
                if !mapped.attachments.contains(where: { $0.id == id }) {
                    mapped.attachments.append(CompanionDocuments.metadata(id: id, url: url))
                }
                documents.append((url, id))
            }
        }
        mapped.text = CompanionDocuments.rewrite(mapped.text, folder: folder, documents: documents)
        return mapped
    }

    private static func plainItem(_ item: DisplayItem) -> Companion.Item {
        // Rows Chatterbox sent on its own read as a small line on the phone too.
        if item.kind == .user, item.automatic == true {
            return .init(id: item.id, kind: .notice, text: item.detail ?? "From Chatterbox", isStreaming: false, isCommentary: false,
                         toolState: nil, isPending: false, attachments: [], isQueued: false)
        }
        var text = item.text
        switch item.kind {
        case .questions:
            let asked = (item.questions ?? []).map(\.question).joined(separator: "\n")
            if !asked.isEmpty { text = asked }
        case .plan:
            text = item.planSteps.map { ($0.status == "completed" ? "✓ " : $0.status == "in_progress" ? "→ " : "○ ") + $0.step }.joined(separator: "\n")
        default:
            break
        }
        return .init(id: item.id, kind: Companion.Item.Kind(rawValue: item.kind.rawValue) ?? .notice, text: text,
                     isStreaming: item.phase == .streaming && item.kind == .assistant,
                     isCommentary: item.phase == .commentary,
                     toolState: item.kind == .tool ? item.toolState.rawValue : nil,
                     isPending: item.approvalState == .pending,
                     attachments: (item.attachments ?? []).map { .init(id: $0.id, name: $0.name, mediaType: $0.mediaType, isImage: $0.kind == .image) },
                     isQueued: item.queued == true,
                     approval: item.kind == .approval
                        ? .init(isPlan: item.approvalStyle == .plan, state: (item.approvalState ?? .expired).rawValue) : nil,
                     questions: item.questions?.map { q in
                         .init(id: q.id, header: q.header, question: q.question,
                               options: q.options.map { .init(label: $0.label, detail: $0.detail) },
                               multiSelect: q.multiSelect, isSecret: q.isSecret)
                     },
                     answers: item.answers,
                     detail: item.kind == .approval || item.kind == .shell ? item.detail.map { String($0.suffix(20_000)) } : nil,
                     planSteps: item.kind == .plan ? item.planSteps.map { .init(step: $0.step, status: $0.status) } : nil,
                     workedSeconds: item.workedSeconds)
    }
}

/// Just enough HTTP/1.1 for the app's requests.
struct HTTPRequest {
    var method: String
    var path: String
    var query: [String: String]
    var headers: [String: String]
    var body: Data

    enum Parse {
        /// More bytes are still coming.
        case incomplete
        /// Can never become a valid request (a bad request line or Content-Length).
        case invalid
        case request(HTTPRequest)
    }

    /// Parses a request once all of it has arrived. This runs before pairing or the token is
    /// checked, so anything malformed is rejected, never trusted.
    static func parse(_ data: Data) -> Parse {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return .incomplete }
        let head = String(decoding: data[..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let start = lines.removeFirst().split(separator: " ")
        guard start.count >= 2 else { return .invalid }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        // Only plain digits, within the request size limit ("-1", "+5", "1e3", "abc" are refused).
        let lengthText = headers["content-length"] ?? "0"
        guard !lengthText.isEmpty, lengthText.allSatisfy({ $0.isASCII && $0.isNumber }),
              let length = Int(lengthText), length <= Companion.maxRequestBytes else { return .invalid }
        let bodyStart = end.upperBound
        guard data.count - bodyStart >= length else { return .incomplete }
        let target = String(start[1])
        let components = URLComponents(string: target)
        return .request(HTTPRequest(
            method: String(start[0]), path: components?.path ?? target,
            query: Dictionary((components?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 }),
            headers: headers, body: Data(data[bodyStart..<(bodyStart + length)])))
    }
}

struct HTTPResponse {
    var status: Int
    var contentType: String
    var body: Data
    var fileURL: URL? = nil
    var thumbnailSource: URL? = nil
    /// The longest side of a resized image, in pixels.
    var thumbnailSize = 320
    /// When resizing isn't needed (or fails), send the original file instead of an error.
    var fallbackFile = false
    var headers: [String: String] = [:]

    static func json<T: Encodable>(_ value: T) -> HTTPResponse {
        HTTPResponse(status: 200, contentType: "application/json", body: (try? Companion.encoder.encode(value)) ?? Data())
    }

    static func error(_ status: Int, _ message: String) -> HTTPResponse {
        var response = json(Companion.ErrorResponse(error: message))
        response.status = status
        return response
    }

    var data: Data {
        let reason = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found",
                      409: "Conflict", 410: "Gone", 503: "Service Unavailable"][status] ?? "Error"
        let extra = headers.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)\r\n" }.joined()
        let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\(extra)\r\n"
        return Data(head.utf8) + body
    }
}
