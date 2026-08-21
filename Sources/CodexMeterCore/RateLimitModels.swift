import Foundation

public enum CodexClientError: LocalizedError, Equatable {
    case executableNotFound
    case launch(String)
    case disconnected
    case timedOut
    case server(String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .executableNotFound: return "Codex is not installed in a supported location."
        case .launch(let message): return "Could not start Codex: \(message)"
        case .disconnected: return "The Codex usage service stopped unexpectedly."
        case .timedOut: return "Codex did not return usage data in time."
        case .server(let message): return message
        case .invalidResponse: return "Codex returned usage data in an unknown format."
        }
    }
}

public struct RateLimitWindow: Equatable, Sendable, Codable {
    public let usedPercent: Int
    public let resetsAt: Date?
    public let durationMinutes: Int?

    public init(usedPercent: Int, resetsAt: Date?, durationMinutes: Int?) {
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.durationMinutes = durationMinutes
    }

    public var remainingPercent: Int { max(0, min(100, 100 - usedPercent)) }

    public var displayName: String {
        guard let durationMinutes else { return "Usage window" }
        if durationMinutes <= 360 { return "5-hour limit" }
        if durationMinutes >= 9_000 { return "Weekly limit" }
        if durationMinutes >= 1_200 { return "Daily limit" }
        return "\(durationMinutes / 60)-hour limit"
    }
}

public struct ResetCountdown: Equatable, Sendable {
    public let daysText: String
    public let hoursText: String
    public let accessibilityText: String

    public init(daysText: String, hoursText: String, accessibilityText: String) {
        self.daysText = daysText
        self.hoursText = hoursText
        self.accessibilityText = accessibilityText
    }
}

public enum ResetCountdownFormatter {
    public static func format(until resetDate: Date?, now: Date = Date()) -> ResetCountdown {
        guard let resetDate else {
            return ResetCountdown(daysText: "--", hoursText: "--", accessibilityText: "Reset time unavailable")
        }

        let secondsRemaining = max(0, Int(resetDate.timeIntervalSince(now)))
        if secondsRemaining == 0 {
            return ResetCountdown(daysText: "0d", hoursText: "0h", accessibilityText: "Resetting now")
        }
        if secondsRemaining < 3_600 {
            return ResetCountdown(daysText: "0d", hoursText: "<1h", accessibilityText: "Less than 1 hour until reset")
        }

        let days = secondsRemaining / 86_400
        let hours = (secondsRemaining % 86_400) / 3_600
        let dayUnit = days == 1 ? "day" : "days"
        let hourUnit = hours == 1 ? "hour" : "hours"
        return ResetCountdown(
            daysText: "\(days)d",
            hoursText: "\(hours)h",
            accessibilityText: "\(days) \(dayUnit), \(hours) \(hourUnit) until reset"
        )
    }
}

public enum WeeklyPaceSeverity: String, Equatable, Sendable, Codable {
    case belowPace
    case onPace
    case elevated
    case high
    case veryHigh
}

public struct WeeklyPace: Equatable, Sendable, Codable {
    public static let visualLimit = 50.0

    public let actualUsedPercent: Double
    public let expectedUsedPercent: Double
    public let deltaPoints: Double
    public let markerPosition: Double
    public let equivalentTime: TimeInterval
    public let severity: WeeklyPaceSeverity

    public init?(window: RateLimitWindow, now: Date = Date()) {
        guard let durationMinutes = window.durationMinutes,
              durationMinutes >= 9_000,
              let resetsAt = window.resetsAt else { return nil }

        let duration = TimeInterval(durationMinutes * 60)
        guard duration > 0 else { return nil }
        let start = resetsAt.addingTimeInterval(-duration)
        let elapsed = min(max(now.timeIntervalSince(start), 0), duration)
        let expected = elapsed / duration * 100
        let actual = Double(window.usedPercent)
        let delta = actual - expected

        actualUsedPercent = actual
        expectedUsedPercent = expected
        deltaPoints = delta
        markerPosition = min(max(delta / Self.visualLimit, -1), 1)
        equivalentTime = abs(delta) / 100 * duration
        if delta <= -0.5 {
            severity = .belowPace
        } else if delta < 0.5 {
            severity = .onPace
        } else if delta < 15 {
            severity = .elevated
        } else if delta < 30 {
            severity = .high
        } else {
            severity = .veryHigh
        }
    }

    public var summaryText: String {
        guard abs(deltaPoints) >= 0.5 else { return "On pace" }
        let totalHours = max(1, Int(equivalentTime / 3_600))
        let days = totalHours / 24
        let hours = totalHours % 24
        let timeText: String
        if days > 0, hours > 0 {
            timeText = "\(days)d \(hours)h"
        } else if days > 0 {
            timeText = "\(days)d"
        } else {
            timeText = "\(hours)h"
        }
        return deltaPoints > 0 ? "usage is \(timeText) ahead" : "usage is \(timeText) under pace"
    }
}

public struct RateLimitSnapshot: Equatable, Sendable, Codable {
    public let limitID: String?
    public let limitName: String?
    public let planType: String?
    public let primary: RateLimitWindow?
    public let secondary: RateLimitWindow?

    public init(limitID: String?, limitName: String?, planType: String?, primary: RateLimitWindow?, secondary: RateLimitWindow?) {
        self.limitID = limitID
        self.limitName = limitName
        self.planType = planType
        self.primary = primary
        self.secondary = secondary
    }

    public var windows: [RateLimitWindow] { [primary, secondary].compactMap { $0 } }
    public var mostConstrainedWindow: RateLimitWindow? {
        windows.min { $0.remainingPercent < $1.remainingPercent }
    }
    public var mostConstrainedRemaining: Int? { mostConstrainedWindow?.remainingPercent }
}

public struct RateLimitPayload: Equatable, Sendable, Codable {
    public let snapshot: RateLimitSnapshot
    public let fetchedAt: Date
    public let availableResetCredits: Int?

    public init(snapshot: RateLimitSnapshot, fetchedAt: Date, availableResetCredits: Int? = nil) {
        self.snapshot = snapshot
        self.fetchedAt = fetchedAt
        self.availableResetCredits = availableResetCredits
    }
}

public enum RateLimitParser {
    public static func parseResponse(_ data: Data, now: Date = Date()) throws -> RateLimitPayload? {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let root = object as? [String: Any] else { return nil }

        if let error = root["error"] as? [String: Any] {
            throw CodexClientError.server(error["message"] as? String ?? "Codex returned an unknown error.")
        }

        guard let result = root["result"] as? [String: Any],
              let rawSnapshot = selectSnapshot(from: result) else { return nil }

        let resetCredits = (result["rateLimitResetCredits"] as? [String: Any])
            .flatMap { integer($0["availableCount"]) }
        return RateLimitPayload(
            snapshot: parseSnapshot(rawSnapshot),
            fetchedAt: now,
            availableResetCredits: resetCredits.map { max(0, $0) }
        )
    }

    public static func parseNotification(_ data: Data, now: Date = Date()) throws -> RateLimitPayload? {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let root = object as? [String: Any],
              root["method"] as? String == "account/rateLimits/updated",
              let params = root["params"] as? [String: Any],
              let rawSnapshot = params["rateLimits"] as? [String: Any] else { return nil }
        return RateLimitPayload(snapshot: parseSnapshot(rawSnapshot), fetchedAt: now)
    }

    private static func selectSnapshot(from result: [String: Any]) -> [String: Any]? {
        if let byID = result["rateLimitsByLimitId"] as? [String: Any] {
            if let codex = byID["codex"] as? [String: Any] { return codex }
            if let first = byID.values.compactMap({ $0 as? [String: Any] }).first { return first }
        }
        return result["rateLimits"] as? [String: Any]
    }

    private static func parseSnapshot(_ raw: [String: Any]) -> RateLimitSnapshot {
        RateLimitSnapshot(
            limitID: raw["limitId"] as? String,
            limitName: raw["limitName"] as? String,
            planType: raw["planType"] as? String,
            primary: parseWindow(raw["primary"]),
            secondary: parseWindow(raw["secondary"])
        )
    }

    private static func parseWindow(_ value: Any?) -> RateLimitWindow? {
        guard let raw = value as? [String: Any], let used = integer(raw["usedPercent"]) else { return nil }
        let reset = integer(raw["resetsAt"]).map { Date(timeIntervalSince1970: TimeInterval($0)) }
        return RateLimitWindow(
            usedPercent: max(0, min(100, used)),
            resetsAt: reset,
            durationMinutes: integer(raw["windowDurationMins"])
        )
    }

    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }
}
