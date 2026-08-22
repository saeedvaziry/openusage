import XCTest
@testable import OpenUsage

final class XalUsageScannerTests: XCTestCase {
    private func pricing() -> ModelPricing {
        ModelPricing(
            supplement: PricingSupplement(),
            primary: PricingCatalog(entries: [
                "gpt-5.2": ModelRates(
                    inputPerMillion: 1000,
                    outputPerMillion: 3000,
                    cacheWritePerMillion: 1000,
                    cacheReadPerMillion: 100
                ),
                "claude-test": ModelRates(
                    inputPerMillion: 1000,
                    outputPerMillion: 3000,
                    cacheWritePerMillion: 1250,
                    cacheReadPerMillion: 100
                )
            ]),
            secondary: PricingCatalog(entries: [:])
        )
    }

    private func line(
        id: String = UUID().uuidString,
        timestamp: String = "2026-08-22T12:34:56.000Z",
        provider: String,
        model: String,
        input: Int,
        cacheRead: Int = 0,
        cacheWrite: Int = 0,
        output: Int
    ) -> String {
        let object: [String: Any] = [
            "type": "provider_usage",
            "version": 1,
            "id": id,
            "timestamp": timestamp,
            "provider": provider,
            "model": model,
            "phase": "turn",
            "outcome": "completed",
            "usage": [
                "totalInputTokens": input,
                "cacheReadInputTokens": cacheRead,
                "cacheWriteInputTokens": cacheWrite,
                "outputTokens": output
            ]
        ]
        return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    func testParsesSupportedProvidersAndTokenBuckets() {
        let data = [
            line(
                id: "codex-request",
                provider: "openai-chatgpt",
                model: "gpt-5.2-1m-fast",
                input: 1000,
                cacheRead: 300,
                output: 200
            ),
            line(
                id: "claude-request",
                provider: "anthropic",
                model: "claude-test",
                input: 800,
                cacheRead: 200,
                cacheWrite: 100,
                output: 50
            ),
            line(provider: "openrouter", model: "unknown", input: 10, output: 5)
        ].joined(separator: "\n")

        let entries = XalUsageScanner.parseFile(Data(data.utf8))

        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].cardID, "codex")
        XCTAssertEqual(entries[0].model, "gpt-5.2")
        XCTAssertTrue(entries[0].tokens.isFast)
        XCTAssertEqual(entries[0].tokens.input, 700)
        XCTAssertEqual(entries[0].tokens.cacheRead, 300)
        XCTAssertEqual(entries[0].reportedTotalTokens, 1200)
        XCTAssertEqual(entries[1].cardID, "claude")
        XCTAssertEqual(entries[1].tokens.input, 500)
        XCTAssertEqual(entries[1].tokens.cacheRead, 200)
        XCTAssertEqual(entries[1].tokens.cacheWrite5m, 100)
    }

    func testDeduplicatesRequestIDsAcrossFiles() {
        let entry = XalUsageScanner.parseFile(Data(line(
            id: "same-request",
            provider: "anthropic",
            model: "claude-test",
            input: 100,
            output: 20
        ).utf8))[0]

        XCTAssertEqual(XalUsageScanner.dedup([entry, entry]), [entry])
    }

    func testAggregatesUsageIntoUnderlyingProviderCards() {
        let data = [
            line(
                id: "codex-request",
                provider: "openai-chatgpt",
                model: "gpt-5.2",
                input: 1000,
                cacheRead: 400,
                output: 200
            ),
            line(
                id: "second-identical-codex-request",
                provider: "openai-chatgpt",
                model: "gpt-5.2",
                input: 1000,
                cacheRead: 400,
                output: 200
            ),
            line(
                id: "claude-request",
                provider: "anthropic",
                model: "claude-test",
                input: 1000,
                cacheRead: 400,
                cacheWrite: 100,
                output: 200
            )
        ].joined(separator: "\n")
        let entries = XalUsageScanner.parseFile(Data(data.utf8))

        let codex = XalUsageScanner.aggregate(
            entries: entries,
            cardID: "codex",
            since: .distantPast,
            pricing: pricing()
        )
        let claude = XalUsageScanner.aggregate(
            entries: entries,
            cardID: "claude",
            since: .distantPast,
            pricing: pricing()
        )

        XCTAssertEqual(codex.series.daily.first?.totalTokens, 2400)
        XCTAssertEqual(codex.series.daily.first?.costUSD ?? 0, 2.48, accuracy: 0.0001)
        XCTAssertEqual(claude.series.daily.first?.totalTokens, 1200)
        XCTAssertEqual(claude.series.daily.first?.costUSD ?? 0, 1.265, accuracy: 0.0001)
    }

    func testScanReadsConfiguredXalHome() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("openusage-xal-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let usage = home.appendingPathComponent("usage", isDirectory: true)
        try FileManager.default.createDirectory(at: usage, withIntermediateDirectories: true)
        let timestamp = OpenUsageISO8601.string(from: Date().addingTimeInterval(-60))
        try line(
            timestamp: timestamp,
            provider: "anthropic",
            model: "claude-test",
            input: 100,
            output: 20
        ).write(to: usage.appendingPathComponent("run.jsonl"), atomically: true, encoding: .utf8)
        let scanner = XalUsageScanner(
            environment: FakeEnvironment(["XAL_HOME": home.path]),
            incrementalScanner: IncrementalJSONLScanner<XalUsageScanner.Entry>()
        )

        let scan = await scanner.scan(cardID: "claude", pricing: pricing())
        let unrelated = await scanner.scan(cardID: "codex", pricing: pricing())

        XCTAssertEqual(scan?.series.daily.first?.totalTokens, 120)
        XCTAssertNil(unrelated)
    }
}
