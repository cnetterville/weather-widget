//
//  RadarEntryTests.swift
//  Weather WidgetTests
//

import Foundation
import Testing

extension RadarEntry {
    static func sample(
        date: Date = Date(timeIntervalSinceReferenceDate: 800_000_000),
        radarAge: TimeInterval? = 5 * 60,
        hourlyRain: [Int] = [],
        hourlyRainStart: Date? = nil,
        isFromCache: Bool = false
    ) -> RadarEntry {
        RadarEntry(
            date: date,
            locationName: "Houston, TX",
            image: nil,
            radarTime: radarAge.map { date.addingTimeInterval(-$0) },
            rainChance: nil,
            hourlyRain: hourlyRain,
            hourlyRainStart: hourlyRainStart,
            tropicalWindArrival: nil,
            warningTitle: nil,
            warningCode: nil,
            warningExpires: nil,
            warningCoversLocation: false,
            isFromCache: isFromCache,
            errorMessage: nil
        )
    }
}

struct RadarEntryFreshnessTests {
    @Test func recentRadarIsCurrent() {
        #expect(RadarEntry.sample(radarAge: 5 * 60).freshness == .current)
        #expect(RadarEntry.sample(radarAge: nil).freshness == .current)
    }

    @Test func radarPastTheLimitIsOld() {
        #expect(RadarEntry.sample(radarAge: RadarEntry.staleAfter).freshness == .old)
    }

    @Test func cachedFallbackIsNotUpdatedEvenWhenRecent() {
        #expect(RadarEntry.sample(radarAge: 60, isFromCache: true).freshness == .notUpdated)
    }
}

struct RainSoonTests {
    @Test func noSummaryBelowTenPercent() {
        #expect(RadarEntry.sample(hourlyRain: [0, 5, 9, 0, 0, 0]).rainSoon == nil)
        #expect(RadarEntry.sample(hourlyRain: []).rainSoon == nil)
    }

    @Test func wordsByChance() {
        #expect(RadarEntry.sample(hourlyRain: [70]).rainSoon?.summary == "Rain likely now (70%)")
        #expect(RadarEntry.sample(hourlyRain: [40]).rainSoon?.summary == "Rain possible now (40%)")
        #expect(RadarEntry.sample(hourlyRain: [20]).rainSoon?.summary == "Slight chance of rain now (20%)")
    }

    @Test func peakHourAsClockTime() throws {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let entry = RadarEntry.sample(hourlyRain: [10, 30, 60, 70, 40, 20], hourlyRainStart: start)
        let soon = try #require(entry.rainSoon)
        let peakHour = start.addingTimeInterval(3 * 3600).formatted(.dateTime.hour())
        #expect(soon.summary == "Rain likely ~\(peakHour) (70%)")
        #expect(soon.chance == 70)
    }

    @Test func earliestPeakWinsAndLaterHoursAreIgnored() {
        // The 90% in hour 7 is beyond the strip.
        let entry = RadarEntry.sample(hourlyRain: [10, 50, 20, 50, 0, 0, 90])
        #expect(entry.rainSoon?.summary == "Rain likely in 1 hr (50%)")
    }
}
