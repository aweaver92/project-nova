import XCTest
@testable import NovaDomain

final class OpenAICostsDiffTests: XCTestCase {
    func testPeriodBoundsStartOfMonth() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = cal.date(from: DateComponents(year: 2026, month: 7, day: 22, hour: 12))!
        let bounds = OpenAICostsDiff.periodBounds(now: now, calendar: cal)
        XCTAssertEqual(cal.component(.day, from: bounds.start), 1)
        XCTAssertEqual(cal.component(.month, from: bounds.start), 7)
        XCTAssertEqual(bounds.end, now)
    }

    func testAggregateSumsLineItemsAcrossBuckets() throws {
        let json = """
        {
          "object": "page",
          "has_more": false,
          "data": [
            {
              "object": "bucket",
              "start_time": 1,
              "end_time": 2,
              "results": [
                {
                  "object": "organization.costs.result",
                  "line_item": "gpt-realtime",
                  "amount": { "currency": "usd", "value": 1.25 }
                },
                {
                  "object": "organization.costs.result",
                  "line_item": "gpt-4.1-mini",
                  "amount": { "currency": "usd", "value": 0.40 }
                }
              ]
            },
            {
              "object": "bucket",
              "start_time": 2,
              "end_time": 3,
              "results": [
                {
                  "object": "organization.costs.result",
                  "line_item": "gpt-realtime",
                  "amount": { "currency": "usd", "value": 0.75 }
                },
                {
                  "object": "organization.costs.result",
                  "line_item": "whisper",
                  "amount": { "currency": "usd", "value": 0.10 }
                }
              ]
            }
          ]
        }
        """.data(using: .utf8)!

        let start = Date(timeIntervalSince1970: 0)
        let end = Date(timeIntervalSince1970: 100)
        let spend = try XCTUnwrap(OpenAICostsDiff.aggregate(data: json, periodStart: start, periodEnd: end))
        XCTAssertEqual(spend.totalUSD, 2.50, accuracy: 0.001)
        XCTAssertEqual(spend.lineItems.count, 3)
        XCTAssertEqual(spend.lineItems[0].name, "gpt-realtime")
        XCTAssertEqual(spend.lineItems[0].amountUSD, 2.0, accuracy: 0.001)
        XCTAssertEqual(spend.chartItems(limit: 2).count, 2)
    }

    func testNextPageToken() {
        let withPage = #"{"has_more":true,"next_page":"cursor-abc","data":[]}"#.data(using: .utf8)!
        XCTAssertEqual(OpenAICostsDiff.nextPageToken(from: withPage), "cursor-abc")
        let done = #"{"has_more":false,"next_page":"cursor-abc","data":[]}"#.data(using: .utf8)!
        XCTAssertNil(OpenAICostsDiff.nextPageToken(from: done))
    }

    func testEmptyBucketsYieldZeroSpend() throws {
        let json = #"{"object":"page","has_more":false,"data":[{"object":"bucket","results":[]}]}"#
            .data(using: .utf8)!
        let spend = try XCTUnwrap(
            OpenAICostsDiff.aggregate(
                data: json,
                periodStart: Date(),
                periodEnd: Date()
            )
        )
        XCTAssertEqual(spend.totalUSD, 0)
        XCTAssertTrue(spend.lineItems.isEmpty)
    }
}
