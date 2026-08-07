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
    let warningTitle: String?
    let warningCode: String?
    let errorMessage: String?

    static func placeholder() -> RadarEntry {
        RadarEntry(
            date: .now,
            locationName: "Weather Radar",
            image: nil,
            radarTime: nil,
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
                // Render at 2x the widget's point size so the map stays sharp.
                size: CGSize(width: context.displaySize.width * 2, height: context.displaySize.height * 2)
            )
            let result = try await renderer.render()
            RadarEntryCache.save(
                image: result.image,
                metadata: RadarEntryCache.Metadata(
                    savedAt: .now,
                    radarTime: result.radarTime,
                    locationName: place.name,
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

    private func reverseGeocodedName(for location: CLLocation) async -> String? {
        guard let request = MKReverseGeocodingRequest(location: location) else { return nil }
        let mapItems = try? await request.mapItems
        return mapItems?.first?.addressRepresentations?.cityWithContext(.automatic)
    }

    private func geocode(_ query: String) async throws -> (coordinate: CLLocationCoordinate2D, name: String) {
        guard let request = MKGeocodingRequest(addressString: query) else {
            throw RadarRenderError.emptyLocation
        }
        let mapItems = try await request.mapItems
        guard let item = mapItems.first else {
            throw RadarRenderError.locationNotFound
        }
        let name = item.addressRepresentations?.cityWithContext(.automatic) ?? item.name ?? query
        return (item.location.coordinate, name)
    }
}
