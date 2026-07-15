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
        precondition(payload.snapshot.primary?.displayName == "5-hour limit")
        precondition(payload.snapshot.secondary?.displayName == "Weekly limit")

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
        print("Parser checks passed")
    }

    private static func require<T>(_ value: T?) throws -> T {
        guard let value else { throw CodexClientError.invalidResponse }
        return value
    }
}
