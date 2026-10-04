import Foundation

/// The retry envelope is separate from the body, so every mobile mutation uses the same
/// protection, including creates, forks, approvals and settings.
enum CompanionRetry {
    static let operationHeader = "X-Chatterbox-Operation"
    static let incarnationHeader = "X-Chatterbox-Incarnation"
    static let issuedHeader = "X-Chatterbox-Issued"
    static let versionHeader = "X-Chatterbox-Mutation-Version"
    static let version = "1"
    static let lifetime: TimeInterval = 600
    static let uncertain = "The Mac may have applied this action, but its reply couldn't be confirmed. Refresh and check the chat before trying again."

    struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    @MainActor static func decode<T: Decodable>(_ type: T.Type, data: Data, method: String) throws -> T {
        do { return try Companion.decoder.decode(type, from: data) }
        catch {
            // A 200 with an unreadable body still may represent an applied mutation.
            if method != "GET" && method != "HEAD" { throw Failure(message: uncertain) }
            throw error
        }
    }

    /// Preflight each endpoint before a mutation. A fallback must support the protocol and
    /// belong to the same running server, or it must not receive the uncertain POST.
    @MainActor static func load(
        hosts: [String], method: String,
        request: @MainActor (String, Bool) -> URLRequest,
        validate: @MainActor (Data, URLResponse) throws -> Void,
        send: @MainActor (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }
    ) async throws -> (data: Data, host: String) {
        let mutation = method != "GET" && method != "HEAD"
        let operation = UUID().uuidString
        var incarnation: String?
        var issued: String?
        var attempted = false
        var lastError: Error = Failure(message: "No saved Mac address is available.")
        func checkCancellation() throws {
            if mutation && attempted && Task.isCancelled { throw Failure(message: uncertain) }
            try Task.checkCancellation()
        }
        for host in hosts {
            try checkCancellation()
            var outgoing = request(host, false)
            if mutation {
                let capability: (Data, URLResponse)
                do { capability = try await send(request(host, true)) }
                catch {
                    try checkCancellation()
                    lastError = error
                    continue // Only a GET was attempted at this address.
                }
                try validate(capability.0, capability.1)
                let http = capability.1 as? HTTPURLResponse
                let supported = http?.value(forHTTPHeaderField: versionHeader) == version
                let epoch = http?.value(forHTTPHeaderField: incarnationHeader)
                let time = http?.value(forHTTPHeaderField: issuedHeader)
                let valid = supported && epoch.flatMap(UUID.init(uuidString:)) != nil && time.flatMap(Double.init)?.isFinite == true
                if attempted && (!valid || epoch != incarnation) { throw Failure(message: uncertain) }
                if !attempted, valid { incarnation = epoch; issued = time }
                if let incarnation, let issued {
                    outgoing.setValue(operation, forHTTPHeaderField: operationHeader)
                    outgoing.setValue(incarnation, forHTTPHeaderField: incarnationHeader)
                    outgoing.setValue(issued, forHTTPHeaderField: issuedHeader)
                }
            }
            try checkCancellation()
            let reply: (Data, URLResponse)
            do {
                attempted = true
                reply = try await send(outgoing)
            } catch {
                // A cancelled mutation may already have reached the Mac, too.
                if mutation && (incarnation == nil || Task.isCancelled) { throw Failure(message: uncertain) }
                try Task.checkCancellation()
                lastError = error
                continue
            }
            // HTTP failures are definitive; never retry those against another address.
            try validate(reply.0, reply.1)
            return (reply.0, host)
        }
        if mutation && attempted { throw Failure(message: uncertain) }
        throw lastError
    }
}
