import Foundation

/// One OpenAI organization cost line item for the billing-period chart.
public struct OpenAICostLineItem: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public var name: String
    public var amountUSD: Double

    public init(name: String, amountUSD: Double) {
        self.name = name
        self.amountUSD = amountUSD
    }
}

/// Aggregated OpenAI org spend for a period (typically the current calendar month).
public struct OpenAIBillingPeriodSpend: Sendable, Equatable {
    public var periodStart: Date
    public var periodEnd: Date
    public var fetchedAt: Date
    public var totalUSD: Double
    public var lineItems: [OpenAICostLineItem]
    public var currency: String

    public init(
        periodStart: Date,
        periodEnd: Date,
        fetchedAt: Date = Date(),
        totalUSD: Double,
        lineItems: [OpenAICostLineItem],
        currency: String = "usd"
    ) {
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.fetchedAt = fetchedAt
        self.totalUSD = totalUSD
        self.lineItems = lineItems
        self.currency = currency
    }

    /// Top N line items for the bar chart (already sorted descending).
    public func chartItems(limit: Int = 8) -> [OpenAICostLineItem] {
        Array(lineItems.prefix(max(0, limit)))
    }

    public var periodLabel: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM yyyy"
        return formatter.string(from: periodStart)
    }
}

/// Pure helpers: billing-period bounds + OpenAI `/organization/costs` JSON aggregation.
public enum OpenAICostsDiff {
    public static func periodBounds(
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> (start: Date, end: Date) {
        let comps = calendar.dateComponents([.year, .month], from: now)
        let start = calendar.date(from: comps) ?? now
        return (start, now)
    }

    public static func unixSeconds(_ date: Date) -> Int {
        Int(date.timeIntervalSince1970)
    }

    /// Parse one costs page (or concatenated pages) and aggregate by `line_item`.
    public static func aggregate(
        pages: [Data],
        periodStart: Date,
        periodEnd: Date,
        fetchedAt: Date = Date()
    ) -> OpenAIBillingPeriodSpend? {
        var totals: [String: Double] = [:]
        var currency = "usd"
        var sawBucket = false

        for data in pages {
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let buckets = root["data"] as? [[String: Any]] else {
                continue
            }
            for bucket in buckets {
                sawBucket = true
                guard let results = bucket["results"] as? [[String: Any]] else { continue }
                for result in results {
                    let name = ((result["line_item"] as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines))
                        .flatMap { $0.isEmpty ? nil : $0 } ?? "Other"
                    guard let amount = result["amount"] as? [String: Any] else { continue }
                    if let c = amount["currency"] as? String, !c.isEmpty {
                        currency = c.lowercased()
                    }
                    let value = number(amount["value"]) ?? 0
                    totals[name, default: 0] += value
                }
            }
        }

        guard sawBucket else { return nil }

        let items = totals
            .map { OpenAICostLineItem(name: $0.key, amountUSD: $0.value) }
            .sorted { $0.amountUSD > $1.amountUSD }
        let total = items.reduce(0.0) { $0 + $1.amountUSD }
        return OpenAIBillingPeriodSpend(
            periodStart: periodStart,
            periodEnd: periodEnd,
            fetchedAt: fetchedAt,
            totalUSD: total,
            lineItems: items,
            currency: currency
        )
    }

    /// Convenience when a single response body is available.
    public static func aggregate(
        data: Data,
        periodStart: Date,
        periodEnd: Date,
        fetchedAt: Date = Date()
    ) -> OpenAIBillingPeriodSpend? {
        aggregate(pages: [data], periodStart: periodStart, periodEnd: periodEnd, fetchedAt: fetchedAt)
    }

    public static func nextPageToken(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let hasMore = root["has_more"] as? Bool ?? false
        guard hasMore else { return nil }
        let page = (root["next_page"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (page?.isEmpty == false) ? page : nil
    }

    private static func number(_ value: Any?) -> Double? {
        if let v = value as? Double { return v }
        if let v = value as? Int { return Double(v) }
        if let v = value as? NSNumber { return v.doubleValue }
        if let v = value as? String, let d = Double(v) { return d }
        return nil
    }
}
