import Foundation

/// Tails one session's transcript JSONL and folds new lines into the session: current
/// model, git branch, running token total, and a rolling log preview. Reads happen on a
/// background serial queue; store mutations hop to the main actor.
final class TranscriptWatcher: @unchecked Sendable {
    private let sessionID: String
    private let path: String
    private weak var store: SessionStore?

    private let queue = DispatchQueue(label: "com.ozan.ClaudeNotch.transcript")
    private var source: DispatchSourceFileSystemObject?
    private var evtFD: Int32 = -1

    private var readHandle: FileHandle?
    private var offset: UInt64 = 0
    private var pending = Data()

    // Accumulated state (serial-queue confined).
    private var runningTokens = 0
    private var logTail: [String] = []

    init(sessionID: String, path: String, store: SessionStore) {
        self.sessionID = sessionID
        self.path = path
        self.store = store
    }

    func start() {
        queue.async { [weak self] in
            self?.ingest()               // catch up on existing content
            self?.installWatch()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.source?.cancel()
            self?.source = nil
            try? self?.readHandle?.close()
            self?.readHandle = nil
        }
    }

    // MARK: Watching

    private func installWatch() {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        evtFD = fd
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.extend, .write, .rename, .delete], queue: queue)
        src.setEventHandler { [weak self] in self?.ingest() }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    // MARK: Ingesting new lines (serial queue)

    private func ingest() {
        if readHandle == nil {
            readHandle = FileHandle(forReadingAtPath: path)
        }
        guard let h = readHandle else { return }

        h.seek(toFileOffset: offset)
        let newData = h.readDataToEndOfFile()
        guard !newData.isEmpty else { return }
        offset += UInt64(newData.count)
        pending.append(newData)

        var model: String?
        var branch: String?
        var task: String?
        var tokensAdded = 0

        let newline = UInt8(0x0A)
        while let idx = pending.firstIndex(of: newline) {
            let lineData = pending.subdata(in: pending.startIndex..<idx)
            pending.removeSubrange(pending.startIndex...idx)
            guard !lineData.isEmpty, let e = TranscriptParser.parse(line: lineData) else { continue }
            if let m = e.model { model = m }
            if let b = e.branch, !b.isEmpty { branch = b }
            if let p = e.userPrompt { task = p }
            tokensAdded += e.addedTokens
            if let log = e.logLine {
                logTail.append(log)
                if logTail.count > 100 { logTail.removeFirst(logTail.count - 100) }
            }
        }

        runningTokens += tokensAdded
        let tokens = runningTokens
        let tail = logTail
        let sid = sessionID

        guard model != nil || branch != nil || task != nil || tokensAdded > 0 || !tail.isEmpty else { return }

        Task { @MainActor [weak store] in
            store?.update(sid) { s in
                if let model { s.model = model }
                if let branch { s.branch = branch }
                // Only fill an empty task (a live UserPromptSubmit hook wins).
                if let task, s.task.isEmpty { s.task = task }
                s.sessionTokens = tokens
                s.logTail = tail
            }
        }
    }
}
