//
//  FeedParsingTests.swift
//  Weather WidgetTests
//

import CoreLocation
import Foundation
import Testing

struct StormWarningFeedTests {
    let json = """
    {"type": "FeatureCollection", "features": [
      {"properties": {"phenomena": "TO", "significance": "W", "expire": "2026-10-27T19:45:00Z"},
       "geometry": {"type": "Polygon", "coordinates": [[[-95, 29], [-94, 29], [-94, 30], [-95, 29]]]}},
      {"properties": {"phenomena": "FL", "significance": "W", "expire": null},
       "geometry": {"type": "MultiPolygon", "coordinates": [
         [[[-90, 30], [-89, 30], [-89, 31], [-90, 30]]],
         [[[-88, 30], [-87, 30], [-87, 31], [-88, 30]]]]}},
      {"properties": {"phenomena": "SV", "significance": "Y"},
       "geometry": {"type": "Polygon", "coordinates": [[[-95, 29], [-94, 29], [-94, 30], [-95, 29]]]}},
      {"properties": {"phenomena": "WS", "significance": "W"},
       "geometry": {"type": "Polygon", "coordinates": [[[-95, 29], [-94, 29], [-94, 30], [-95, 29]]]}},
      {"properties": {"phenomena": "SV", "significance": "W"}, "geometry": null}
    ]}
    """

    @Test func keepsOnlyBadgedWarningsWithGeometry() {
        let warnings = StormWarningFeed.warnings(from: Data(json.utf8))
        #expect(warnings.map(\.phenomena) == ["TO", "FL"])
    }

    @Test func parsesExpiryAndFlattensMultiPolygons() throws {
        let warnings = StormWarningFeed.warnings(from: Data(json.utf8))
        let tornado = try #require(warnings.first)
        #expect(tornado.expires == (try Date("2026-10-27T19:45:00Z", strategy: .iso8601)))
        // GeoJSON is longitude-first.
        #expect(tornado.rings[0][0].latitude == 29 && tornado.rings[0][0].longitude == -95)
        let flood = try #require(warnings.last)
        #expect(flood.expires == nil)
        #expect(flood.rings.count == 2)
    }

    @Test func badDataIsEmptyNotACrash() {
        #expect(StormWarningFeed.warnings(from: Data("not json".utf8)).isEmpty)
    }
}

struct RainForecastTests {
    /// Open-Meteo's shape: local wall-clock times starting at the current
    /// hour, plus the location's UTC offset (Houston, CDT).
    let json = """
    {"utc_offset_seconds": -18000,
     "hourly": {
       "time": ["2026-10-27T22:00", "2026-10-27T23:00", "2026-10-28T00:00",
                "2026-10-28T01:00", "2026-10-28T02:00", "2026-10-28T03:00", "2026-10-28T04:00"],
       "precipitation_probability": [10, null, 40, 80, 20, 5, 90]}}
    """

    @Test func restOfTodayStopsAtLocalMidnight() throws {
        let outlook = try #require(RainForecast.outlook(from: Data(json.utf8)))
        // Only 10 PM and 11 PM are still today; tomorrow's 80% doesn't count.
        #expect(outlook.restOfTodayMax == 10)
    }

    @Test func nextHoursKeepTheirPositions() throws {
        let outlook = try #require(RainForecast.outlook(from: Data(json.utf8)))
        // The missing 11 PM value is 0%, not dropped, so later hours stay aligned.
        #expect(outlook.next6Hours == [10, 0, 40, 80, 20, 5])
    }

    @Test func firstHourStartsAtItsUTCInstant() throws {
        let outlook = try #require(RainForecast.outlook(from: Data(json.utf8)))
        // 10 PM CDT is 03:00 UTC the next day.
        #expect(outlook.next6HoursStart == (try Date("2026-10-28T03:00:00Z", strategy: .iso8601)))
    }

    @Test func badDataIsNil() {
        #expect(RainForecast.outlook(from: Data("{}".utf8)) == nil)
    }
}
