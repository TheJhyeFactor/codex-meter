import CodexMeterCore
import Foundation

private struct StatusOutput: Encodable {
    let schemaVersion = 1
    let fetchedAt: Date
    let planType: String?
    let tightestRemainingPercent: Int
    let windows: [Window]

    struct Window: Encodable {
        let name: String
        let durationMinutes: Int?
        let usedPercent: Int
        let remainingPercent: Int
        let resetsAt: Date?
    }
}

private enum CLIError: LocalizedError {
    case argument(String)
    case noUsage

    var errorDescription: String? {
        switch self {
        case .argument(let message): return message
        case .noUsage: return "Codex returned no rate-limit windows."
        }
    }
}

private struct ParsedOptions {
    let flags: Set<String>
    let values: [String: String]
}

@main
struct CodexMeterCLI {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments.contains("--help") || arguments.contains("-h") {
                printHelp()
                Foundation.exit(0)
            }
            if arguments.first == "history" {
                try await history(Array(arguments.dropFirst()))
            } else {
                try await status(arguments.first == "status" ? Array(arguments.dropFirst()) : arguments)
            }
        } catch {
            FileHandle.standardError.write(Data("codex-meter: \(error.localizedDescription)\n".utf8))
            Foundation.exit(1)
        }
    }

    private static func status(_ arguments: [String]) async throws {
        let options = try parseOptions(arguments, booleanFlags: ["--json"], valuedFlags: ["--threshold"])
        let json = options.flags.contains("--json")
        let threshold = try intValue(options.values["--threshold"], flag: "--threshold", range: 0...100)

        let client = CodexAppServerClient()
        let payload = try await client.readRateLimits()
        await client.stop()
        guard let tightest = payload.snapshot.mostConstrainedRemaining else { throw CLIError.noUsage }

        let output = StatusOutput(
            fetchedAt: payload.fetchedAt,
            planType: payload.snapshot.planType,
            tightestRemainingPercent: tightest,
            windows: payload.snapshot.windows.map {
                .init(name: $0.displayName, durationMinutes: $0.durationMinutes, usedPercent: $0.usedPercent, remainingPercent: $0.remainingPercent, resetsAt: $0.resetsAt)
            }
        )
        if json {
            print(try encode(output))
        } else {
            for window in output.windows {
                let reset = window.resetsAt.map { ISO8601DateFormatter().string(from: $0) } ?? "unknown"
                print("\(window.name): \(window.remainingPercent)% remaining; resets \(reset)")
            }
            print("tightest: \(tightest)% remaining")
        }
        if let threshold, tightest <= threshold { Foundation.exit(2) }
    }

    private static func history(_ arguments: [String]) async throws {
        let options = try parseOptions(
            arguments,
            booleanFlags: ["--json"],
            valuedFlags: ["--days", "--input-rate", "--cached-input-rate", "--output-rate"]
        )
        let json = options.flags.contains("--json")
        let days = try intValue(options.values["--days"], flag: "--days", range: 1...90) ?? 7
        let inputRate = try doubleValue(options.values["--input-rate"], flag: "--input-rate") ?? 0
        let cachedRate = try doubleValue(options.values["--cached-input-rate"], flag: "--cached-input-rate") ?? 0
        let outputRate = try doubleValue(options.values["--output-rate"], flag: "--output-rate") ?? 0

        let snapshot = try await LocalActivityScanner().scan(days: days)
        let rates = LocalCostRates(inputPerMillion: inputRate, cachedInputPerMillion: cachedRate, outputPerMillion: outputRate)
        if json {
            struct Output: Encodable {
                let schemaVersion = 1
                let activity: LocalActivitySnapshot
                let apiEquivalentEstimate: Double?
            }
            print(try encode(Output(activity: snapshot, apiEquivalentEstimate: rates.isConfigured ? rates.estimate(snapshot.total) : nil)))
        } else {
            for day in snapshot.days {
                print("\(day.date.formatted(date: .numeric, time: .omitted)): \(day.usage.totalTokens) tokens")
            }
            print("total: \(snapshot.total.totalTokens) tokens")
            if rates.isConfigured {
                print(String(format: "API-equivalent estimate: $%.4f", rates.estimate(snapshot.total)))
            }
        }
    }

    private static func intValue(_ raw: String?, flag: String, range: ClosedRange<Int>) throws -> Int? {
        guard let raw else { return nil }
        guard let value = Int(raw), range.contains(value) else {
            throw CLIError.argument("\(flag) requires a value from \(range.lowerBound) to \(range.upperBound).")
        }
        return value
    }

    private static func doubleValue(_ raw: String?, flag: String) throws -> Double? {
        guard let raw else { return nil }
        guard let value = Double(raw), value.isFinite, value >= 0 else {
            throw CLIError.argument("\(flag) requires a non-negative number.")
        }
        return value
    }

    private static func parseOptions(_ arguments: [String], booleanFlags: Set<String>, valuedFlags: Set<String>) throws -> ParsedOptions {
        var flags = Set<String>()
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if booleanFlags.contains(argument) {
                guard flags.insert(argument).inserted else { throw CLIError.argument("Duplicate argument: \(argument)") }
                index += 1
                continue
            }
            if valuedFlags.contains(argument) {
                guard values[argument] == nil else { throw CLIError.argument("Duplicate argument: \(argument)") }
                guard arguments.indices.contains(index + 1), !arguments[index + 1].hasPrefix("--") else {
                    throw CLIError.argument("\(argument) requires a value.")
                }
                values[argument] = arguments[index + 1]
                index += 2
                continue
            }
            throw CLIError.argument("Unknown argument: \(argument)")
        }
        return ParsedOptions(flags: flags, values: values)
    }

    private static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private static func printHelp() {
        print("""
        codex-meter — local Codex usage for scripts and alerts

        Usage:
          codex-meter status [--json] [--threshold 0...100]
          codex-meter history [--json] [--days 1...90]
                              [--input-rate N] [--cached-input-rate N] [--output-rate N]

        Exit codes: 0 success, 1 operational/argument error, 2 at or below threshold.
        Cost rates are user-supplied dollars per million tokens and are estimates only.
        """)
    }
}
