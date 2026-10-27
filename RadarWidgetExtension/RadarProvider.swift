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
    let date: Date
    let locationName: String
    let image: NSImage?
    let radarTime: Date?
    let rainChance: Int?
    let hourlyRain: [Int]
    let tropicalWindArrival: String?
    let warningTitle: String?
    let warningCode: String?
    let warningExpires: Date?
    /// Whether the badged warning covers this location, not just the map.
    let warningCoversLocation: Bool
    let errorMessage: String?

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
        // IEM regenerates the NEXRAD composite roughly every 5 minutes.
        let refreshDate = entry.date.addingTimeInterval(5 * 60)
        return Timeline(entries: [entry], policy: .after(refreshDate))
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
                    tropicalWindArrival: cached.metadata.tropicalWindArrival,
                    warningTitle: warningActive ? cached.metadata.warningTitle : nil,
                    warningCode: warningActive ? cached.metadata.warningCode : nil,
                    warningExpires: warningActive ? expires : nil,
                    warningCoversLocation: warningActive && cached.metadata.warningCoversLocation == true,
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

    // Geocoding results are cached permanently: places don't move, and
    // Apple throttles apps that re-geocode the same string repeatedly —
    // which a widget refreshing every few minutes would otherwise do.

    private func reverseGeocodedName(for location: CLLocation) async -> String? {
        let cacheKey = String(
            format: "reverse-geocode:%.2f,%.2f",
            location.coordinate.latitude,
            location.coordinate.longitude
        )
        if let cached = UserDefaults.standard.string(forKey: cacheKey) {
            return cached
        }
        guard let request = MKReverseGeocodingRequest(location: location),
              let mapItems = try? await request.mapItems,
              let name = mapItems.first?.addressRepresentations?.cityWithContext(.automatic)
        else {
            return nil
        }
        UserDefaults.standard.set(name, forKey: cacheKey)
        return name
    }

    private func geocode(_ query: String) async throws -> (coordinate: CLLocationCoordinate2D, name: String) {
        let cacheKey = "geocode:" + query.lowercased()
        if let cached = UserDefaults.standard.dictionary(forKey: cacheKey),
           let latitude = cached["latitude"] as? Double,
           let longitude = cached["longitude"] as? Double,
           let name = cached["name"] as? String {
            return (CLLocationCoordinate2D(latitude: latitude, longitude: longitude), name)
        }
        guard let request = MKGeocodingRequest(addressString: query) else {
            throw RadarRenderError.emptyLocation
        }
        let mapItems = try await request.mapItems
        guard let item = mapItems.first else {
            throw RadarRenderError.locationNotFound
        }
        let coordinate = item.location.coordinate
        let name = item.addressRepresentations?.cityWithContext(.automatic) ?? item.name ?? query
        UserDefaults.standard.set(
            ["latitude": coordinate.latitude, "longitude": coordinate.longitude, "name": name],
            forKey: cacheKey
        )
        return (coordinate, name)
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
