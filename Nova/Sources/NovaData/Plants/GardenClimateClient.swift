import Foundation
import NovaCore
import NovaDomain

/// Open-Meteo geocode + prior-year daily mins → approximate last/first frost dates.
public struct GardenClimateClient: Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func snapshot(city: String, now: Date = Date()) async throws -> GardenClimateSnapshot {
        let trimmed = city.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NovaError.tool("Climate city is empty")
        }
        guard let geo = try await geocode(trimmed) else {
            throw NovaError.tool(
                "City not found: \(trimmed). Try “Philadelphia” or “Philadelphia, Pennsylvania”."
            )
        }
        let year = Calendar.current.component(.year, from: now) - 1
        let mins = try await dailyMinTemps(lat: geo.lat, lon: geo.lon, year: year)
        let (lastSpring, firstFall) = Self.frostAnchors(dailyMins: mins, year: year)
        let mappedLast = Self.mapDayOfYear(lastSpring, onto: now)
        let mappedFirst = Self.mapDayOfYear(firstFall, onto: now)

        var parts: [String] = []
        if let mappedLast, let label = GardenPlanningDiff.formatDate(mappedLast) {
            parts.append("typical last spring frost ~\(label)")
        }
        if let mappedFirst, let label = GardenPlanningDiff.formatDate(mappedFirst) {
            parts.append("typical first fall frost ~\(label)")
        }
        let summary = parts.isEmpty
            ? "No hard-frost days found in prior-year sample — treat frost dates as approximate."
            : parts.joined(separator: "; ") + " (from prior-year climate sample)."

        return GardenClimateSnapshot(
            city: geo.name,
            lastSpringFrost: mappedLast,
            firstFallFrost: mappedFirst,
            summary: summary
        )
    }

    private struct Geo { let name: String; let lat: Double; let lon: Double }

    private func geocode(_ city: String) async throws -> Geo? {
        for candidate in Self.geocodeCandidates(city) {
            if let hit = try await geocodeOnce(candidate) {
                return hit
            }
        }
        return nil
    }

    private func geocodeOnce(_ city: String) async throws -> Geo? {
        var comps = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        comps.queryItems = [
            .init(name: "name", value: city),
            .init(name: "count", value: "5"),
            .init(name: "language", value: "en")
        ]
        struct Response: Decodable {
            struct Result: Decodable {
                let name: String
                let latitude: Double
                let longitude: Double
                let admin1: String?
                let country: String?
                let country_code: String?
                let population: Int?
            }
            let results: [Result]?
        }
        let (data, _) = try await session.data(from: comps.url!)
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        guard let results = decoded.results, !results.isEmpty else { return nil }
        // Prefer the most populous US/Canada hit when several match.
        let preferred = results.max { lhs, rhs in
            (lhs.population ?? 0) < (rhs.population ?? 0)
        } ?? results[0]
        let label = [preferred.name, preferred.admin1, preferred.country]
            .compactMap { $0 }
            .joined(separator: ", ")
        return Geo(
            name: label.isEmpty ? preferred.name : label,
            lat: preferred.latitude,
            lon: preferred.longitude
        )
    }

    /// Open-Meteo accepts "City, FullState" better than US postal abbreviations.
    static func geocodeCandidates(_ raw: String) -> [String] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var out: [String] = []
        func add(_ value: String) {
            let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !v.isEmpty, !out.contains(where: { $0.caseInsensitiveCompare(v) == .orderedSame }) else { return }
            out.append(v)
        }

        add(trimmed)
        if let expanded = expandUSStateAbbreviation(trimmed) {
            add(expanded)
        }
        // City-only fallback (drop ", PA" / ", Pennsylvania").
        if let comma = trimmed.firstIndex(of: ",") {
            add(String(trimmed[..<comma]))
        }
        return out
    }

    /// "Philadelphia, PA" → "Philadelphia, Pennsylvania"
    static func expandUSStateAbbreviation(_ raw: String) -> String? {
        let parts = raw.split(separator: ",", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard parts.count == 2, parts[0].count >= 2 else { return nil }
        let abbr = parts[1].uppercased()
        guard let full = usStateNames[abbr] else { return nil }
        return "\(parts[0]), \(full)"
    }

    private static let usStateNames: [String: String] = [
        "AL": "Alabama", "AK": "Alaska", "AZ": "Arizona", "AR": "Arkansas",
        "CA": "California", "CO": "Colorado", "CT": "Connecticut", "DE": "Delaware",
        "FL": "Florida", "GA": "Georgia", "HI": "Hawaii", "ID": "Idaho",
        "IL": "Illinois", "IN": "Indiana", "IA": "Iowa", "KS": "Kansas",
        "KY": "Kentucky", "LA": "Louisiana", "ME": "Maine", "MD": "Maryland",
        "MA": "Massachusetts", "MI": "Michigan", "MN": "Minnesota", "MS": "Mississippi",
        "MO": "Missouri", "MT": "Montana", "NE": "Nebraska", "NV": "Nevada",
        "NH": "New Hampshire", "NJ": "New Jersey", "NM": "New Mexico", "NY": "New York",
        "NC": "North Carolina", "ND": "North Dakota", "OH": "Ohio", "OK": "Oklahoma",
        "OR": "Oregon", "PA": "Pennsylvania", "RI": "Rhode Island", "SC": "South Carolina",
        "SD": "South Dakota", "TN": "Tennessee", "TX": "Texas", "UT": "Utah",
        "VT": "Vermont", "VA": "Virginia", "WA": "Washington", "WV": "West Virginia",
        "WI": "Wisconsin", "WY": "Wyoming", "DC": "District of Columbia"
    ]

    private func dailyMinTemps(lat: Double, lon: Double, year: Int) async throws -> [(Date, Double)] {
        var comps = URLComponents(string: "https://archive-api.open-meteo.com/v1/archive")!
        comps.queryItems = [
            .init(name: "latitude", value: String(lat)),
            .init(name: "longitude", value: String(lon)),
            .init(name: "start_date", value: String(format: "%04d-01-01", year)),
            .init(name: "end_date", value: String(format: "%04d-12-31", year)),
            .init(name: "daily", value: "temperature_2m_min"),
            .init(name: "temperature_unit", value: "fahrenheit"),
            .init(name: "timezone", value: "auto")
        ]
        struct Response: Codable {
            struct Daily: Codable {
                let time: [String]
                let temperature_2m_min: [Double?]
            }
            let daily: Daily
        }
        let (data, _) = try await session.data(from: comps.url!)
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        var pairs: [(Date, Double)] = []
        for (idx, stamp) in decoded.daily.time.enumerated() {
            guard let date = formatter.date(from: stamp),
                  idx < decoded.daily.temperature_2m_min.count,
                  let min = decoded.daily.temperature_2m_min[idx] else { continue }
            pairs.append((date, min))
        }
        return pairs
    }

    /// Last spring frost = last day with min ≤ 32°F before July 1; first fall = first after July 1.
    static func frostAnchors(dailyMins: [(Date, Double)], year: Int) -> (Date?, Date?) {
        let cal = Calendar(identifier: .gregorian)
        guard let july = cal.date(from: DateComponents(year: year, month: 7, day: 1)) else {
            return (nil, nil)
        }
        let spring = dailyMins.filter { $0.0 < july && $0.1 <= 32 }
        let fall = dailyMins.filter { $0.0 >= july && $0.1 <= 32 }
        return (spring.last?.0, fall.first?.0)
    }

    static func mapDayOfYear(_ source: Date?, onto now: Date, calendar: Calendar = .current) -> Date? {
        guard let source else { return nil }
        let y = calendar.component(.year, from: now)
        let m = calendar.component(.month, from: source)
        let d = calendar.component(.day, from: source)
        return calendar.date(from: DateComponents(year: y, month: m, day: d))
    }
}
