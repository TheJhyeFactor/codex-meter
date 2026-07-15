import Foundation

public struct TokenUsage: Codable, Equatable, Sendable {
    public var inputTokens: Int64
    public var cachedInputTokens: Int64
    public var outputTokens: Int64
    public var totalTokens: Int64

    public init(inputTokens: Int64 = 0, cachedInputTokens: Int64 = 0, outputTokens: Int64 = 0, totalTokens: Int64 = 0) {
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
    }

    public static func + (lhs: Self, rhs: Self) -> Self {
        Self(
            inputTokens: saturatedAdd(lhs.inputTokens, rhs.inputTokens),
            cachedInputTokens: saturatedAdd(lhs.cachedInputTokens, rhs.cachedInputTokens),
            outputTokens: saturatedAdd(lhs.outputTokens, rhs.outputTokens),
            totalTokens: saturatedAdd(lhs.totalTokens, rhs.totalTokens)
        )
    }

    private static func saturatedAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? Int64.max : result.partialValue
    }

    fileprivate func isAtLeast(_ other: Self) -> Bool {
        inputTokens >= other.inputTokens
            && cachedInputTokens >= other.cachedInputTokens
            && outputTokens >= other.outputTokens
            && totalTokens >= other.totalTokens
    }

    fileprivate static func delta(from previous: Self, to current: Self) -> Self {
        Self(
            inputTokens: current.inputTokens - previous.inputTokens,
            cachedInputTokens: current.cachedInputTokens - previous.cachedInputTokens,
            outputTokens: current.outputTokens - previous.outputTokens,
            totalTokens: current.totalTokens - previous.totalTokens
        )
    }

    fileprivate var fingerprint: String {
        "\(inputTokens):\(cachedInputTokens):\(outputTokens):\(totalTokens)"
    }
}

public enum LocalActivityError: LocalizedError, Equatable {
    case unreadableSource
    case filterUnavailable
    case filterFailed
    case unsupportedRecords

    public var errorDescription: String? {
        switch self {
        case .unreadableSource: return "Local Codex session history is not readable."
        case .filterUnavailable: return "The local history filter could not be started."
        case .filterFailed: return "Local Codex session history could not be filtered."
        case .unsupportedRecords: return "Codex returned an unsupported local usage record format."
        }
    }
}

public struct DailyTokenUsage: Codable, Equatable, Identifiable, Sendable {
    public let date: Date
    public let usage: TokenUsage
    public var id: Date { date }

    public init(date: Date, usage: TokenUsage) {
        self.date = date
        self.usage = usage
    }
}

public struct LocalActivitySnapshot: Codable, Equatable, Sendable {
    public let days: [DailyTokenUsage]
    public let sampledAt: Date
    public let filesRead: Int

    public init(days: [DailyTokenUsage], sampledAt: Date, filesRead: Int) {
        self.days = days
        self.sampledAt = sampledAt
        self.filesRead = filesRead
    }

    public var total: TokenUsage { days.reduce(TokenUsage()) { $0 + $1.usage } }
    public var today: TokenUsage { days.last?.usage ?? TokenUsage() }
}

public struct LocalCostRates: Codable, Equatable, Sendable {
    public var inputPerMillion: Double
    public var cachedInputPerMillion: Double
    public var outputPerMillion: Double

    public init(inputPerMillion: Double, cachedInputPerMillion: Double, outputPerMillion: Double) {
        self.inputPerMillion = max(0, inputPerMillion)
        self.cachedInputPerMillion = max(0, cachedInputPerMillion)
        self.outputPerMillion = max(0, outputPerMillion)
    }

    public var isConfigured: Bool { inputPerMillion > 0 || cachedInputPerMillion > 0 || outputPerMillion > 0 }

    public func estimate(_ usage: TokenUsage) -> Double {
        let nonCached = max(0, usage.inputTokens - usage.cachedInputTokens)
        return Double(nonCached) / 1_000_000 * inputPerMillion
            + Double(usage.cachedInputTokens) / 1_000_000 * cachedInputPerMillion
            + Double(usage.outputTokens) / 1_000_000 * outputPerMillion
    }
}

public actor LocalActivityScanner {
    private struct CumulativeRecord: Sendable {
        let date: Date
        let total: TokenUsage
    }

    private struct Event: Sendable {
        let date: Date
        let usage: TokenUsage
        let fingerprint: String
    }

    private var cachedSignature: String?
    private var cachedEvents: [Event] = []
    private let roots: [URL]
    private let calendar: Calendar
    private let fractionalISO = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private let standardISO = Date.ISO8601FormatStyle()

    public init(roots: [URL]? = nil, calendar: Calendar = .current) {
        if let roots {
            self.roots = roots
        } else {
            let codex = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
            self.roots = [
                codex.appendingPathComponent("sessions", isDirectory: true),
                codex.appendingPathComponent("archived_sessions", isDirectory: true)
            ]
        }
        self.calendar = calendar
    }

    public func scan(days dayCount: Int = 7, now: Date = Date()) async throws -> LocalActivitySnapshot {
        let days = max(1, min(90, dayCount))
        let startToday = calendar.startOfDay(for: now)
        let cutoff = calendar.date(byAdding: .day, value: -(days - 1), to: startToday) ?? startToday
        let candidates = try discoverFiles(modifiedSince: calendar.date(byAdding: .day, value: -1, to: cutoff) ?? cutoff)
        let signature = candidates.compactMap { url -> String? in
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = values.fileSize,
                  let modifiedAt = values.contentModificationDate else { return nil }
            return "\(url.path):\(size):\(modifiedAt.timeIntervalSince1970)"
        }.joined(separator: "|")
        let allEvents: [Event]
        if signature == cachedSignature {
            allEvents = cachedEvents
        } else {
            allEvents = try readEvents(from: candidates)
            cachedSignature = signature
            cachedEvents = allEvents
        }

        var seen = Set<String>()
        var buckets: [Date: TokenUsage] = [:]
        for event in allEvents where event.date >= cutoff && event.date <= now {
            guard seen.insert(event.fingerprint).inserted else { continue }
            let day = calendar.startOfDay(for: event.date)
            buckets[day] = (buckets[day] ?? TokenUsage()) + event.usage
        }

        let output = (0..<days).compactMap { offset -> DailyTokenUsage? in
            guard let date = calendar.date(byAdding: .day, value: offset, to: cutoff) else { return nil }
            return DailyTokenUsage(date: date, usage: buckets[date] ?? TokenUsage())
        }
        return LocalActivitySnapshot(days: output, sampledAt: now, filesRead: candidates.count)
    }

    private func discoverFiles(modifiedSince cutoff: Date) throws -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        var urls: [URL] = []
        for root in roots {
            if FileManager.default.fileExists(atPath: root.path), !FileManager.default.isReadableFile(atPath: root.path) {
                throw LocalActivityError.unreadableSource
            }
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                guard let values = try? url.resourceValues(forKeys: Set(keys)),
                      values.isRegularFile == true,
                      (values.contentModificationDate ?? .distantPast) >= cutoff else { continue }
                urls.append(url)
            }
        }
        return urls
    }

    private func readEvents(from urls: [URL]) throws -> [Event] {
        guard !urls.isEmpty else { return [] }
        var recordsBySession: [String: [CumulativeRecord]] = [:]
        var matchesFound = 0
        var decodedRecords = 0
        let jsonMarker = Data(":{\"timestamp\"".utf8)
        for batchStart in stride(from: 0, to: urls.count, by: 100) {
            let batch = Array(urls[batchStart..<min(batchStart + 100, urls.count)])
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/grep")
            process.arguments = ["-H", "-F", "\"type\":\"token_count\""] + batch.map(\.path)
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { throw LocalActivityError.filterUnavailable }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 || process.terminationStatus == 1 else {
                throw LocalActivityError.filterFailed
            }
            for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) where line.count <= 5_000_000 {
                matchesFound += 1
                let raw = Data(line)
                guard let marker = raw.range(of: jsonMarker),
                      let path = String(data: raw[..<marker.lowerBound], encoding: .utf8),
                      let record = decodeRecord(Data(raw[(marker.lowerBound + 1)...])) else { continue }
                decodedRecords += 1
                let sessionID = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
                recordsBySession[sessionID, default: []].append(record)
            }
        }
        if matchesFound > 0, decodedRecords == 0 { throw LocalActivityError.unsupportedRecords }

        var output: [Event] = []
        for (sessionID, records) in recordsBySession {
            var previous: TokenUsage?
            var generation = 0
            for record in records.sorted(by: { $0.date < $1.date }) {
                let delta: TokenUsage
                if let previous {
                    if record.total == previous { continue }
                    if record.total.isAtLeast(previous) {
                        delta = .delta(from: previous, to: record.total)
                    } else {
                        generation += 1
                        delta = record.total
                    }
                } else {
                    delta = record.total
                }
                previous = record.total
                guard delta.totalTokens > 0 else { continue }
                output.append(Event(
                    date: record.date,
                    usage: delta,
                    fingerprint: "\(sessionID):\(generation):\(record.total.fingerprint)"
                ))
            }
        }
        return output
    }

    private func decodeRecord(_ data: Data) -> CumulativeRecord? {
        guard let record = try? JSONDecoder().decode(TokenRecord.self, from: data),
              record.type == "event_msg",
              record.payload.type == "token_count",
              let info = record.payload.info,
              let total = info.totalTokenUsage?.validated,
              let date = parseDate(record.timestamp) else { return nil }
        return CumulativeRecord(date: date, total: total)
    }

    private func parseDate(_ value: String) -> Date? {
        (try? fractionalISO.parse(value)) ?? (try? standardISO.parse(value))
    }
}

private struct TokenRecord: Decodable {
    let timestamp: String
    let type: String
    let payload: Payload

    struct Payload: Decodable {
        let type: String
        let info: Info?
    }

    struct Info: Decodable {
        let lastTokenUsage: RawUsage?
        let totalTokenUsage: RawUsage?
        let modelContextWindow: Int64?

        enum CodingKeys: String, CodingKey {
            case lastTokenUsage = "last_token_usage"
            case totalTokenUsage = "total_token_usage"
            case modelContextWindow = "model_context_window"
        }
    }

    struct RawUsage: Decodable {
        let inputTokens: Int64
        let cachedInputTokens: Int64
        let outputTokens: Int64
        let totalTokens: Int64

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case cachedInputTokens = "cached_input_tokens"
            case outputTokens = "output_tokens"
            case totalTokens = "total_tokens"
        }

        var validated: TokenUsage? {
            guard inputTokens >= 0, cachedInputTokens >= 0, outputTokens >= 0, totalTokens >= 0,
                  cachedInputTokens <= inputTokens else { return nil }
            return TokenUsage(
                inputTokens: inputTokens,
                cachedInputTokens: cachedInputTokens,
                outputTokens: outputTokens,
                totalTokens: totalTokens
            )
        }
    }
}
