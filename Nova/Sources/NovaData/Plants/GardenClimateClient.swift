import Foundation
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
            throw NovaError.tool("City not found: \(trimmed)")
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
        var comps = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        comps.queryItems = [
            .init(name: "name", value: city),
            .init(name: "count", value: "1")
        ]
        struct Response: Decodable {
            struct Result: Decodable {
                let name: String
                let latitude: Double
                let longitude: Double
                let admin1: String?
                let country: String?
            }
            let results: [Result]?
        }
        let (data, _) = try await session.data(from: comps.url!)
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        guard let first = decoded.results?.first else { return nil }
        let label = [first.name, first.admin1, first.country].compactMap { $0 }.joined(separator: ", ")
        return Geo(name: label.isEmpty ? first.name : label, lat: first.latitude, lon: first.longitude)
    }

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
        struct Response: Decodable {
            struct Daily: Decodable {
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
