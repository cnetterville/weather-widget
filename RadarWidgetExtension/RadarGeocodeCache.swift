//
//  RadarGeocodeCache.swift
//  RadarWidgetExtension
//

import CoreLocation
import Foundation

/// Remembers geocoding results for a week. Apple throttles apps that
/// geocode the same string repeatedly, which a widget refreshing every few
/// minutes would otherwise do — but a result kept forever means a bad match,
/// or a place Apple has since corrected, never goes away.
struct GeocodeCache {
    struct Entry: Codable, Equatable {
        let name: String
        /// Present for forward geocoding (place name to coordinate); a
        /// reverse lookup only needs the name.
        var latitude: Double?
        var longitude: Double?
        let savedAt: Date

        var coordinate: CLLocationCoordinate2D? {
            guard let latitude, let longitude else { return nil }
            return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
    }

    static let lifetime: TimeInterval = 7 * 24 * 60 * 60

    private static let keyPrefix = "geocode-cache:"
    /// Keys from before entries expired. Their values carry no save date,
    /// so they're cleared rather than trusted.
    private static let legacyKeyPrefixes = ["geocode:", "reverse-geocode:"]

    var defaults: UserDefaults = .standard
    var now: () -> Date = { Date() }

    /// The entry for a typed place name. `includingExpired` is for when a
    /// fresh lookup just failed: an old match beats no radar at all.
    func place(named query: String, includingExpired: Bool = false) -> Entry? {
        entry(forKey: "place:" + query.lowercased(), includingExpired: includingExpired)
    }

    func savePlace(named query: String, name: String, coordinate: CLLocationCoordinate2D) {
        save(
            Entry(name: name, latitude: coordinate.latitude, longitude: coordinate.longitude, savedAt: now()),
            forKey: "place:" + query.lowercased()
        )
    }

    /// The place name for a location, at roughly 1 km granularity.
    func name(near location: CLLocationCoordinate2D) -> String? {
        entry(forKey: Self.nearKey(location))?.name
    }

    func saveName(_ name: String, near location: CLLocationCoordinate2D) {
        save(Entry(name: name, savedAt: now()), forKey: Self.nearKey(location))
    }

    private static func nearKey(_ location: CLLocationCoordinate2D) -> String {
        String(format: "near:%.2f,%.2f", location.latitude, location.longitude)
    }

    private func entry(forKey key: String, includingExpired: Bool = false) -> Entry? {
        guard let data = defaults.data(forKey: Self.keyPrefix + key),
              let entry = try? JSONDecoder().decode(Entry.self, from: data),
              includingExpired || now().timeIntervalSince(entry.savedAt) < Self.lifetime
        else { return nil }
        return entry
    }

    private func save(_ entry: Entry, forKey key: String) {
        guard let data = try? JSONEncoder().encode(entry) else { return }
        defaults.set(data, forKey: Self.keyPrefix + key)
        removeExpired()
    }

    /// Drops expired and legacy entries. Runs only on a save, which a cache
    /// hit skips, so it's rare; without it, following the current location
    /// on a trip would leave an entry behind for every place passed through.
    private func removeExpired() {
        let decoder = JSONDecoder()
        for (key, value) in defaults.dictionaryRepresentation() {
            if Self.legacyKeyPrefixes.contains(where: key.hasPrefix) {
                defaults.removeObject(forKey: key)
            } else if key.hasPrefix(Self.keyPrefix) {
                let entry = (value as? Data).flatMap { try? decoder.decode(Entry.self, from: $0) }
                if let entry, now().timeIntervalSince(entry.savedAt) < Self.lifetime {
                    continue
                }
                defaults.removeObject(forKey: key)
            }
        }
    }
}
