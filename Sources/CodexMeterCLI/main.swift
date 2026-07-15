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
            valuedFlags: ["--days", "--currency", "--exchange-rate", "--input-rate", "--cached-input-rate", "--output-rate"]
        )
        let json = options.flags.contains("--json")
        let days = try intValue(options.values["--days"], flag: "--days", range: 1...90) ?? 7
        let inputRate = try doubleValue(options.values["--input-rate"], flag: "--input-rate") ?? 0
        let cachedRate = try doubleValue(options.values["--cached-input-rate"], flag: "--cached-input-rate") ?? 0
        let outputRate = try doubleValue(options.values["--output-rate"], flag: "--output-rate") ?? 0
        let currency = try currencyValue(options.values["--currency"])
        let exchangeRate = try doubleValue(options.values["--exchange-rate"], flag: "--exchange-rate")
        if let exchangeRate, exchangeRate == 0 { throw CLIError.argument("--exchange-rate requires a number greater than zero.") }
        if options.values["--exchange-rate"] != nil, options.values["--currency"] == nil {
            throw CLIError.argument("--exchange-rate requires --currency.")
        }

        let snapshot = try await LocalActivityScanner().scan(days: days)
        let rates = LocalCostRates(inputPerMillion: inputRate, cachedInputPerMillion: cachedRate, outputPerMillion: outputRate)
        let estimates = snapshot.models.map { item -> ModelEstimate in
            if let price = OpenAIPriceCatalog.price(for: item.model) {
                return ModelEstimate(model: item.model, usage: item.usage, price: price, apiEquivalentEstimate: currency.convertFromUSD(price.estimate(item.usage), overrideRate: exchangeRate), pricing: "official")
            }
            let fallback = rates.isConfigured ? currency.convertFromUSD(rates.estimate(item.usage), overrideRate: exchangeRate) : nil
            return ModelEstimate(model: item.model, usage: item.usage, price: nil, apiEquivalentEstimate: fallback, pricing: rates.isConfigured ? "fallback" : "unpriced")
        }
        let totalEstimate = estimates.compactMap(\.apiEquivalentEstimate).reduce(0, +)
        if json {
            struct Output: Encodable {
                let schemaVersion = 2
                let activity: LocalActivitySnapshot
                let models: [ModelEstimate]
                let apiEquivalentEstimate: Double
                let priceCatalogEffectiveDate: String
                let priceCatalogSource: URL
                let currency: String
                let usdToCurrencyRate: Double
                let exchangeRateEffectiveDate: String
                let exchangeRateSource: URL
            }
            print(try encode(Output(activity: snapshot, models: estimates, apiEquivalentEstimate: totalEstimate, priceCatalogEffectiveDate: OpenAIPriceCatalog.effectiveDate, priceCatalogSource: OpenAIPriceCatalog.sourceURL, currency: currency.code, usdToCurrencyRate: exchangeRate ?? currency.bundledUSDExchangeRate, exchangeRateEffectiveDate: CurrencyRateCatalog.effectiveDate, exchangeRateSource: CurrencyRateCatalog.sourceURL)))
        } else {
            for day in snapshot.days {
                print("\(day.date.formatted(date: .numeric, time: .omitted)): \(day.usage.totalTokens) tokens")
            }
            print("total: \(snapshot.total.totalTokens) tokens")
            for item in estimates {
                let cost = item.apiEquivalentEstimate.map { formattedCurrency($0, currency: currency) } ?? "unpriced"
                print("  \(item.model): \(item.usage.totalTokens) tokens · \(cost) [\(item.pricing)]")
            }
            print("API-equivalent estimate: \(formattedCurrency(totalEstimate, currency: currency))")
            print("Official standard API prices checked \(OpenAIPriceCatalog.effectiveDate); not subscription spend.")
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

    private static func currencyValue(_ raw: String?) throws -> DisplayCurrency {
        guard let raw else { return .usd }
        guard let currency = DisplayCurrency(rawValue: raw.uppercased()) else {
            throw CLIError.argument("--currency requires USD, AUD, or EUR.")
        }
        return currency
    }

    private static func formattedCurrency(_ amount: Double, currency: DisplayCurrency) -> String {
        "\(currency.symbol)\(amount.formatted(.number.precision(.fractionLength(4))))"
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
                              [--currency USD|AUD|EUR] [--exchange-rate N]
                              [--input-rate N] [--cached-input-rate N] [--output-rate N]

        Exit codes: 0 success, 1 operational/argument error, 2 at or below threshold.
        Known models use bundled official standard API prices. USD is the default; AUD and EUR use dated ECB reference rates.
        --exchange-rate overrides USD-to-selected-currency conversion. Rate flags are fallbacks for unknown models.
        Estimates are API-equivalent and are not ChatGPT subscription spend.
        """)
    }
}

private struct ModelEstimate: Encodable {
    let model: String
    let usage: TokenUsage
    let price: ModelPrice?
    let apiEquivalentEstimate: Double?
    let pricing: String
}
