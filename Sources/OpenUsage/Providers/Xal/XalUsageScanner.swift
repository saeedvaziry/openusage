import Foundation

actor XalUsageScanner {
    static let shared = XalUsageScanner()

    private let environment: EnvironmentReading
    private let homeDirectory: @Sendable () -> URL
    private let scanner: IncrementalJSONLScanner<Entry>

    private static let sharedScanner = IncrementalJSONLScanner<Entry>(
        logTag: LogTag.plugin("xal"),
        persistence: JSONLScanCachePersistence(namespace: "xal", schemaVersion: 1)
    )

    static func flushPersistentCacheWrites() async {
        await sharedScanner.flushPendingWrites()
    }

    init(
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        homeDirectory: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser },
        incrementalScanner: IncrementalJSONLScanner<Entry>? = nil
    ) {
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.scanner = incrementalScanner ?? Self.sharedScanner
    }

    struct Entry: Codable, Sendable, Equatable {
        var id: String
        var timestamp: Date
        var cardID: String
        var model: String
        var tokens: TokenBreakdown
        var reportedTotalTokens: Int
    }

    func scan(
        cardID: String,
        daysBack: Int = 30,
        now: Date = Date(),
        pricing: ModelPricing
    ) async -> LogUsageScan? {
        let directory = usageDirectory()
        let since = JSONLScanning.sinceDate(daysBack: daysBack, now: now)
        let cacheIdentity = directory.resolvingSymlinksInPath().path
        let files = JSONLScanning.jsonlFiles(under: directory)
        guard !files.isEmpty else {
            _ = await scanner.items(from: [], since: since, cacheIdentity: cacheIdentity, parse: Self.parseFile)
            return nil
        }

        guard let entries = await scanner.items(
            from: files,
            since: since,
            cacheIdentity: cacheIdentity,
            parse: Self.parseFile
        ), !Task.isCancelled else { return nil }
        let matching = Self.dedup(entries).filter { $0.cardID == cardID && $0.timestamp >= since }
        guard !matching.isEmpty else { return nil }
        return Self.aggregate(entries: matching, cardID: cardID, since: since, pricing: pricing)
    }

    private func usageDirectory() -> URL {
        if let raw = environment.value(for: "XAL_HOME")?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            return URL(fileURLWithPath: expandHome(raw)).appendingPathComponent("usage")
        }
        return homeDirectory().appendingPathComponent(".xal/usage")
    }

    static func parseFile(_ data: Data) -> [Entry] {
        let marker = Data(#""type":"provider_usage""#.utf8)
        var entries: [Entry] = []
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard line.range(of: marker) != nil,
                  let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  let entry = parseLine(object)
            else { continue }
            entries.append(entry)
        }
        return entries
    }

    private static func parseLine(_ object: [String: Any]) -> Entry? {
        guard object["type"] as? String == "provider_usage",
              ProviderParse.number(object["version"]) == 1,
              let id = (object["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty,
              let timestampRaw = object["timestamp"] as? String,
              let timestamp = OpenUsageISO8601.date(from: timestampRaw),
              let provider = object["provider"] as? String,
              let cardID = cardID(forXalProvider: provider),
              let model = (object["model"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !model.isEmpty,
              let usage = object["usage"] as? [String: Any],
              let totalInput = nonnegativeInt(usage["totalInputTokens"]),
              let output = nonnegativeInt(usage["outputTokens"])
        else { return nil }

        let cacheRead = min(nonnegativeInt(usage["cacheReadInputTokens"]) ?? 0, totalInput)
        let cacheWrite = min(
            nonnegativeInt(usage["cacheWriteInputTokens"]) ?? 0,
            max(0, totalInput - cacheRead)
        )
        let input = max(0, totalInput - cacheRead - cacheWrite)
        let normalized = normalizedModel(model, cardID: cardID)
        return Entry(
            id: id,
            timestamp: timestamp,
            cardID: cardID,
            model: normalized.model,
            tokens: TokenBreakdown(
                input: input,
                cacheWrite5m: cacheWrite,
                cacheRead: cacheRead,
                output: output,
                isFast: normalized.isFast
            ),
            reportedTotalTokens: totalInput + output
        )
    }

    private static func nonnegativeInt(_ value: Any?) -> Int? {
        guard let number = ProviderParse.number(value),
              number >= 0,
              number <= 1e15,
              number.rounded(.towardZero) == number
        else { return nil }
        return Int(number)
    }

    private static func cardID(forXalProvider provider: String) -> String? {
        switch provider {
        case "openai-chatgpt": return "codex"
        case "anthropic": return "claude"
        case "xai": return "grok"
        default: return nil
        }
    }

    private static func normalizedModel(_ model: String, cardID: String) -> (model: String, isFast: Bool) {
        guard cardID == "codex" else { return (model, false) }
        var normalized = model
        let isFast = normalized.hasSuffix("-fast")
        if isFast { normalized.removeLast("-fast".count) }
        if normalized.hasSuffix("-1m") { normalized.removeLast("-1m".count) }
        return (normalized, isFast)
    }

    static func dedup(_ entries: [Entry]) -> [Entry] {
        var seen: Set<String> = []
        return entries.filter { seen.insert($0.id).inserted }
    }

    static func aggregate(
        entries: [Entry],
        cardID: String,
        since: Date,
        pricing: ModelPricing
    ) -> LogUsageScan {
        if cardID == "codex" {
            return CodexLogUsageScanner.aggregate(
                events: entries.compactMap { entry in
                    guard entry.cardID == cardID, entry.timestamp >= since else { return nil }
                    return CodexLogUsageScanner.Event(
                        timestamp: entry.timestamp,
                        model: entry.model,
                        input: entry.tokens.promptTokens,
                        cached: entry.tokens.cacheRead,
                        output: entry.tokens.output,
                        reasoning: 0,
                        total: entry.reportedTotalTokens,
                        isFast: entry.tokens.isFast
                    )
                },
                since: since,
                pricing: pricing,
                deduplicateEvents: false
            )
        }

        var accumulator = DailyUsageAccumulator()
        for entry in entries where entry.cardID == cardID && entry.timestamp >= since {
            let day = DailyUsageAccumulator.dayKey(from: entry.timestamp)
            guard let cost = pricing.estimatedCostDollars(model: entry.model, tokens: entry.tokens) else {
                if entry.reportedTotalTokens > 0 {
                    accumulator.addUnknownModel(day: day, model: entry.model)
                }
                continue
            }
            accumulator.add(
                day: day,
                tokens: entry.reportedTotalTokens,
                cost: cost,
                model: entry.model
            )
        }
        return accumulator.build()
    }
}
