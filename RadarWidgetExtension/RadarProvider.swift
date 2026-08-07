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
    let errorMessage: String?

    static func placeholder() -> RadarEntry {
        RadarEntry(date: .now, locationName: "Weather Radar", image: nil, radarTime: nil, errorMessage: nil)
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
        do {
            let place = try await geocode(query)
            let renderer = RadarMapRenderer(
                coordinate: place.coordinate,
                latitudeSpan: configuration.zoom.latitudeSpan,
                // Render at 2x the widget's point size so the map stays sharp.
                size: CGSize(width: context.displaySize.width * 2, height: context.displaySize.height * 2)
            )
            let (image, radarTime) = try await renderer.render()
            return RadarEntry(
                date: .now,
                locationName: place.name,
                image: image,
                radarTime: radarTime,
                errorMessage: nil
            )
        } catch {
            return RadarEntry(
                date: .now,
                locationName: query,
                image: nil,
                radarTime: nil,
                errorMessage: query.isEmpty
                    ? "Edit the widget to choose a location."
                    : "Couldn’t load radar for “\(query)”."
            )
        }
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
