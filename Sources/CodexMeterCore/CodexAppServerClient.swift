import Foundation

public actor CodexAppServerClient {
    private let codexHome: URL?
    private let explicitExecutableURL: URL?
    private var process: Process?
    private var input: FileHandle?
    private var readTask: Task<Void, Never>?
    private var nextID = 1
    private var initializationID: Int?
    private var pendingReads: [Int: CheckedContinuation<RateLimitPayload, Error>] = [:]
    private var pendingAccountReads: [Int: CheckedContinuation<CodexAccount?, Error>] = [:]
    private var pendingLoginStarts: [Int: CheckedContinuation<CodexLoginSession, Error>] = [:]
    private var pendingLogouts: [Int: CheckedContinuation<Void, Error>] = [:]
    private var pendingLoginCompletions: [String: CheckedContinuation<Void, Error>] = [:]
    private var completedLogins: [String: Result<Void, Error>] = [:]
    private var latestSnapshot: RateLimitPayload?
    private var executablePath: String?
    private var protocolStage = "not started"

    private var executableCandidates: [String] {
        Self.executableCandidatePaths()
    }

    public static func executableCandidatePaths(
        home: String = FileManager.default.homeDirectoryForCurrentUser.path,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        [
            environment["CODEX_PATH"],
            "/Applications/Codex.app/Contents/Resources/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "\(home)/.local/bin/codex",
            "\(home)/.npm-global/bin/codex",
            "\(home)/.volta/bin/codex"
        ].compactMap { $0 }
    }

    public static func locateExecutable() -> URL? {
        let candidates = executableCandidatePaths()
        return candidates.first(where: FileManager.default.isExecutableFile(atPath:)).map(URL.init(fileURLWithPath:))
    }

    deinit {
        readTask?.cancel()
        process?.terminate()
    }

    public init(codexHome: URL? = nil, executableURL: URL? = nil) {
        self.codexHome = codexHome
        self.explicitExecutableURL = executableURL
    }

    public func readRateLimits() async throws -> RateLimitPayload {
        if process?.isRunning != true { try start() }
        try await ensureInitialized()

        protocolStage = "waiting for account/rateLimits/read"
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

    public func readAccount(refreshToken: Bool = false) async throws -> CodexAccount? {
        if process?.isRunning != true { try start() }
        try await ensureInitialized()

        let id = nextID
        nextID += 1
        return try await withCheckedThrowingContinuation { continuation in
            pendingAccountReads[id] = continuation
            do {
                try send(["method": "account/read", "id": id, "params": ["refreshToken": refreshToken]])
            } catch {
                pendingAccountReads.removeValue(forKey: id)
                continuation.resume(throwing: error)
                return
            }
            Task {
                try? await Task.sleep(for: .seconds(12))
                self.timeoutAccountRead(id: id)
            }
        }
    }

    public func logoutAccount() async throws {
        if process?.isRunning != true { try start() }
        try await ensureInitialized()

        let id = nextID
        nextID += 1
        try await withCheckedThrowingContinuation { continuation in
            pendingLogouts[id] = continuation
            do {
                try send(["method": "account/logout", "id": id])
            } catch {
                pendingLogouts.removeValue(forKey: id)
                continuation.resume(throwing: error)
                return
            }
            Task {
                try? await Task.sleep(for: .seconds(12))
                self.timeoutLogout(id: id)
            }
        }
    }

    public func startChatGPTLogin() async throws -> CodexLoginSession {
        if process?.isRunning != true { try start() }
        try await ensureInitialized()

        let id = nextID
        nextID += 1
        return try await withCheckedThrowingContinuation { continuation in
            pendingLoginStarts[id] = continuation
            do {
                try send([
                    "method": "account/login/start",
                    "id": id,
                    "params": ["type": "chatgpt", "appBrand": "codex", "codexStreamlinedLogin": true]
                ])
            } catch {
                pendingLoginStarts.removeValue(forKey: id)
                continuation.resume(throwing: error)
                return
            }
            Task {
                try? await Task.sleep(for: .seconds(12))
                self.timeoutLoginStart(id: id)
            }
        }
    }

    public func waitForLogin(id loginID: String) async throws {
        if let result = completedLogins.removeValue(forKey: loginID) {
            return try result.get()
        }
        try await withCheckedThrowingContinuation { continuation in
            pendingLoginCompletions[loginID] = continuation
            Task {
                try? await Task.sleep(for: .seconds(300))
                self.timeoutLoginCompletion(id: loginID)
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

    public func diagnosticSummary() -> String {
        [
            "Executable: \(executablePath ?? explicitExecutableURL?.path ?? "not resolved")",
            "CODEX_HOME: \(codexHome == nil ? "default" : "isolated profile")",
            "Protocol stage: \(protocolStage)",
            "Process running: \(process?.isRunning == true ? "yes" : "no")"
        ].joined(separator: "\n")
    }

    private func timeoutRead(id: Int) {
        pendingReads.removeValue(forKey: id)?.resume(throwing: CodexClientError.timedOut)
    }

    private func timeoutAccountRead(id: Int) {
        pendingAccountReads.removeValue(forKey: id)?.resume(throwing: CodexClientError.timedOut)
    }

    private func timeoutLoginStart(id: Int) {
        pendingLoginStarts.removeValue(forKey: id)?.resume(throwing: CodexClientError.timedOut)
    }

    private func timeoutLogout(id: Int) {
        pendingLogouts.removeValue(forKey: id)?.resume(throwing: CodexClientError.timedOut)
    }

    private func timeoutLoginCompletion(id: String) {
        pendingLoginCompletions.removeValue(forKey: id)?.resume(throwing: CodexClientError.timedOut)
    }

    private func start() throws {
        let executable = explicitExecutableURL?.path
            ?? executableCandidates.first(where: FileManager.default.isExecutableFile(atPath:))
        guard let executable else {
            throw CodexClientError.executableNotFound
        }

        executablePath = executable
        protocolStage = "starting app-server"

        let process = Process()
        let stdout = Pipe()
        let stdin = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server"]
        process.standardOutput = stdout
        process.standardInput = stdin
        process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        let inheritedPath = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let executableDirectory = URL(fileURLWithPath: executable).deletingLastPathComponent().path
        let requiredPaths = [executableDirectory, "/opt/homebrew/bin", "/usr/local/bin"]
        environment["PATH"] = (requiredPaths + [inheritedPath]).joined(separator: ":")
        if let codexHome {
            environment["CODEX_HOME"] = codexHome.path
        }
        process.environment = environment

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
            protocolStage = "waiting for initialize response"
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
            protocolStage = "initialized"
            try? send(["method": "initialized", "params": [:]])
            return
        }

        if let id = (root["id"] as? NSNumber)?.intValue, let continuation = pendingReads.removeValue(forKey: id) {
            do {
                guard let payload = try RateLimitParser.parseResponse(data) else { throw CodexClientError.invalidResponse }
                latestSnapshot = payload
                protocolStage = "rate limits received"
                continuation.resume(returning: payload)
            } catch {
                continuation.resume(throwing: error)
            }
            return
        }

        if let id = (root["id"] as? NSNumber)?.intValue, let continuation = pendingAccountReads.removeValue(forKey: id) {
            if let error = responseError(root) {
                continuation.resume(throwing: error)
            } else if let result = root["result"] as? [String: Any] {
                continuation.resume(returning: CodexAccount.parse(result["account"]))
            } else {
                continuation.resume(throwing: CodexClientError.invalidResponse)
            }
            return
        }

        if let id = (root["id"] as? NSNumber)?.intValue, let continuation = pendingLoginStarts.removeValue(forKey: id) {
            if let error = responseError(root) {
                continuation.resume(throwing: error)
            } else if let result = root["result"] as? [String: Any],
                      let loginID = result["loginId"] as? String,
                      let authURLString = result["authUrl"] as? String,
                      let authURL = URL(string: authURLString) {
                continuation.resume(returning: CodexLoginSession(id: loginID, authorizationURL: authURL))
            } else {
                continuation.resume(throwing: CodexClientError.invalidResponse)
            }
            return
        }

        if let id = (root["id"] as? NSNumber)?.intValue, let continuation = pendingLogouts.removeValue(forKey: id) {
            if let error = responseError(root) {
                continuation.resume(throwing: error)
            } else {
                continuation.resume()
            }
            return
        }

        if root["method"] as? String == "account/login/completed",
           let params = root["params"] as? [String: Any],
           let loginID = params["loginId"] as? String {
            let success = params["success"] as? Bool ?? false
            let result: Result<Void, Error> = success
                ? .success(())
                : .failure(CodexClientError.server(params["error"] as? String ?? "OpenAI sign-in did not complete."))
            if let continuation = pendingLoginCompletions.removeValue(forKey: loginID) {
                continuation.resume(with: result)
            } else {
                completedLogins[loginID] = result
            }
            return
        }

        if let payload = try? RateLimitParser.parseNotification(data) { latestSnapshot = payload }
    }

    private func connectionEnded() {
        process = nil
        input = nil
        initializationID = nil
        protocolStage = "app-server disconnected"
        failPending(with: CodexClientError.disconnected)
    }

    private func failPending(with error: Error) {
        let continuations = pendingReads.values
        pendingReads.removeAll()
        continuations.forEach { $0.resume(throwing: error) }
        let accountContinuations = pendingAccountReads.values
        pendingAccountReads.removeAll()
        accountContinuations.forEach { $0.resume(throwing: error) }
        let loginContinuations = pendingLoginStarts.values
        pendingLoginStarts.removeAll()
        loginContinuations.forEach { $0.resume(throwing: error) }
        let logoutContinuations = pendingLogouts.values
        pendingLogouts.removeAll()
        logoutContinuations.forEach { $0.resume(throwing: error) }
        let completionContinuations = pendingLoginCompletions.values
        pendingLoginCompletions.removeAll()
        completionContinuations.forEach { $0.resume(throwing: error) }
    }

    private func responseError(_ root: [String: Any]) -> CodexClientError? {
        guard let error = root["error"] as? [String: Any] else { return nil }
        return .server(error["message"] as? String ?? "Codex returned an unknown error.")
    }
}

public struct CodexAccount: Equatable, Sendable {
    public let type: String
    public let email: String?
    public let planType: String?

    fileprivate static func parse(_ value: Any?) -> CodexAccount? {
        guard let raw = value as? [String: Any], let type = raw["type"] as? String else { return nil }
        return CodexAccount(type: type, email: raw["email"] as? String, planType: raw["planType"] as? String)
    }
}

public struct CodexLoginSession: Equatable, Sendable {
    public let id: String
    public let authorizationURL: URL
}
