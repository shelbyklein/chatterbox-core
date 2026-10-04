import Foundation

/// Shared by the app and ChatterboxHost: where the host lives and how the two talk.
///
/// The socket carries one JSON object per line. The app sends requests (`spawn`, `attach`,
/// `write`, `kill`, `forget`, `ack`, `list`, `detach`); the host sends `line`, `exit`, and
/// replies. A `line` frame is followed by the child's output line itself, byte for byte, so
/// the host never re-encodes what the agent printed.
enum HostPaths {
    /// `CHATTERBOX_HOST_DIR` moves everything, so tests never touch the real host.
    static var directory: URL {
        if let dir = ProcessInfo.processInfo.environment["CHATTERBOX_HOST_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Chatterbox/Host", isDirectory: true)
    }

    static let socketName = "host.sock"
    static var socket: URL { directory.appendingPathComponent(socketName) }
    static var logs: URL { directory.appendingPathComponent("logs", isDirectory: true) }
}

enum HostWire {
    /// One frame: the header line, then the raw line for `line` frames.
    static func frame(_ header: JSON, raw: Data? = nil) -> Data {
        var data = (try? header.encoded()) ?? Data("{}".utf8)
        data.append(0x0A)
        if let raw {
            data.append(raw)
            data.append(0x0A)
        }
        return data
    }
}

/// Splits a socket's byte stream into frames. Scans with a cursor and compacts once per
/// feed, so a chunk with thousands of lines stays linear.
struct HostFrameReader {
    struct Frame {
        var header: JSON
        var raw: Data?
    }

    private var buffer = Data()
    private var waitingHeader: JSON?

    mutating func feed(_ data: Data) -> [Frame] {
        buffer.append(data)
        var frames: [Frame] = []
        var start = buffer.startIndex
        while let newline = buffer[start...].firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: start..<newline)
            start = buffer.index(after: newline)
            if let header = waitingHeader {
                waitingHeader = nil
                frames.append(Frame(header: header, raw: line))
                continue
            }
            guard !line.isEmpty, let header = try? JSON.parse(line) else { continue }
            if header["op"]?.string == "line" {
                waitingHeader = header
            } else {
                frames.append(Frame(header: header))
            }
        }
        buffer = start == buffer.endIndex ? Data() : buffer.subdata(in: start..<buffer.endIndex)
        return frames
    }
}

/// Unix-domain socket helpers. `sun_path` holds only 104 bytes, so a longer path (a test's
/// deep temp folder) is reached relative to its folder instead.
enum UnixSocket {
    static func connect(to url: URL) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        let ok = withAddress(url) { addr, len in Darwin.connect(fd, addr, len) == 0 }
        if ok { return fd }
        close(fd)
        return nil
    }

    static func listen(at url: URL) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        unlink(url.path)
        let bound = withAddress(url) { addr, len in bind(fd, addr, len) == 0 }
        guard bound, chmod(url.path, 0o600) == 0, Darwin.listen(fd, 16) == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    /// Calls `body` with a sockaddr for `url`. For a path too long for `sun_path`, the working
    /// folder is switched to the socket's folder for the call. Only tests use such paths.
    private static func withAddress(_ url: URL, _ body: (UnsafePointer<sockaddr>, socklen_t) -> Bool) -> Bool {
        var path = url.path
        var restore: String?
        let limit = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1
        if path.utf8.count > limit {
            restore = FileManager.default.currentDirectoryPath
            guard FileManager.default.changeCurrentDirectoryPath(url.deletingLastPathComponent().path) else { return false }
            path = url.lastPathComponent
        }
        defer { if let restore { FileManager.default.changeCurrentDirectoryPath(restore) } }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            let bytes = Array(path.utf8.prefix(limit))
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }
}
