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
    let warningTitle: String?
    let warningCode: String?
    let errorMessage: String?

    static func placeholder() -> RadarEntry {
        RadarEntry(
            date: .now,
            locationName: "Weather Radar",
            image: nil,
            radarTime: nil,
            rainChance: nil,
            warningTitle: nil,
            warningCode: nil,
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
                // Render at 2x the widget's point size so the map stays sharp.
                size: CGSize(width: context.displaySize.width * 2, height: context.displaySize.height * 2)
            )
            async let rainChanceTask = RainForecast.chanceOfRainToday(at: place.coordinate)
            let result = try await renderer.render()
            let rainChance = await rainChanceTask
            RadarEntryCache.save(
                image: result.image,
                metadata: RadarEntryCache.Metadata(
                    savedAt: .now,
                    radarTime: result.radarTime,
                    locationName: place.name,
                    rainChance: rainChance,
                    warningTitle: result.topWarning?.eventName,
                    warningCode: result.topWarning?.phenomena
                ),
                key: cacheKey
            )
            return RadarEntry(
                date: .now,
                locationName: place.name,
                image: result.image,
                radarTime: result.radarTime,
                rainChance: rainChance,
                warningTitle: result.topWarning?.eventName,
                warningCode: result.topWarning?.phenomena,
                errorMessage: nil
            )
        } catch {
            // Fall back to the last successful render before showing an error.
            if let cached = RadarEntryCache.load(key: cacheKey) {
                return RadarEntry(
                    date: .now,
                    locationName: cached.metadata.locationName,
                    image: cached.image,
                    radarTime: cached.metadata.radarTime,
                    rainChance: cached.metadata.rainChance,
                    warningTitle: cached.metadata.warningTitle,
                    warningCode: cached.metadata.warningCode,
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
            message = "Location unavailable. Open Weather Widget, allow location access, and approve widget access when adding the widget."
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
            warningTitle: nil,
            warningCode: nil,
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
        guard let location = await Self.currentLocation() else {
            throw RadarRenderError.currentLocationUnavailable
        }
        let name = await reverseGeocodedName(for: location) ?? "Current Location"
        return (location.coordinate, name)
    }

    /// The system's cached location, available while the widget is considered
    /// "in use" and the person has extended location access to widgets.
    @MainActor
    private static func currentLocation() -> CLLocation? {
        let manager = CLLocationManager()
        guard manager.isAuthorizedForWidgetUpdates else { return nil }
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
