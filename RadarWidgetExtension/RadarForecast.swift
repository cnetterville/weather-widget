//
//  RadarForecast.swift
//  RadarWidgetExtension
//

import CoreLocation
import Foundation

/// Today's rain outlook: the day's peak chance plus the next few hours, so the
/// widget can answer both "will it rain today" and "is it about to rain."
struct RainOutlook {
    /// Maximum chance of precipitation for today, percent.
    let todayMax: Int?
    /// Hourly chance of precipitation starting this hour, percent.
    let next6Hours: [Int]
}

/// Fetches precipitation probability from Open-Meteo (free, no key).
enum RainForecast {
    private struct Response: Decodable {
        struct Daily: Decodable {
            let precipitation_probability_max: [Int?]
        }
        struct Hourly: Decodable {
            let precipitation_probability: [Int?]
        }
        let daily: Daily
        let hourly: Hourly
    }

    /// Today's rain outlook at the coordinate, or an empty outlook if
    /// unavailable. Never throws — the forecast is an enhancement, not a
    /// requirement.
    static func outlook(at coordinate: CLLocationCoordinate2D) async -> RainOutlook {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.4f", coordinate.latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.4f", coordinate.longitude)),
            URLQueryItem(name: "daily", value: "precipitation_probability_max"),
            URLQueryItem(name: "hourly", value: "precipitation_probability"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "1"),
            URLQueryItem(name: "forecast_hours", value: "6"),
        ]
        guard let url = components.url,
              let (data, _) = try? await RadarNetwork.session.data(from: url),
              let response = try? JSONDecoder().decode(Response.self, from: data)
        else {
            return RainOutlook(todayMax: nil, next6Hours: [])
        }
        return RainOutlook(
            todayMax: response.daily.precipitation_probability_max.first ?? nil,
            next6Hours: response.hourly.precipitation_probability.compactMap { $0 }
        )
    }
}
