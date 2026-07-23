import Foundation

/// Minimal POSIX AF_UNIX helpers shared by the hook client and the in-app server.
/// Kept dependency-free and synchronous so the `--hook` client stays tiny and fast.
enum UnixSocket {

    /// Where the app listens and the hook client connects.
    static var socketPath: String {
        let dir = appSupportDir()
        return dir.appendingPathComponent("notch.sock").path
    }

    static func appSupportDir() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
        let dir = base.appendingPathComponent("ClaudeNotch", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Fill a sockaddr_un for `path`. Returns the address and its valid length.
    static func address(for path: String) -> (sockaddr_un, socklen_t) {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: capacity) { cptr in
                let maxLen = min(bytes.count, capacity - 1)
                for i in 0..<maxLen {
                    cptr[i] = CChar(bitPattern: bytes[i])
                }
                cptr[maxLen] = 0
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        return (addr, len)
    }

    /// Connect, send `data`, half-close, and read the reply to EOF. Synchronous;
    /// returns the decoded JSON reply or nil on any failure (fail-open for the client).
    /// `timeout` bounds how long we'll wait for the app to answer — short for
    /// observational hooks so they can never delay Claude Code, long for blocking ones.
    static func request(_ data: Data, timeout: TimeInterval = 5) -> [String: Any]? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        // Bound both send and receive so a stuck/absent app can't hang the hook process.
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var (addr, len) = address(for: socketPath)
        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
        }
        guard connected == 0, writeAll(fd, data) else { return nil }
        shutdown(fd, SHUT_WR)

        let reply = readToEnd(fd)
        guard !reply.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any]
    }

    // MARK: I/O

    /// Write all bytes to `fd`. Returns false on error.
    @discardableResult
    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        var remaining = data
        while !remaining.isEmpty {
            let n = remaining.withUnsafeBytes { raw -> Int in
                write(fd, raw.baseAddress, remaining.count)
            }
            if n <= 0 { return false }
            remaining.removeFirst(n)
        }
        return true
    }

    /// Read from `fd` until EOF (peer closed its write side). Blocks.
    static func readToEnd(_ fd: Int32, chunk: Int = 16_384) -> Data {
        var out = Data()
        var buf = [UInt8](repeating: 0, count: chunk)
        while true {
            let n = read(fd, &buf, chunk)
            if n > 0 { out.append(buf, count: n) }
            else { break } // 0 = EOF, <0 = error
        }
        return out
    }
}
