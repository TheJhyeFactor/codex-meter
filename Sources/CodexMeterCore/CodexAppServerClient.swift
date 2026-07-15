import Foundation

public actor CodexAppServerClient {
    private var process: Process?
    private var input: FileHandle?
    private var readTask: Task<Void, Never>?
    private var nextID = 1
    private var initializationID: Int?
    private var pendingReads: [Int: CheckedContinuation<RateLimitPayload, Error>] = [:]
    private var latestSnapshot: RateLimitPayload?

    private var executableCandidates: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            ProcessInfo.processInfo.environment["CODEX_PATH"],
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "\(home)/.local/bin/codex",
            "\(home)/.npm-global/bin/codex",
            "\(home)/.volta/bin/codex"
        ].compactMap { $0 }
    }

    deinit {
        readTask?.cancel()
        process?.terminate()
    }

    public init() {}

    public func readRateLimits() async throws -> RateLimitPayload {
        if process?.isRunning != true { try start() }
        try await ensureInitialized()

        let id = nextID
        nextID += 1
        return try await withCheckedThrowingContinuation { continuation in
            pendingReads[id] = continuation
            do {
                try send(["method": "account/rateLimits/read", "id": id])
            } catch {
                pendingReads.removeValue(forKey: id)
                continuation.resume(throwing: error)
                return
            }
            Task {
                try? await Task.sleep(for: .seconds(12))
                self.timeoutRead(id: id)
            }
        }
    }

    public func stop() {
        readTask?.cancel()
        readTask = nil
        input?.closeFile()
        input = nil
        if process?.isRunning == true { process?.terminate() }
        process = nil
        failPending(with: CodexClientError.disconnected)
    }

    private func timeoutRead(id: Int) {
        pendingReads.removeValue(forKey: id)?.resume(throwing: CodexClientError.timedOut)
    }

    private func start() throws {
        guard let executable = executableCandidates.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw CodexClientError.executableNotFound
        }

        let process = Process()
        let stdout = Pipe()
        let stdin = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server"]
        process.standardOutput = stdout
        process.standardInput = stdin
        process.standardError = FileHandle.nullDevice

        do { try process.run() } catch { throw CodexClientError.launch(error.localizedDescription) }

        self.process = process
        self.input = stdin.fileHandleForWriting
        self.readTask = Task { [weak self] in
            do {
                for try await line in stdout.fileHandleForReading.bytes.lines {
                    guard let data = line.data(using: .utf8) else { continue }
                    await self?.handle(data)
                }
                await self?.connectionEnded()
            } catch {
                await self?.connectionEnded()
            }
        }
    }

    private func ensureInitialized() async throws {
        if initializationID == nil {
            let id = nextID
            nextID += 1
            initializationID = id
            try send([
                "method": "initialize",
                "id": id,
                "params": ["clientInfo": ["name": "codex_meter", "title": "Codex Meter", "version": "1.0.0"]]
            ])
        }

        let deadline = ContinuousClock.now + .seconds(5)
        while initializationID != nil {
            if ContinuousClock.now >= deadline {
                stop()
                throw CodexClientError.timedOut
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func send(_ object: [String: Any]) throws {
        guard let input, process?.isRunning == true else { throw CodexClientError.disconnected }
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        do { try input.write(contentsOf: data) } catch { throw CodexClientError.disconnected }
    }

    private func handle(_ data: Data) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        if let id = (root["id"] as? NSNumber)?.intValue, id == initializationID {
            initializationID = nil
            try? send(["method": "initialized", "params": [:]])
            return
        }

        if let id = (root["id"] as? NSNumber)?.intValue, let continuation = pendingReads.removeValue(forKey: id) {
            do {
                guard let payload = try RateLimitParser.parseResponse(data) else { throw CodexClientError.invalidResponse }
                latestSnapshot = payload
                continuation.resume(returning: payload)
            } catch {
                continuation.resume(throwing: error)
            }
            return
        }

        if let payload = try? RateLimitParser.parseNotification(data) { latestSnapshot = payload }
    }

    private func connectionEnded() {
        process = nil
        input = nil
        initializationID = nil
        failPending(with: CodexClientError.disconnected)
    }

    private func failPending(with error: Error) {
        let continuations = pendingReads.values
        pendingReads.removeAll()
        continuations.forEach { $0.resume(throwing: error) }
    }
}
