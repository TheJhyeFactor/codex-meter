import AppKit
import CodexMeterCore
import Foundation
import ServiceManagement
import UserNotifications

enum MenuBarDisplayMode: String, CaseIterable, Identifiable {
    case iconAndPercentage
    case resetAndPercentage
    case percentage
    case icon
    case activity

    var id: String { rawValue }
    var title: String {
        switch self {
        case .iconAndPercentage: return "Icon + percentage"
        case .resetAndPercentage: return "Reset + percentage"
        case .percentage: return "Percentage only"
        case .icon: return "Icon only"
        case .activity: return "Activity chart"
        }
    }
}

struct AccountProfile: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    let homePath: String?
    var email: String?

    var homeURL: URL? { homePath.map(URL.init(fileURLWithPath:)) }
    var displayName: String { email ?? name }
}

struct Celebration: Equatable, Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let symbol: String
}

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var payload: RateLimitPayload?
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var activity: LocalActivitySnapshot?
    @Published private(set) var activityError: String?
    @Published var alertThreshold: Int {
        didSet { UserDefaults.standard.set(alertThreshold, forKey: Self.thresholdKey) }
    }
    @Published private(set) var launchAtLogin = false
    @Published var displayMode: MenuBarDisplayMode {
        didSet { UserDefaults.standard.set(displayMode.rawValue, forKey: Self.displayModeKey) }
    }
    @Published var inputRate: Double { didSet { persistRates() } }
    @Published var cachedInputRate: Double { didSet { persistRates() } }
    @Published var outputRate: Double { didSet { persistRates() } }
    @Published var currency: DisplayCurrency {
        didSet { UserDefaults.standard.set(currency.rawValue, forKey: Self.currencyKey) }
    }
    @Published private(set) var accounts: [AccountProfile]
    @Published var activeAccountID: UUID {
        didSet { UserDefaults.standard.set(activeAccountID.uuidString, forKey: Self.activeAccountKey) }
    }
    @Published private(set) var celebration: Celebration?
    @Published private(set) var isSwitchingCodexAccount = false
    @Published private(set) var accountSwitchStatus: String?

    private var client: CodexAppServerClient
    private let activityScanner = LocalActivityScanner()
    private let previewMode: Bool
    private var pollingTask: Task<Void, Never>?
    private var activityPollingTask: Task<Void, Never>?
    private var loginProcesses: [UUID: Process] = [:]
    private static let thresholdKey = "alertThreshold"
    private static let notifiedResetKey = "lastNotifiedReset"
    private static let displayModeKey = "menuBarDisplayMode"
    private static let inputRateKey = "costInputRate"
    private static let cachedInputRateKey = "costCachedInputRate"
    private static let outputRateKey = "costOutputRate"
    private static let currencyKey = "displayCurrency"
    private static let accountsKey = "accountProfiles"
    private static let activeAccountKey = "activeAccountID"
    private static let savingsMilestoneKey = "lastSavingsMilestoneUSD"
    private static let tokenMilestoneKey = "lastTokenMilestone"
    private static let resetMilestoneKey = "lastBankedReset"

    init(previewMode: Bool = false) {
        let defaultAccount = AccountProfile(id: UUID(), name: "Default", homePath: nil, email: nil)
        let loadedAccounts: [AccountProfile]
        if let data = UserDefaults.standard.data(forKey: Self.accountsKey),
           let decoded = try? JSONDecoder().decode([AccountProfile].self, from: data), !decoded.isEmpty {
            loadedAccounts = decoded
        } else {
            loadedAccounts = [defaultAccount]
        }
        let savedAccount = UserDefaults.standard.string(forKey: Self.activeAccountKey).flatMap(UUID.init(uuidString:))
        let chosenAccountID = savedAccount.flatMap { candidate in
            loadedAccounts.contains(where: { $0.id == candidate }) ? candidate : nil
        } ?? loadedAccounts[0].id
        self.previewMode = previewMode
        self.accounts = loadedAccounts
        self.activeAccountID = chosenAccountID
        self.client = CodexAppServerClient(codexHome: loadedAccounts.first(where: { $0.id == chosenAccountID })?.homeURL)
        if UserDefaults.standard.data(forKey: Self.accountsKey) == nil {
            UserDefaults.standard.set(try? JSONEncoder().encode(loadedAccounts), forKey: Self.accountsKey)
        }
        let saved = UserDefaults.standard.integer(forKey: Self.thresholdKey)
        alertThreshold = saved == 0 ? 20 : saved
        displayMode = MenuBarDisplayMode(rawValue: UserDefaults.standard.string(forKey: Self.displayModeKey) ?? "") ?? .iconAndPercentage
        inputRate = UserDefaults.standard.double(forKey: Self.inputRateKey)
        cachedInputRate = UserDefaults.standard.double(forKey: Self.cachedInputRateKey)
        outputRate = UserDefaults.standard.double(forKey: Self.outputRateKey)
        currency = DisplayCurrency(rawValue: UserDefaults.standard.string(forKey: Self.currencyKey) ?? "") ?? .usd
        if previewMode {
            let now = Date()
            payload = RateLimitPayload(
                snapshot: RateLimitSnapshot(
                    limitID: "codex",
                    limitName: "Codex",
                    planType: "plus",
                    primary: RateLimitWindow(usedPercent: 58, resetsAt: now.addingTimeInterval(8_040), durationMinutes: 300),
                    secondary: RateLimitWindow(usedPercent: 32, resetsAt: now.addingTimeInterval(403_200), durationMinutes: 10_080)
                ),
                fetchedAt: now,
                availableResetCredits: 3
            )
            activity = LocalActivitySnapshot(
                days: [8, 5, 6, 3, 7, 4, 9].enumerated().map { offset, millions in
                    DailyTokenUsage(
                        date: Calendar.current.date(byAdding: .day, value: offset - 6, to: Calendar.current.startOfDay(for: now)) ?? now,
                        usage: TokenUsage(inputTokens: Int64(millions) * 900_000, cachedInputTokens: Int64(millions) * 650_000, outputTokens: Int64(millions) * 100_000, totalTokens: Int64(millions) * 1_000_000)
                    )
                },
                models: [
                    ModelTokenUsage(model: "gpt-5.6-sol", usage: TokenUsage(inputTokens: 25_000_000, cachedInputTokens: 18_000_000, outputTokens: 3_000_000, totalTokens: 28_000_000)),
                    ModelTokenUsage(model: "gpt-5.6-terra", usage: TokenUsage(inputTokens: 14_000_000, cachedInputTokens: 10_000_000, outputTokens: 2_000_000, totalTokens: 16_000_000))
                ],
                sampledAt: now,
                filesRead: 12
            )
        }
        if #available(macOS 13.0, *) {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    var windows: [RateLimitWindow] { payload?.snapshot.windows ?? [] }
    var activeAccountName: String { accounts.first(where: { $0.id == activeAccountID })?.name ?? "Default" }
    var activeAccountDisplayName: String { accounts.first(where: { $0.id == activeAccountID })?.displayName ?? "Default" }
    var canDeleteActiveAccount: Bool { accounts.first(where: { $0.id == activeAccountID })?.homePath != nil }
    var bankedResetCount: Int? { payload?.availableResetCredits }
    var totalSavingsUSD: Double {
        guard let activity else { return 0 }
        guard let baseline = OpenAIPriceCatalog.price(for: "gpt-5.6-sol") else { return 0 }
        return activity.models.reduce(0) { total, item in
            guard let actual = OpenAIPriceCatalog.price(for: item.model) else { return total }
            return total + max(0, baseline.estimate(item.usage) - actual.estimate(item.usage))
        }
    }
    var totalSavings: Double { currency.convertFromUSD(totalSavingsUSD) }
    var menuBarRemaining: Int? {
        guard errorMessage == nil, !isStale else { return nil }
        return payload?.snapshot.mostConstrainedRemaining
    }
    var menuBarWindow: RateLimitWindow? {
        guard errorMessage == nil, !isStale else { return nil }
        return payload?.snapshot.mostConstrainedWindow
    }
    var planLabel: String? {
        payload?.snapshot.planType?.replacingOccurrences(of: "_", with: " ").capitalized
    }
    var costRates: LocalCostRates {
        LocalCostRates(inputPerMillion: inputRate, cachedInputPerMillion: cachedInputRate, outputPerMillion: outputRate)
    }
    var isStale: Bool {
        guard let fetchedAt = payload?.fetchedAt else { return false }
        return Date().timeIntervalSince(fetchedAt) > 180
    }

    func start() {
        guard !previewMode else { return }
        pollingTask?.cancel()
        pollingTask = Task {
            await refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(120))
                guard !Task.isCancelled else { break }
                await refresh()
            }
        }
        activityPollingTask?.cancel()
        activityPollingTask = Task {
            await refreshActivity()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(600))
                guard !Task.isCancelled else { break }
                await refreshActivity()
            }
        }
    }

    func refreshActivity() async {
        do {
            let previous = activity
            activity = try await activityScanner.scan(days: 7)
            activityError = nil
            detectActivityMilestones(previous: previous, current: activity)
        } catch {
            activity = nil
            activityError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let newPayload = try await client.readRateLimits()
            let previous = payload
            payload = newPayload
            errorMessage = newPayload.snapshot.windows.isEmpty ? "No Codex rate-limit windows were returned for this account." : nil
            await notifyIfNeeded(newPayload)
            detectBankedResetMilestone(previous: previous, current: newPayload)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            await client.stop()
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        guard #available(macOS 13.0, *) else { return }
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            errorMessage = "Launch at login could not be changed: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func openCodex() {
        let settingsURL = URL(string: "codex://settings")
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").first {
            running.activate(options: [.activateAllWindows])
            if let settingsURL { _ = NSWorkspace.shared.open(settingsURL) }
            return
        }
        let discoveredURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex")
        let fallbackURL = URL(fileURLWithPath: "/Applications/ChatGPT.app")
        guard let appURL = discoveredURL ?? (FileManager.default.fileExists(atPath: fallbackURL.path) ? fallbackURL : nil) else {
            errorMessage = "Codex is not installed in /Applications."
            return
        }
        NSWorkspace.shared.openApplication(at: appURL, configuration: .init()) { [weak self] _, error in
            Task { @MainActor in
                if let error {
                    self?.errorMessage = "Codex could not be opened: \(error.localizedDescription)"
                } else if let settingsURL {
                    _ = NSWorkspace.shared.open(settingsURL)
                }
            }
        }
    }

    func requestAccountSwitch(to id: UUID) {
        guard accounts.contains(where: { $0.id == id }), id != activeAccountID else { return }
        guard let profile = accounts.first(where: { $0.id == id }) else { return }

        let alert = NSAlert()
        alert.messageText = "Switch to \(profile.displayName)?"
        alert.informativeText = profile.homeURL == nil
            ? "This is the Codex desktop profile. Codex Meter will switch its usage view to the account currently signed in there."
            : "Choose whether to switch only Codex Meter, or also sign the Codex desktop app out and open OpenAI's secure browser login for this account."
        if profile.homeURL == nil {
            alert.addButton(withTitle: "Switch Meter")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            switchMeterAccount(to: id)
            return
        }
        alert.addButton(withTitle: "Meter + Codex")
        alert.addButton(withTitle: "Meter Only")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            switchMeterAccount(to: id)
            Task { await switchCodexDesktopAccount(to: profile) }
        case .alertSecondButtonReturn:
            switchMeterAccount(to: id)
        default:
            return
        }
    }

    private func switchMeterAccount(to id: UUID) {
        guard accounts.contains(where: { $0.id == id }), id != activeAccountID else { return }
        pollingTask?.cancel()
        activityPollingTask?.cancel()
        Task {
            await client.stop()
            let profile = accounts.first(where: { $0.id == id })
            activeAccountID = id
            client = CodexAppServerClient(codexHome: profile?.homeURL)
            payload = nil
            activity = nil
            start()
        }
    }

    func addAccount() {
        let alert = NSAlert()
        alert.messageText = "Add Codex account"
        alert.informativeText = "Choose a label. Codex Meter will open OpenAI's secure browser sign-in for a private profile on this Mac. Passwords and verification codes stay on OpenAI's page."
        let field = NSTextField(string: "Work")
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let id = UUID()
        let home = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex-meter", isDirectory: true)
            .appendingPathComponent("accounts", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            let config = home.appendingPathComponent("config.toml")
            if !FileManager.default.fileExists(atPath: config.path) {
                try Data("cli_auth_credentials_store = \"file\"\n".utf8).write(to: config, options: .atomic)
            }
            let profile = AccountProfile(id: id, name: name, homePath: home.path, email: nil)
            accounts.append(profile)
            persistAccounts()
            startLogin(for: profile)
        } catch {
            errorMessage = "The account profile could not be created: \(error.localizedDescription)"
        }
    }

    func deleteActiveAccount() {
        deleteAccount(id: activeAccountID)
    }

    func deleteAccount(id: UUID) {
        guard let profile = accounts.first(where: { $0.id == id }), let home = profile.homeURL else { return }
        let wasActive = profile.id == activeAccountID
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete \(profile.name)?"
        alert.informativeText = "This removes the locally saved Codex credentials and usage profile from this Mac. It does not delete the OpenAI account."
        alert.addButton(withTitle: "Delete Account")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        if wasActive {
            pollingTask?.cancel()
            activityPollingTask?.cancel()
        }
        Task {
            if wasActive { await client.stop() }
            do {
                loginProcesses.removeValue(forKey: profile.id)?.terminate()
                try AccountProfileStorage.removeLocalProfile(at: home)
                accounts.removeAll { $0.id == profile.id }
                persistAccounts()
                if wasActive, let fallback = accounts.first {
                    activeAccountID = fallback.id
                    client = CodexAppServerClient(codexHome: fallback.homeURL)
                    payload = nil
                    activity = nil
                    start()
                }
                celebration = Celebration(title: "Account removed", subtitle: "Local credentials were deleted", symbol: "trash")
                dismissCelebration()
            } catch {
                if wasActive {
                    client = CodexAppServerClient(codexHome: profile.homeURL)
                    start()
                }
                errorMessage = "The local account could not be deleted: \(error.localizedDescription)"
            }
        }
    }

    private func startLogin(for profile: AccountProfile) {
        guard let executable = CodexAppServerClient.locateExecutable(), let home = profile.homeURL else { return }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["login"]
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = home.path
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] finished in
            Task { @MainActor in
                self?.finishLogin(profileID: profile.id, succeeded: finished.terminationStatus == 0)
            }
        }
        do {
            try process.run()
            loginProcesses[profile.id] = process
        } catch {
            errorMessage = "Codex login could not be started: \(error.localizedDescription)"
        }
    }

    private func finishLogin(profileID: UUID, succeeded: Bool) {
        loginProcesses.removeValue(forKey: profileID)
        guard succeeded else {
            accounts.removeAll { $0.id == profileID }
            persistAccounts()
            errorMessage = "The OpenAI sign-in was cancelled or did not complete. You can add the account again when ready."
            return
        }
        Task { await finishSuccessfulLogin(profileID: profileID) }
    }

    private func finishSuccessfulLogin(profileID: UUID) async {
        if let index = accounts.firstIndex(where: { $0.id == profileID }), let home = accounts[index].homeURL {
            let identityClient = CodexAppServerClient(codexHome: home)
            if let account = try? await identityClient.readAccount() {
                accounts[index].email = account.email
                persistAccounts()
            }
            await identityClient.stop()
        }
        switchMeterAccount(to: profileID)
        celebration = Celebration(title: "Account ready", subtitle: "Secure sign-in completed", symbol: "person.crop.circle.badge.checkmark")
        dismissCelebration()
    }

    private func persistAccounts() {
        UserDefaults.standard.set(try? JSONEncoder().encode(accounts), forKey: Self.accountsKey)
    }

    private func detectActivityMilestones(previous: LocalActivitySnapshot?, current: LocalActivitySnapshot?) {
        guard !previewMode, previous != nil, let current else { return }
        let newSavings = current.models.reduce(0) { total, item in savingsUSD(for: item) + total }
        let newTokens = current.total.totalTokens
        let savingsStep = max(0, Int(newSavings / 50))
        let savedStep = UserDefaults.standard.integer(forKey: Self.savingsMilestoneKey)
        if savingsStep > savedStep, savingsStep > 0 {
            UserDefaults.standard.set(savingsStep, forKey: Self.savingsMilestoneKey)
            celebration = Celebration(title: "\(currency.code) \(Int(currency.convertFromUSD(newSavings))) saved", subtitle: "Estimated savings versus GPT-5.6 Sol", symbol: "sparkles")
            dismissCelebration()
            return
        }
        let tokenStep = max(0, Int(newTokens / 1_000_000))
        let oldTokenStep = UserDefaults.standard.integer(forKey: Self.tokenMilestoneKey)
        if tokenStep >= 1, tokenStep > oldTokenStep, (tokenStep % 10 == 0 || oldTokenStep == 0) {
            UserDefaults.standard.set(tokenStep, forKey: Self.tokenMilestoneKey)
            celebration = Celebration(title: "Token milestone", subtitle: "You have used \(tokenStep)M local tokens", symbol: "bolt.fill")
            dismissCelebration()
        }
    }

    private func savingsUSD(for item: ModelTokenUsage) -> Double {
        guard let baseline = OpenAIPriceCatalog.price(for: "gpt-5.6-sol"), let actual = OpenAIPriceCatalog.price(for: item.model) else { return 0 }
        return max(0, baseline.estimate(item.usage) - actual.estimate(item.usage))
    }

    private func detectBankedResetMilestone(previous: RateLimitPayload?, current: RateLimitPayload) {
        guard !previewMode,
              let previousCount = previous?.availableResetCredits,
              let currentCount = current.availableResetCredits,
              currentCount > previousCount else { return }
        let key = "\(activeAccountID.uuidString)-\(currentCount)"
        guard UserDefaults.standard.string(forKey: Self.resetMilestoneKey) != key else { return }
        UserDefaults.standard.set(key, forKey: Self.resetMilestoneKey)
        celebration = Celebration(title: "Reset banked", subtitle: "\(currentCount) available for this account", symbol: "arrow.counterclockwise.circle.fill")
        dismissCelebration()
    }

    private func switchCodexDesktopAccount(to profile: AccountProfile) async {
        guard !isSwitchingCodexAccount else { return }
        isSwitchingCodexAccount = true
        accountSwitchStatus = "Signing Codex out…"
        errorMessage = nil

        let desktopClient = CodexAppServerClient()
        do {
            var expectedEmail = profile.email
            if expectedEmail == nil, let home = profile.homeURL {
                accountSwitchStatus = "Checking \(profile.name)…"
                let profileClient = CodexAppServerClient(codexHome: home)
                if let account = try? await profileClient.readAccount() {
                    expectedEmail = account.email
                    if let index = accounts.firstIndex(where: { $0.id == profile.id }) {
                        accounts[index].email = account.email
                        persistAccounts()
                    }
                }
                await profileClient.stop()
            }
            accountSwitchStatus = "Signing Codex out…"
            try await closeCodexDesktop()
            try await desktopClient.logoutAccount()
            accountSwitchStatus = "Waiting for secure OpenAI sign-in…"
            let login = try await desktopClient.startChatGPTLogin()
            guard NSWorkspace.shared.open(login.authorizationURL) else {
                throw CodexClientError.server("The OpenAI sign-in page could not be opened in your browser.")
            }
            try await desktopClient.waitForLogin(id: login.id)
            guard let signedIn = try await desktopClient.readAccount(refreshToken: true) else {
                throw CodexClientError.server("Codex did not report a signed-in account after login.")
            }
            if let expected = expectedEmail, let actual = signedIn.email,
               expected.caseInsensitiveCompare(actual) != .orderedSame {
                throw CodexClientError.server("Codex signed in as \(actual), not \(expected). Sign in again and choose the intended account.")
            }
            await desktopClient.stop()
            accountSwitchStatus = nil
            isSwitchingCodexAccount = false
            openCodex()
            celebration = Celebration(
                title: "Codex account switched",
                subtitle: signedIn.email ?? profile.displayName,
                symbol: "person.crop.circle.badge.checkmark"
            )
            dismissCelebration()
        } catch {
            await desktopClient.stop()
            accountSwitchStatus = nil
            isSwitchingCodexAccount = false
            errorMessage = "Codex account switch failed: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
            openCodex()
        }
    }

    private func closeCodexDesktop() async throws {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex")
        running.forEach { _ = $0.terminate() }
        let deadline = ContinuousClock.now + .seconds(8)
        while NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").contains(where: { !$0.isTerminated }) {
            guard ContinuousClock.now < deadline else {
                throw CodexClientError.server("Codex could not be closed before signing out. Quit Codex and try again.")
            }
            try await Task.sleep(for: .milliseconds(150))
        }
    }

    private func dismissCelebration() {
        Task { try? await Task.sleep(for: .seconds(4)); celebration = nil }
    }

    private func notifyIfNeeded(_ payload: RateLimitPayload) async {
        guard let constrained = payload.snapshot.windows.min(by: { $0.remainingPercent < $1.remainingPercent }),
              constrained.remainingPercent <= alertThreshold else { return }

        let fallbackBucket = Int(Date().timeIntervalSince1970 / 86_400)
        let resetComponent = constrained.resetsAt.map { Int($0.timeIntervalSince1970) } ?? fallbackBucket
        let resetID = "\(constrained.durationMinutes ?? 0)-\(resetComponent)-\(alertThreshold)"
        guard UserDefaults.standard.string(forKey: Self.notifiedResetKey) != resetID else { return }

        if !previewMode {
            celebration = Celebration(title: "Usage running low", subtitle: "\(constrained.remainingPercent)% remains in the tightest window", symbol: "exclamationmark.triangle.fill")
            dismissCelebration()
        }

        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        guard granted else { return }

        let content = UNMutableNotificationContent()
        content.title = "Codex usage is running low"
        content.body = "\(constrained.remainingPercent)% remains. \(ResetTimeFormatter.notificationText(for: constrained.resetsAt))"
        content.sound = .default
        try? await center.add(UNNotificationRequest(identifier: "codex-meter-low-\(resetID)", content: content, trigger: nil))
        UserDefaults.standard.set(resetID, forKey: Self.notifiedResetKey)
    }

    private func persistRates() {
        UserDefaults.standard.set(max(0, inputRate), forKey: Self.inputRateKey)
        UserDefaults.standard.set(max(0, cachedInputRate), forKey: Self.cachedInputRateKey)
        UserDefaults.standard.set(max(0, outputRate), forKey: Self.outputRateKey)
    }
}

enum ResetTimeFormatter {
    static func relativeText(for date: Date?, now: Date = Date()) -> String {
        guard let date else { return "Reset time unavailable" }
        if date <= now { return "Resetting now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Resets \(formatter.localizedString(for: date, relativeTo: now))"
    }

    static func absoluteText(for date: Date?) -> String? {
        guard let date else { return nil }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    static func notificationText(for date: Date?) -> String {
        guard let date else { return "The reset time is unavailable." }
        return "It resets \(date.formatted(date: .omitted, time: .shortened))."
    }
}
