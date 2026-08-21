import Foundation
#if canImport(CodexMeterCore)
import CodexMeterCore
#endif

@main
struct ParserCheck {
    static func main() throws {
        let standard = #"{"id":2,"result":{"rateLimits":{"limitId":"codex","planType":"plus","primary":{"usedPercent":37,"windowDurationMins":300,"resetsAt":2000000000},"secondary":{"usedPercent":81,"windowDurationMins":10080,"resetsAt":2000100000}}}}"#
        let payload = try require(RateLimitParser.parseResponse(Data(standard.utf8), now: Date(timeIntervalSince1970: 1)))
        precondition(payload.snapshot.primary?.remainingPercent == 63)
        precondition(payload.snapshot.secondary?.remainingPercent == 19)
        precondition(payload.snapshot.mostConstrainedRemaining == 19)
        precondition(payload.snapshot.mostConstrainedWindow == payload.snapshot.secondary)
        precondition(payload.snapshot.primary?.displayName == "5-hour limit")
        precondition(payload.snapshot.secondary?.displayName == "Weekly limit")
        precondition(payload.availableResetCredits == nil)

        let withBankedResets = #"{"id":3,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":10}},"rateLimitResetCredits":{"availableCount":2,"credits":null}}}"#
        let banked = try require(RateLimitParser.parseResponse(Data(withBankedResets.utf8)))
        precondition(banked.availableResetCredits == 2)

        let buckets = #"{"id":2,"result":{"rateLimits":{},"rateLimitsByLimitId":{"other":{"primary":{"usedPercent":4}},"codex":{"primary":{"usedPercent":22}}}}}"#
        let selected = try require(RateLimitParser.parseResponse(Data(buckets.utf8)))
        precondition(selected.snapshot.primary?.remainingPercent == 78)

        let clamped = #"{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":125},"secondary":{"usedPercent":-4}}}}"#
        let clampedPayload = try require(RateLimitParser.parseResponse(Data(clamped.utf8)))
        precondition(clampedPayload.snapshot.primary?.remainingPercent == 0)
        precondition(clampedPayload.snapshot.secondary?.remainingPercent == 100)

        let update = #"{"method":"account/rateLimits/updated","params":{"rateLimits":{"primary":{"usedPercent":9,"windowDurationMins":300}}}}"#
        let updated = try require(RateLimitParser.parseNotification(Data(update.utf8)))
        precondition(updated.snapshot.primary?.remainingPercent == 91)

        let now = Date(timeIntervalSince1970: 1_000_000)
        let multiDay = ResetCountdownFormatter.format(until: now.addingTimeInterval((2 * 86_400) + (8 * 3_600)), now: now)
        precondition(multiDay.daysText == "2d")
        precondition(multiDay.hoursText == "8h")
        precondition(multiDay.accessibilityText == "2 days, 8 hours until reset")

        let sameDay = ResetCountdownFormatter.format(until: now.addingTimeInterval(8 * 3_600), now: now)
        precondition(sameDay.daysText == "0d")
        precondition(sameDay.hoursText == "8h")

        let underOneHour = ResetCountdownFormatter.format(until: now.addingTimeInterval(59 * 60), now: now)
        precondition(underOneHour.daysText == "0d")
        precondition(underOneHour.hoursText == "<1h")

        let expired = ResetCountdownFormatter.format(until: now.addingTimeInterval(-1), now: now)
        precondition(expired.daysText == "0d")
        precondition(expired.hoursText == "0h")

        let unavailable = ResetCountdownFormatter.format(until: nil, now: now)
        precondition(unavailable.daysText == "--")
        precondition(unavailable.hoursText == "--")

        let tiedPrimary = RateLimitWindow(usedPercent: 50, resetsAt: now.addingTimeInterval(3_600), durationMinutes: 300)
        let tiedSecondary = RateLimitWindow(usedPercent: 50, resetsAt: now.addingTimeInterval(86_400), durationMinutes: 10_080)
        let tied = RateLimitSnapshot(limitID: "codex", limitName: "Codex", planType: "plus", primary: tiedPrimary, secondary: tiedSecondary)
        precondition(tied.mostConstrainedWindow == tiedPrimary)
        print("Parser checks passed")
    }

    private static func require<T>(_ value: T?) throws -> T {
        guard let value else { throw CodexClientError.invalidResponse }
        return value
    }
}
