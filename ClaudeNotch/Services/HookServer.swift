import Foundation

/// Listens on the unix socket for hook messages from the `--hook` client, dispatches
/// them to the main-actor `HookCoordinator`, and writes the reply back. The accept
/// loop and per-connection reads run on a background queue; only the coordinator call
/// touches the main actor.
final class HookServer: @unchecked Sendable {
    private let coordinator: HookCoordinator

    /// App-level control messages (`ping` / `show` / `quit`) the coordinator knows
    /// nothing about. Return nil to let the message fall through to the coordinator.
    var onAppControl: (@MainActor @Sendable (String) -> [String: Any]?)?

    private var listenFD: Int32 = -1
    private let queue = DispatchQueue(label: "com.ozan.ClaudeNotch.hookserver",
                                      qos: .userInitiated, attributes: .concurrent)

    init(coordinator: HookCoordinator) {
        self.coordinator = coordinator
    }

    /// Bind + listen, then start accepting. Returns false if the socket couldn't be created.
    @discardableResult
    func start() -> Bool {
        let path = UnixSocket.socketPath
        unlink(path)  // clear a stale socket from a previous run

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }

        var (addr, len) = UnixSocket.address(for: path)
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
        }
        guard bound == 0, listen(fd, 32) == 0 else { close(fd); return false }

        listenFD = fd
        queue.async { [weak self] in self?.acceptLoop(fd) }
        return true
    }

    func stop() {
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        unlink(UnixSocket.socketPath)
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let conn = accept(fd, nil, nil)
            if conn < 0 { break }               // listener closed → exit loop
            queue.async { [weak self] in self?.serve(conn) }
        }
    }

    private func serve(_ conn: Int32) {
        let data = UnixSocket.readToEnd(conn)
        guard
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { close(conn); return }

        // Control messages (e.g. answering a permission from the CLI) vs. hook events.
        if let control = obj["control"] as? String {
            let session = obj["session"] as? String ?? ""
            let decision = obj["decision"] as? String ?? ""
            Task { @MainActor [weak self] in
                guard let self else { close(conn); return }
                let reply: [String: Any] = self.onAppControl?(control)
                    ?? ["ok": self.coordinator.control(action: control,
                                                       session: session, decision: decision)]
                UnixSocket.writeAll(conn, (try? JSONSerialization.data(withJSONObject: reply)) ?? Data())
                close(conn)
            }
            return
        }

        let event = obj["event"] as? String ?? "Unknown"
        let payload = obj["payload"] as? [String: Any] ?? [:]

        Task { @MainActor [weak self] in
            guard let self else { close(conn); return }
            let reply = await self.coordinator.handle(event: event, payload: payload)
            let replyData = (try? JSONSerialization.data(withJSONObject: reply))
                ?? Data(#"{"stdout":"","exitCode":0}"#.utf8)
            UnixSocket.writeAll(conn, replyData)
            close(conn)
        }
    }
}
