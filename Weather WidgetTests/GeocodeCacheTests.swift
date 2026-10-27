//
//  GeocodeCacheTests.swift
//  Weather WidgetTests
//

import CoreLocation
import Foundation
import Testing

struct GeocodeCacheTests {
    let defaults: UserDefaults
    let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let houston = CLLocationCoordinate2D(latitude: 29.76, longitude: -95.37)

    init() {
        // A throwaway domain per test, so tests never see each other's data
        // or the real widget's cache.
        let suite = "GeocodeCacheTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
    }

    private func cache(at date: Date) -> GeocodeCache {
        GeocodeCache(defaults: defaults, now: { date })
    }

    @Test func returnsSavedPlaceCaseInsensitively() throws {
        cache(at: start).savePlace(named: "Houston, TX", name: "Houston, TX", coordinate: houston)
        let entry = try #require(cache(at: start.addingTimeInterval(60)).place(named: "houston, tx"))
        #expect(entry.name == "Houston, TX")
        #expect(entry.coordinate?.latitude == houston.latitude)
    }

    @Test func placeExpiresAfterLifetime() {
        cache(at: start).savePlace(named: "Houston, TX", name: "Houston, TX", coordinate: houston)
        let later = cache(at: start.addingTimeInterval(GeocodeCache.lifetime + 1))
        #expect(later.place(named: "Houston, TX") == nil)
        // Still there for when a fresh lookup fails.
        #expect(later.place(named: "Houston, TX", includingExpired: true)?.name == "Houston, TX")
    }

    @Test func nameNearLocationSharesAboutAKilometer() {
        cache(at: start).saveName("Houston, TX", near: houston)
        let nearby = CLLocationCoordinate2D(latitude: 29.762, longitude: -95.368)
        let across = CLLocationCoordinate2D(latitude: 29.80, longitude: -95.37)
        #expect(cache(at: start).name(near: nearby) == "Houston, TX")
        #expect(cache(at: start).name(near: across) == nil)
        #expect(cache(at: start.addingTimeInterval(GeocodeCache.lifetime + 1)).name(near: houston) == nil)
    }

    @Test func savingClearsExpiredAndLegacyEntries() {
        defaults.set(["latitude": 1.0, "longitude": 2.0, "name": "Wrong"], forKey: "geocode:houston, tx")
        defaults.set("Wrong", forKey: "reverse-geocode:29.76,-95.37")
        cache(at: start).saveName("Old Town", near: CLLocationCoordinate2D(latitude: 10, longitude: 10))

        let later = start.addingTimeInterval(GeocodeCache.lifetime + 1)
        cache(at: later).saveName("Houston, TX", near: houston)

        let keys = defaults.dictionaryRepresentation().keys
        #expect(!keys.contains("geocode:houston, tx"))
        #expect(!keys.contains("reverse-geocode:29.76,-95.37"))
        #expect(keys.filter { $0.hasPrefix("geocode-cache:") }.count == 1)
    }
}
