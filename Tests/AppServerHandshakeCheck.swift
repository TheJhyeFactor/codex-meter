import Foundation
#if canImport(CodexMeterCore)
import CodexMeterCore
#endif

@main
struct AppServerHandshakeCheck {
    static func main() async throws {
        if CommandLine.arguments.dropFirst().first == "app-server" {
            try runFakeServer()
            return
        }

        let candidates = CodexAppServerClient.executableCandidatePaths(
            home: "/Users/tester",
            environment: ["CODEX_PATH": "/custom/codex"]
        )
        precondition(candidates.prefix(4).elementsEqual([
            "/custom/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex"
        ]))

        let client = CodexAppServerClient(
            executableURL: URL(fileURLWithPath: CommandLine.arguments[0])
        )
        let payload = try await client.readRateLimits()
        precondition(payload.snapshot.limitID == "codex")
        precondition(payload.snapshot.secondary?.remainingPercent == 56)
        await client.stop()
        print("Deterministic app-server initialization handshake passed")
    }

    private static func runFakeServer() throws {
        var step = 0
        while let line = readLine() {
            let data = Data(line.utf8)
            guard let message = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = message["method"] as? String else { exit(20) }
            switch (step, method) {
            case (0, "initialize"):
                guard let id = message["id"] else { exit(21) }
                write(["id": id, "result": [:]])
                step = 1
            case (1, "initialized"):
                step = 2
            case (2, "account/rateLimits/read"):
                guard let id = message["id"] else { exit(22) }
                write([
                    "id": id,
                    "result": [
                        "rateLimitsByLimitId": [
                            "codex": [
                                "limitId": "codex",
                                "planType": "prolite",
                                "secondary": [
                                    "usedPercent": 44,
                                    "windowDurationMins": 10_080,
                                    "resetsAt": 2_000_000_000
                                ]
                            ]
                        ]
                    ]
                ])
                return
            default:
                exit(23)
            }
        }
        exit(24)
    }

    private static func write(_ object: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: object)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    }
}
