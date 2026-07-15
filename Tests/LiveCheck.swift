import Foundation
#if canImport(CodexMeterCore)
import CodexMeterCore
#endif

@main
struct LiveCheck {
    static func main() async throws {
        let client = CodexAppServerClient()
        let payload = try await client.readRateLimits()
        guard !payload.snapshot.windows.isEmpty,
              payload.snapshot.mostConstrainedRemaining != nil else {
            throw CodexClientError.invalidResponse
        }
        await client.stop()
        print("Live Codex rate-limit check passed")
    }
}
