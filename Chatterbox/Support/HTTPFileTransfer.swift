import Foundation
import Network

/// One bounded chunk at a time, off the UI thread. A slow reader never queues the whole file.
final class HTTPFileTransfer {
    private let connection: NWConnection
    private let url: URL
    private let contentType: String
    private let queue = DispatchQueue(label: "chatterbox.document-transfer", qos: .utility)
    private var handle: FileHandle?
    private var remaining: UInt64 = 0

    init(connection: NWConnection, url: URL, contentType: String) {
        self.connection = connection; self.url = url; self.contentType = contentType
    }

    func start() {
        queue.async {
            do {
                let file = try FileHandle(forReadingFrom: self.url)
                self.handle = file
                self.remaining = try file.seekToEnd()
                try file.seek(toOffset: 0)
                let header = "HTTP/1.1 200 OK\r\nContent-Type: \(self.contentType)\r\nContent-Length: \(self.remaining)\r\nConnection: close\r\n\r\n"
                self.connection.send(content: Data(header.utf8), completion: .contentProcessed { error in
                    self.queue.async { error == nil ? self.next() : self.finish() }
                })
            } catch {
                self.connection.send(content: HTTPResponse.error(404, "That file is missing or can't be read.").data,
                                     completion: .contentProcessed { _ in self.queue.async { self.finish() } })
            }
        }
    }

    private func next() {
        guard remaining > 0 else { return finish() }
        do {
            guard let data = try handle?.read(upToCount: Int(min(remaining, 65_536))), !data.isEmpty else { return finish() }
            remaining -= UInt64(data.count)
            connection.send(content: data, completion: .contentProcessed { error in
                self.queue.async { error == nil ? self.next() : self.finish() }
            })
        } catch { finish() }
    }

    private func finish() {
        try? handle?.close(); handle = nil
        connection.cancel()
    }
}
