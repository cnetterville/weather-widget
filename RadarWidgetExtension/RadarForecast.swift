//
//  RadarForecast.swift
//  RadarWidgetExtension
//

import CoreLocation
import Foundation

/// Today's rain outlook: the peak chance for the rest of the day plus the next
/// few hours, so the widget can answer both "will it rain today" and "is it
/// about to rain."
struct RainOutlook {
    /// Maximum hourly chance of precipitation from now to local midnight,
    /// percent. Hours already past don't count, so a rainy morning doesn't
    /// keep reporting a high chance all evening.
    let restOfTodayMax: Int?
    /// Hourly chance of precipitation starting this hour, percent.
    let next6Hours: [Int]
    /// When the first of `next6Hours` begins.
    let next6HoursStart: Date?
}

/// Fetches precipitation probability from Open-Meteo (free, no key).
enum RainForecast {
    private struct Response: Decodable {
        struct Hourly: Decodable {
            /// Local times like "2026-10-27T15:00", starting with this hour.
            let time: [String]
            let precipitation_probability: [Int?]
        }
        let hourly: Hourly
        let utc_offset_seconds: Int
    }

    /// Today's rain outlook at the coordinate, or an empty outlook if
    /// unavailable. Never throws — the forecast is an enhancement, not a
    /// requirement.
    static func outlook(at coordinate: CLLocationCoordinate2D) async -> RainOutlook {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.4f", coordinate.latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.4f", coordinate.longitude)),
            URLQueryItem(name: "hourly", value: "precipitation_probability"),
            URLQueryItem(name: "timezone", value: "auto"),
            // Starts at the current hour; 24 hours always reaches midnight.
            URLQueryItem(name: "forecast_hours", value: "24"),
        ]
        guard let url = components.url,
              let (data, _) = try? await RadarNetwork.session.data(from: url),
              let response = try? JSONDecoder().decode(Response.self, from: data)
        else {
            return RainOutlook(restOfTodayMax: nil, next6Hours: [], next6HoursStart: nil)
        }
        let hourly = response.hourly
        // Times are local to the location, so "today" is every hour sharing
        // the first hour's date.
        let today = hourly.time.first.map { $0.prefix(10) }
        let restOfToday = zip(hourly.time, hourly.precipitation_probability)
            .filter { time, _ in time.prefix(10) == today }
            .compactMap { _, chance in chance }
        return RainOutlook(
            restOfTodayMax: restOfToday.max(),
            next6Hours: hourly.precipitation_probability.prefix(6).compactMap { $0 },
            next6HoursStart: hourly.time.first.flatMap {
                startDate(localTime: $0, utcOffsetSeconds: response.utc_offset_seconds)
            }
        )
    }

    /// Converts one of the response's local wall-clock times to a Date.
    private static func startDate(localTime: String, utcOffsetSeconds: Int) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return formatter.date(from: localTime)?
            .addingTimeInterval(-TimeInterval(utcOffsetSeconds))
    }
}
