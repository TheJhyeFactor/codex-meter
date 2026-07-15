import AppKit
import CodexMeterCore
import Foundation
import ServiceManagement
import UserNotifications

enum MenuBarDisplayMode: String, CaseIterable, Identifiable {
    case iconAndPercentage
    case percentage
    case icon
    case activity

    var id: String { rawValue }
    var title: String {
        switch self {
        case .iconAndPercentage: return "Icon + percentage"
        case .percentage: return "Percentage only"
        case .icon: return "Icon only"
        case .activity: return "Activity chart"
        }
    }
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

    private let client = CodexAppServerClient()
    private let activityScanner = LocalActivityScanner()
    private let previewMode: Bool
    private var pollingTask: Task<Void, Never>?
    private var activityPollingTask: Task<Void, Never>?
    private static let thresholdKey = "alertThreshold"
    private static let notifiedResetKey = "lastNotifiedReset"
    private static let displayModeKey = "menuBarDisplayMode"
    private static let inputRateKey = "costInputRate"
    private static let cachedInputRateKey = "costCachedInputRate"
    private static let outputRateKey = "costOutputRate"

    init(previewMode: Bool = false) {
        self.previewMode = previewMode
        let saved = UserDefaults.standard.integer(forKey: Self.thresholdKey)
        alertThreshold = saved == 0 ? 20 : saved
        displayMode = MenuBarDisplayMode(rawValue: UserDefaults.standard.string(forKey: Self.displayModeKey) ?? "") ?? .iconAndPercentage
        inputRate = UserDefaults.standard.double(forKey: Self.inputRateKey)
        cachedInputRate = UserDefaults.standard.double(forKey: Self.cachedInputRateKey)
        outputRate = UserDefaults.standard.double(forKey: Self.outputRateKey)
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
                fetchedAt: now
            )
            activity = LocalActivitySnapshot(
                days: [8, 5, 6, 3, 7, 4, 9].enumerated().map { offset, millions in
                    DailyTokenUsage(
                        date: Calendar.current.date(byAdding: .day, value: offset - 6, to: Calendar.current.startOfDay(for: now)) ?? now,
                        usage: TokenUsage(inputTokens: Int64(millions) * 900_000, cachedInputTokens: Int64(millions) * 650_000, outputTokens: Int64(millions) * 100_000, totalTokens: Int64(millions) * 1_000_000)
                    )
                },
                sampledAt: now,
                filesRead: 12
            )
        }
        if #available(macOS 13.0, *) {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    var windows: [RateLimitWindow] { payload?.snapshot.windows ?? [] }
    var menuBarRemaining: Int? {
        guard errorMessage == nil, !isStale else { return nil }
        return payload?.snapshot.mostConstrainedRemaining
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
            activity = try await activityScanner.scan(days: 7)
            activityError = nil
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
            payload = newPayload
            errorMessage = newPayload.snapshot.windows.isEmpty ? "No Codex rate-limit windows were returned for this account." : nil
            await notifyIfNeeded(newPayload)
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
        let appURL = URL(fileURLWithPath: "/Applications/ChatGPT.app")
        if FileManager.default.fileExists(atPath: appURL.path) {
            NSWorkspace.shared.openApplication(at: appURL, configuration: .init())
        }
    }

    private func notifyIfNeeded(_ payload: RateLimitPayload) async {
        guard let constrained = payload.snapshot.windows.min(by: { $0.remainingPercent < $1.remainingPercent }),
              constrained.remainingPercent <= alertThreshold else { return }

        let fallbackBucket = Int(Date().timeIntervalSince1970 / 86_400)
        let resetComponent = constrained.resetsAt.map { Int($0.timeIntervalSince1970) } ?? fallbackBucket
        let resetID = "\(constrained.durationMinutes ?? 0)-\(resetComponent)-\(alertThreshold)"
        guard UserDefaults.standard.string(forKey: Self.notifiedResetKey) != resetID else { return }

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
