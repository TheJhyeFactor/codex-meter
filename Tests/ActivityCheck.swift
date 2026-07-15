import Foundation
#if canImport(CodexMeterCore)
import CodexMeterCore
#endif

@main
struct ActivityCheck {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let active = root.appendingPathComponent("active", isDirectory: true)
        let archived = root.appendingPathComponent("archived", isDirectory: true)
        try FileManager.default.createDirectory(at: active, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        let now = Date()
        func event(at offset: TimeInterval, input: Int, cached: Int, output: Int, total: Int) -> String {
            let timestamp = formatter.string(from: now.addingTimeInterval(offset))
            return #"{"timestamp":"\#(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1,"cached_input_tokens":0,"output_tokens":1,"reasoning_output_tokens":0,"total_tokens":2},"total_token_usage":{"input_tokens":\#(input),"cached_input_tokens":\#(cached),"output_tokens":\#(output),"reasoning_output_tokens":0,"total_tokens":\#(total)},"model_context_window":1000},"private_prompt":"never retain me"}}"#
        }
        let records = [
            event(at: -4, input: 100, cached: 40, output: 20, total: 120),
            event(at: -3, input: 100, cached: 40, output: 20, total: 120),
            event(at: -2, input: 150, cached: 50, output: 30, total: 180),
            event(at: -1, input: 30, cached: 5, output: 10, total: 40),
            #"{"timestamp":"\#(formatter.string(from: now))","type":"event_msg","payload":{"type":"user_message","message":"secret"}}"#
        ].joined(separator: "\n") + "\n"
        let name = "rollout-2026-session-abc.jsonl"
        try Data(records.utf8).write(to: active.appendingPathComponent(name))
        try Data(records.utf8).write(to: archived.appendingPathComponent(name))

        let snapshot = try await LocalActivityScanner(roots: [root]).scan(days: 7)
        precondition(snapshot.total.inputTokens == 180)
        precondition(snapshot.total.cachedInputTokens == 55)
        precondition(snapshot.total.outputTokens == 40)
        precondition(snapshot.total.totalTokens == 220)

        let rates = LocalCostRates(inputPerMillion: 2, cachedInputPerMillion: 0.5, outputPerMillion: 8)
        let expected = 125.0 / 1_000_000 * 2 + 55.0 / 1_000_000 * 0.5 + 40.0 / 1_000_000 * 8
        precondition(abs(rates.estimate(snapshot.total) - expected) < 0.0000001)

        let invalidRoot = root.appendingPathComponent("invalid", isDirectory: true)
        try FileManager.default.createDirectory(at: invalidRoot, withIntermediateDirectories: true)
        try Data(#"{"type":"token_count","private":"do not echo"}"#.utf8)
            .write(to: invalidRoot.appendingPathComponent("rollout-invalid.jsonl"))
        do {
            _ = try await LocalActivityScanner(roots: [invalidRoot]).scan(days: 7)
            preconditionFailure("Unsupported records must fail visibly")
        } catch LocalActivityError.unsupportedRecords {
            // Expected: the source line is never included in the error.
        }
        print("Local activity checks passed")
    }
}
