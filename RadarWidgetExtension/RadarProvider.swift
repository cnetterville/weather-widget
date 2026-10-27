//
//  RadarProvider.swift
//  RadarWidgetExtension
//

import AppKit
import CoreLocation
import Foundation
import MapKit
import WidgetKit

struct RadarEntry: TimelineEntry {
    var date: Date
    let locationName: String
    let image: NSImage?
    let radarTime: Date?
    let rainChance: Int?
    let hourlyRain: [Int]
    /// When the first of `hourlyRain` begins.
    var hourlyRainStart: Date?
    let tropicalWindArrival: String?
    let warningTitle: String?
    let warningCode: String?
    let warningExpires: Date?
    /// Whether the badged warning covers this location, not just the map.
    let warningCoversLocation: Bool
    /// Whether this is the last successful render, shown because a fresh
    /// one failed.
    var isFromCache = false
    let errorMessage: String?

    /// Radar older than this is flagged in the caption. RainViewer frames
    /// are 10 minutes apart and land a few minutes late, so a tighter limit
    /// would flag normal worldwide radar.
    static let staleAfter: TimeInterval = 20 * 60

    enum Freshness {
        case current
        /// The radar frame is older than `staleAfter`.
        case old
        /// A refresh failed and this is the previous render.
        case notUpdated
    }

    var freshness: Freshness {
        if isFromCache {
            return .notUpdated
        }
        if let radarTime, date.timeIntervalSince(radarTime) >= Self.staleAfter {
            return .old
        }
        return .current
    }

    static func placeholder() -> RadarEntry {
        RadarEntry(
            date: .now,
            locationName: "Weather Radar",
            image: nil,
            radarTime: nil,
            rainChance: nil,
            hourlyRain: [],
            tropicalWindArrival: nil,
            warningTitle: nil,
            warningCode: nil,
            warningExpires: nil,
            warningCoversLocation: false,
            errorMessage: nil
        )
    }
}

struct RadarProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> RadarEntry {
        .placeholder()
    }

    func snapshot(for configuration: RadarConfigurationIntent, in context: Context) async -> RadarEntry {
        // The widget gallery needs a fast snapshot; skip the network work there.
        if context.isPreview {
            return .placeholder()
        }
        return await makeEntry(for: configuration, in: context)
    }

    func timeline(for configuration: RadarConfigurationIntent, in context: Context) async -> Timeline<RadarEntry> {
        let entry = await makeEntry(for: configuration, in: context)
        var entries = [entry]
        // WidgetKit budgets reloads and may hold off the next one, leaving
        // this radar on screen as it ages. A second entry flags it as old at
        // the point it becomes so, without needing a reload.
        if entry.freshness == .current, let radarTime = entry.radarTime {
            var aged = entry
            aged.date = radarTime.addingTimeInterval(RadarEntry.staleAfter)
            if aged.date > entry.date {
                entries.append(aged)
            }
        }
        // IEM regenerates the NEXRAD composite roughly every 5 minutes.
        let refreshDate = entry.date.addingTimeInterval(5 * 60)
        return Timeline(entries: entries, policy: .after(refreshDate))
    }

    private func makeEntry(for configuration: RadarConfigurationIntent, in context: Context) async -> RadarEntry {
        let query = configuration.location.trimmingCharacters(in: .whitespacesAndNewlines)
        let cacheKey = RadarEntryCache.key(for: configuration, displaySize: context.displaySize)
        do {
            let place = try await resolvePlace(for: configuration, query: query)
            let renderer = RadarMapRenderer(
                coordinate: place.coordinate,
                latitudeSpan: configuration.zoom.latitudeSpan,
                mapStyle: configuration.mapStyle,
                radarSource: configuration.radarSource,
                showsClouds: configuration.showsCloudCover,
                displaySize: context.displaySize,
                // Render at 2x the widget's point size so the map stays sharp.
                scale: 2
            )
            async let outlookTask = RainForecast.outlook(at: place.coordinate)
            let result = try await renderer.render()
            let outlook = await outlookTask
            RadarEntryCache.save(
                image: result.image,
                metadata: RadarEntryCache.Metadata(
                    savedAt: .now,
                    radarTime: result.radarTime,
                    locationName: place.name,
                    rainChance: outlook.restOfTodayMax,
                    hourlyRain: outlook.next6Hours,
                    hourlyRainStart: outlook.next6HoursStart,
                    tropicalWindArrival: result.tropicalWindArrival,
                    warningTitle: result.topWarning?.eventName,
                    warningCode: result.topWarning?.phenomena,
                    warningExpires: result.topWarning?.expires,
                    warningCoversLocation: result.warningCoversLocation
                ),
                key: cacheKey
            )
            return RadarEntry(
                date: .now,
                locationName: place.name,
                image: result.image,
                radarTime: result.radarTime,
                rainChance: outlook.restOfTodayMax,
                hourlyRain: outlook.next6Hours,
                hourlyRainStart: outlook.next6HoursStart,
                tropicalWindArrival: result.tropicalWindArrival,
                warningTitle: result.topWarning?.eventName,
                warningCode: result.topWarning?.phenomena,
                warningExpires: result.topWarning?.expires,
                warningCoversLocation: result.warningCoversLocation,
                errorMessage: nil
            )
        } catch {
            // Fall back to the last successful render before showing an error.
            if let cached = RadarEntryCache.load(key: cacheKey) {
                // A warning that has since expired shouldn't outlive it on
                // the stale image's badge.
                let expires = cached.metadata.warningExpires
                let warningActive = expires.map { $0 > .now } ?? true
                return RadarEntry(
                    date: .now,
                    locationName: cached.metadata.locationName,
                    image: cached.image,
                    radarTime: cached.metadata.radarTime,
                    rainChance: cached.metadata.rainChance,
                    hourlyRain: cached.metadata.hourlyRain ?? [],
                    hourlyRainStart: cached.metadata.hourlyRainStart,
                    tropicalWindArrival: cached.metadata.tropicalWindArrival,
                    warningTitle: warningActive ? cached.metadata.warningTitle : nil,
                    warningCode: warningActive ? cached.metadata.warningCode : nil,
                    warningExpires: warningActive ? expires : nil,
                    warningCoversLocation: warningActive && cached.metadata.warningCoversLocation == true,
                    isFromCache: true,
                    errorMessage: nil
                )
            }
            return errorEntry(for: error, query: query)
        }
    }

    private func errorEntry(for error: Error, query: String) -> RadarEntry {
        let locationName: String
        let message: String
        if case RadarRenderError.currentLocationUnavailable = error {
            locationName = "Current Location"
            message = "Location unavailable. Open the Weather Radar app, allow location access, and approve widget access when adding the widget."
        } else {
            locationName = query
            message = query.isEmpty
                ? "Edit the widget to choose a location."
                : "Couldn’t load radar for “\(query)”."
        }
        return RadarEntry(
            date: .now,
            locationName: locationName,
            image: nil,
            radarTime: nil,
            rainChance: nil,
            hourlyRain: [],
            tropicalWindArrival: nil,
            warningTitle: nil,
            warningCode: nil,
            warningExpires: nil,
            warningCoversLocation: false,
            errorMessage: message
        )
    }

    private func resolvePlace(
        for configuration: RadarConfigurationIntent,
        query: String
    ) async throws -> (coordinate: CLLocationCoordinate2D, name: String) {
        guard configuration.useCurrentLocation else {
            return try await geocode(query)
        }
        if let location = await Self.currentLocation() {
            let name = await reverseGeocodedName(for: location) ?? "Current Location"
            return (location.coordinate, name)
        }
        // Location access can lapse (for example when the app bundle moves).
        // Only fall back to the typed location if the person actually chose
        // one — otherwise it's still sitting on the intent's placeholder
        // ("New York, NY"), and silently rendering that would look exactly
        // like "Use My Current Location" is being ignored rather than
        // failing, which is much harder to diagnose.
        if query != RadarConfigurationIntent.defaultLocation, !query.isEmpty,
           let fallback = try? await geocode(query) {
            return fallback
        }
        throw RadarRenderError.currentLocationUnavailable
    }

    /// Asks Core Location for a fix while the widget is considered "in use"
    /// (shortly after it's visible, and only once the person has extended
    /// the app's location access to widgets).
    ///
    /// Merely reading `manager.location` isn't enough: a widget runs in a
    /// fresh extension process most of the time, and the cached value there
    /// is usually `nil` until something actually requests a location. It's
    /// still worth checking afterwards as a fallback, since the request may
    /// have populated it even if the fresh fix didn't arrive within budget.
    @MainActor
    private static func currentLocation() async -> CLLocation? {
        let manager = CLLocationManager()
        guard manager.isAuthorizedForWidgetUpdates else { return nil }
        let request = OneShotLocationRequest(manager: manager)
        if let fresh = await request.location(timeout: .seconds(8)) {
            return fresh
        }
        return manager.location
    }

    // Geocoding results are cached for a while (see GeocodeCache): Apple
    // throttles apps that re-geocode the same string repeatedly, which a
    // widget refreshing every few minutes would otherwise do.

    private func reverseGeocodedName(for location: CLLocation) async -> String? {
        let cache = GeocodeCache()
        if let cached = cache.name(near: location.coordinate) {
            return cached
        }
        guard let request = MKReverseGeocodingRequest(location: location),
              let mapItems = try? await request.mapItems,
              let name = mapItems.first?.addressRepresentations?.cityWithContext(.automatic)
        else {
            return nil
        }
        cache.saveName(name, near: location.coordinate)
        return name
    }

    private func geocode(_ query: String) async throws -> (coordinate: CLLocationCoordinate2D, name: String) {
        let cache = GeocodeCache()
        if let cached = cache.place(named: query), let coordinate = cached.coordinate {
            return (coordinate, cached.name)
        }
        guard let request = MKGeocodingRequest(addressString: query) else {
            throw RadarRenderError.emptyLocation
        }
        do {
            let mapItems = try await request.mapItems
            guard let item = mapItems.first else {
                throw RadarRenderError.locationNotFound
            }
            let coordinate = item.location.coordinate
            let name = item.addressRepresentations?.cityWithContext(.automatic) ?? item.name ?? query
            cache.savePlace(named: query, name: name, coordinate: coordinate)
            return (coordinate, name)
        } catch {
            // Offline or throttled once the cached match expired: keep using
            // it until a lookup succeeds rather than lose the radar.
            if let stale = cache.place(named: query, includingExpired: true), let coordinate = stale.coordinate {
                return (coordinate, stale.name)
            }
            throw error
        }
    }
}

/// Wraps `CLLocationManager.requestLocation()` in a single awaitable call.
/// A widget timeline has to return something within WidgetKit's budget, so
/// the wait is capped; whichever of "fix arrived", "failed", or "timed out"
/// happens first resumes the caller exactly once.
@MainActor
private final class OneShotLocationRequest: NSObject, CLLocationManagerDelegate {
    private let manager: CLLocationManager
    private var continuation: CheckedContinuation<CLLocation?, Never>?

    init(manager: CLLocationManager) {
        self.manager = manager
        super.init()
        // A radar map spans tens of kilometres; a coarse fix is plenty and
        // arrives much faster than a precise one.
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        manager.delegate = self
    }

    func location(timeout: Duration) async -> CLLocation? {
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            self?.finish(with: nil)
        }
        defer { timeoutTask.cancel() }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            manager.requestLocation()
        }
    }

    private func finish(with location: CLLocation?) {
        guard let continuation else { return }
        self.continuation = nil
        manager.stopUpdatingLocation()
        continuation.resume(returning: location)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        finish(with: locations.last)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(with: nil)
    }
}
