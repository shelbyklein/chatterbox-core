import CryptoKit
import Foundation

/// Owned by the main-actor server. Reserving and executing are synchronous, so another
/// request cannot enter between lookup and the mutation. The process identity makes a
/// retry fail closed after a restart instead of re-executing on an empty ledger.
final class CompanionMutationLedger {
    let incarnation = UUID().uuidString
    private struct Entry {
        var fingerprint: String
        var issued: TimeInterval
        var response: HTTPResponse?
    }
    private var entries: [String: Entry] = [:]
    private var bytes = 0
    private let maxEntries: Int
    private let maxBytes: Int
    init(maxEntries: Int = 512, maxBytes: Int = 32 * 1_024 * 1_024) {
        self.maxEntries = maxEntries; self.maxBytes = maxBytes
    }

    func headers(now: Date = Date()) -> [String: String] {
        [CompanionRetry.versionHeader: CompanionRetry.version,
         CompanionRetry.incarnationHeader: incarnation,
         CompanionRetry.issuedHeader: String(now.timeIntervalSince1970)]
    }

    func respond(device: UUID, request: HTTPRequest, now: Date = Date(), execute: () -> HTTPResponse) -> HTTPResponse {
        let headers = request.headers
        guard let rawID = headers[CompanionRetry.operationHeader.lowercased()] else {
            if headers[CompanionRetry.incarnationHeader.lowercased()] != nil || headers[CompanionRetry.issuedHeader.lowercased()] != nil {
                return .error(409, CompanionRetry.uncertain)
            }
            return execute() // Legacy client with no retry envelope.
        }
        guard let id = UUID(uuidString: rawID),
              headers[CompanionRetry.incarnationHeader.lowercased()] == incarnation,
              let rawTime = headers[CompanionRetry.issuedHeader.lowercased()],
              let issued = Double(rawTime), issued.isFinite,
              issued <= now.timeIntervalSince1970 + 1,
              now.timeIntervalSince1970 - issued < CompanionRetry.lifetime else {
            return .error(409, CompanionRetry.uncertain)
        }
        // Eviction can only remove operations that the validation above will refuse.
        entries = entries.filter { _, entry in
            if now.timeIntervalSince1970 - entry.issued < CompanionRetry.lifetime { return true }
            bytes -= entry.response?.body.count ?? 0
            return false
        }
        let key = device.uuidString + ":" + id.uuidString
        var hash = SHA256()
        hash.update(data: Data((request.method + "\n" + request.path + "\n" + rawTime + "\n").utf8))
        for (name, value) in request.query.sorted(by: { $0.key < $1.key }) {
            hash.update(data: Data((name + "=" + value + "\n").utf8))
        }
        hash.update(data: request.body)
        let fingerprint = hash.finalize().map { String(format: "%02x", $0) }.joined()
        if let entry = entries[key] {
            guard entry.fingerprint == fingerprint else { return .error(409, "This operation ID was already used for a different request. " + CompanionRetry.uncertain) }
            return entry.response ?? .error(409, CompanionRetry.uncertain)
        }
        guard entries.count < maxEntries else {
            return .error(503, "Too many recent mobile actions. This action was not applied. Wait ten minutes and try again.")
        }
        entries[key] = Entry(fingerprint: fingerprint, issued: issued, response: nil)
        let response = execute()
        if response.fileURL == nil && response.body.count <= maxBytes - bytes {
            entries[key]?.response = response
            bytes += response.body.count
        } // Oversize replies keep the reservation; retry reports uncertainty, never repeats.
        return response
    }
}
