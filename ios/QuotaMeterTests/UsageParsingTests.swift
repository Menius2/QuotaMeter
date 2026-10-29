import XCTest
@testable import QuotaMeter

final class UsageParsingTests: XCTestCase {
    func testDirectUsageObjectProducesCumulativeTokens() throws {
        let data = Data(
            """
            {
              "balance": 12.5,
              "usage": {
                "input_tokens": 100,
                "output_tokens": 200,
                "request_count": 4
              }
            }
            """.utf8
        )

        let response = try UsageClient.decodeForTesting(data)

        XCTAssertEqual(response.balance, 12.5)
        XCTAssertEqual(response.usage?.total?.inputTokens, 100)
        XCTAssertEqual(response.usage?.total?.outputTokens, 200)
        XCTAssertEqual(response.usage?.total?.totalTokens, 300)
        XCTAssertEqual(response.usage?.total?.requests, 4)
    }

    func testNestedResultUsageAggregatesTokensAndRequests() throws {
        let data = Data(
            """
            {
              "balance": 8,
              "data": [
                {
                  "start_time": 1761004800,
                  "results": [
                    {
                      "input_tokens": 120,
                      "output_tokens": 30,
                      "num_model_requests": 2
                    },
                    {
                      "input_tokens": 80,
                      "output_tokens": 20,
                      "num_model_requests": 3
                    }
                  ]
                }
              ]
            }
            """.utf8
        )

        let response = try UsageClient.decodeForTesting(data)

        XCTAssertEqual(response.usage?.total?.inputTokens, 200)
        XCTAssertEqual(response.usage?.total?.outputTokens, 50)
        XCTAssertEqual(response.usage?.total?.totalTokens, 250)
        XCTAssertEqual(response.usage?.total?.requests, 5)
        XCTAssertEqual(response.dailyUsage?.first?.totalTokens, 250)
    }

    func testPrefixedTodayUsageIsParsed() throws {
        let data = Data(
            """
            {
              "balance": 20,
              "today_tokens": 12345,
              "today_requests": 18,
              "usage": {
                "total_tokens": 98765,
                "total_requests": 130
              }
            }
            """.utf8
        )

        let response = try UsageClient.decodeForTesting(data)

        XCTAssertEqual(response.usage?.today?.totalTokens, 12345)
        XCTAssertEqual(response.usage?.today?.requests, 18)
        XCTAssertEqual(response.usage?.total?.totalTokens, 98765)
        XCTAssertEqual(response.usage?.total?.requests, 130)
    }

    func testTotalSpendPrefersProviderTotal() throws {
        let snapshot = UsageResponse(
            balance: nil,
            dailyUsage: nil,
            isValid: true,
            mode: "compatible",
            planName: "Relay",
            remaining: nil,
            unit: "CNY",
            usage: UsageSummary(
                averageDurationMs: nil,
                rpm: nil,
                tpm: nil,
                today: nil,
                total: UsageCounterEntry(
                    actualCost: 128.4,
                    cacheCreationTokens: nil,
                    cacheReadTokens: nil,
                    cost: 128.4,
                    inputTokens: nil,
                    outputTokens: nil,
                    requests: nil,
                    totalTokens: nil,
                    cacheWriteTokens: nil
                )
            ),
            quota: QuotaSummary(limit: nil, used: 200, remaining: nil),
            rateLimits: nil,
            subscription: nil,
            expiresAt: nil,
            daysUntilExpiry: nil,
            modelStats: nil
        )

        let spend = try XCTUnwrap(QuotaDisplay.spendSummary(for: snapshot))
        XCTAssertEqual(spend.formattedValue, "¥128.40")
        XCTAssertEqual(spend.sourceLabel, "接口返回的累计费用")
    }

    func testTotalSpendFallsBackToDailyCosts() throws {
        let snapshot = UsageResponse(
            balance: nil,
            dailyUsage: [
                DailyUsageEntry(date: "2026-10-21", requests: nil, inputTokens: nil, outputTokens: nil, cacheReadTokens: nil, cacheWriteTokens: nil, actualCost: 1.25, cost: 1.25, totalTokens: nil),
                DailyUsageEntry(date: "2026-10-22", requests: nil, inputTokens: nil, outputTokens: nil, cacheReadTokens: nil, cacheWriteTokens: nil, actualCost: 2.75, cost: 2.75, totalTokens: nil)
            ],
            isValid: true,
            mode: "compatible",
            planName: "Relay",
            remaining: nil,
            unit: "USD",
            usage: nil,
            quota: nil,
            rateLimits: nil,
            subscription: nil,
            expiresAt: nil,
            daysUntilExpiry: nil,
            modelStats: nil
        )

        let spend = try XCTUnwrap(QuotaDisplay.spendSummary(for: snapshot))
        XCTAssertEqual(spend.formattedValue, "$4.00")
        XCTAssertEqual(spend.sourceLabel, "每日记录汇总")
    }
}
