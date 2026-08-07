//
//  RadarForecast.swift
//  RadarWidgetExtension
//

import CoreLocation
import Foundation

/// Fetches today's precipitation probability from Open-Meteo (free, no key).
enum RainForecast {
    private struct Response: Decodable {
        struct Daily: Decodable {
            let precipitation_probability_max: [Int?]
        }
        let daily: Daily
    }

    /// The maximum chance of precipitation for today at the coordinate, as a
    /// percentage, or nil if unavailable. Never throws — the forecast is an
    /// enhancement, not a requirement.
    static func chanceOfRainToday(at coordinate: CLLocationCoordinate2D) async -> Int? {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.4f", coordinate.latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.4f", coordinate.longitude)),
            URLQueryItem(name: "daily", value: "precipitation_probability_max"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "1"),
        ]
        guard let url = components.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let response = try? JSONDecoder().decode(Response.self, from: data)
        else {
            return nil
        }
        return response.daily.precipitation_probability_max.first ?? nil
    }
}
