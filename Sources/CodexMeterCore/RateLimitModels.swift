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
    public var mostConstrainedRemaining: Int? { windows.map(\.remainingPercent).min() }
}

public struct RateLimitPayload: Equatable, Sendable, Codable {
    public let snapshot: RateLimitSnapshot
    public let fetchedAt: Date

    public init(snapshot: RateLimitSnapshot, fetchedAt: Date) {
        self.snapshot = snapshot
        self.fetchedAt = fetchedAt
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

        return RateLimitPayload(snapshot: parseSnapshot(rawSnapshot), fetchedAt: now)
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
