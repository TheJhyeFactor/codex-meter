import Foundation

@main
enum WeeklyPaceCheck {
    static func main() {
        let durationMinutes = 10_080
        let duration = TimeInterval(durationMinutes * 60)
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let reset = start.addingTimeInterval(duration)

        func pace(used: Int, elapsedFraction: Double) -> WeeklyPace {
            let now = start.addingTimeInterval(duration * elapsedFraction)
            let window = RateLimitWindow(usedPercent: used, resetsAt: reset, durationMinutes: durationMinutes)
            return WeeklyPace(window: window, now: now)!
        }

        let beginning = pace(used: 0, elapsedFraction: 0)
        precondition(beginning.expectedUsedPercent == 0)
        precondition(beginning.markerPosition == 0)
        precondition(beginning.summaryText == "On pace")

        let midpoint = pace(used: 50, elapsedFraction: 0.5)
        precondition(abs(midpoint.deltaPoints) < 0.001)
        precondition(midpoint.severity == .onPace)

        let ahead = pace(used: 75, elapsedFraction: 0.5)
        precondition(abs(ahead.deltaPoints - 25) < 0.001)
        precondition(abs(ahead.markerPosition - 0.5) < 0.001)
        precondition(ahead.summaryText == "usage is 1d 18h ahead")
        precondition(ahead.severity == .high)

        let under = pace(used: 25, elapsedFraction: 0.5)
        precondition(abs(under.deltaPoints + 25) < 0.001)
        precondition(abs(under.markerPosition + 0.5) < 0.001)
        precondition(under.summaryText == "usage is 1d 18h under pace")
        precondition(under.severity == .belowPace)

        precondition(pace(used: 100, elapsedFraction: 0).markerPosition == 1)
        precondition(pace(used: 0, elapsedFraction: 1).markerPosition == -1)

        let expired = WeeklyPace(
            window: RateLimitWindow(usedPercent: 100, resetsAt: reset, durationMinutes: durationMinutes),
            now: reset.addingTimeInterval(3_600)
        )!
        precondition(expired.expectedUsedPercent == 100)
        precondition(expired.summaryText == "On pace")

        precondition(WeeklyPace(window: RateLimitWindow(usedPercent: 40, resetsAt: nil, durationMinutes: durationMinutes)) == nil)
        precondition(WeeklyPace(window: RateLimitWindow(usedPercent: 40, resetsAt: reset, durationMinutes: 300)) == nil)

        print("Weekly pace checks passed")
    }
}
