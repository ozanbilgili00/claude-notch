import Foundation

/// What a Gemini transcript says about its session right now.
struct GeminiSnapshot: Equatable {
    var task: String?
    var model: String?
    var tokens = TokenCounts()
    var turn = GeminiTurn()
    var conversation: [ConversationTurn] = []
}

/// Tails one `agy` transcript and reports the session's state to the coordinator. The
/// counterpart of `TranscriptWatcher` for Gemini, where the transcript is the whole
/// story: prompt, tool calls, results, tokens, and where the turn ends.
///
/// The transcript file appears only with the conversation's first step, so `poke()`
/// (called on every discovery pass) retries until it exists. Whatever is already in it
/// at start-up is read as history: it sets the state but announces nothing, so opening
/// the notch doesn't celebrate turns that finished an hour ago.
final class GeminiWatcher: @unchecked Sendable {
    /// (session id, state, turn outcomes, live). `live` is false for the history read
    /// at start-up, which carries no outcomes and should announce nothing.
    typealias Report = @MainActor @Sendable (String, GeminiSnapshot, [GeminiTurn.Outcome], Bool) -> Void

    private let sessionID: String
    private let path: String
    private let report: Report

    private let queue = DispatchQueue(label: "com.ozan.ClaudeNotch.gemini")
    private var source: DispatchSourceFileSystemObject?
    private var handle: FileHandle?
    private var offset: UInt64 = 0
    private var partial = Data()
    private var caughtUp = false

    // Serial-queue confined.
    private var snapshot = GeminiSnapshot()
    private var turnCounter = 0
    private static let maxTurns = 40

    init(sessionID: String, path: String, report: @escaping Report) {
        self.sessionID = sessionID
        self.path = path
        self.report = report
    }

    func start() { poke() }

    /// Open the transcript if it has appeared, and read anything new.
    func poke() {
        queue.async { [weak self] in
            guard let self else { return }
            if self.source == nil { self.installWatch() }
            self.ingest()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.source?.cancel()
            self?.source = nil
            try? self?.handle?.close()
            self?.handle = nil
        }
    }

    // MARK: Watching (queue)

    private func installWatch() {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.extend, .write, .rename, .delete], queue: queue)
        src.setEventHandler { [weak self] in self?.ingest() }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    private func ingest() {
        if handle == nil { handle = FileHandle(forReadingAtPath: path) }
        guard let handle else { return }

        let size = (try? handle.seekToEnd()) ?? 0
        if size < offset { offset = 0; partial = Data(); snapshot = GeminiSnapshot() }
        try? handle.seek(toOffset: offset)
        let data = handle.readDataToEndOfFile()
        offset += UInt64(data.count)

        // The first read is history — unless the conversation is brand new, in which
        // case its first turn may already have run between two discovery passes.
        let history = !caughtUp && !isFresh()
        caughtUp = true
        guard !data.isEmpty || history else { return }
        partial.append(data)

        var outcomes: [GeminiTurn.Outcome] = []
        var start = partial.startIndex
        while let nl = partial[start...].firstIndex(of: 0x0A) {
            if let step = GeminiStep.parse(line: partial[start..<nl]) {
                if let outcome = fold(step) { outcomes.append(outcome) }
            }
            start = partial.index(after: nl)
        }
        partial = Data(partial[start...])

        let snap = snapshot
        let id = sessionID
        let report = self.report
        let announced = history ? [] : outcomes
        let live = !history
        Task { @MainActor in report(id, snap, announced, live) }
    }

    private func isFresh() -> Bool {
        let created = (try? FileManager.default.attributesOfItem(atPath: path))?[.creationDate] as? Date
        return created.map { Date().timeIntervalSince($0) < 60 } ?? false
    }

    private func fold(_ step: GeminiStep) -> GeminiTurn.Outcome? {
        switch step {
        case .prompt(let text, let model):
            if let model { snapshot.model = model }
            if !text.isEmpty {
                let firstLine = text.split(whereSeparator: \.isNewline).first ?? ""
                snapshot.task = String(firstLine.prefix(300))
                append(.user, text)
            }
        case .response(let text, _, let tokens):
            snapshot.tokens += tokens
            if !text.isEmpty { append(.assistant, text) }
        default:
            break
        }
        return snapshot.turn.apply(step, at: Date())
    }

    private func append(_ role: ConversationTurn.Role, _ text: String) {
        var turns = snapshot.conversation
        if role == .assistant, turns.last?.role == .assistant {
            turns[turns.count - 1].text += "\n\n" + text
        } else {
            turnCounter += 1
            turns.append(ConversationTurn(id: turnCounter, role: role, text: text))
            if turns.count > Self.maxTurns { turns.removeFirst(turns.count - Self.maxTurns) }
        }
        snapshot.conversation = turns
    }
}
