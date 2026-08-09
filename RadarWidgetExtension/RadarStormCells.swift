//
//  RadarStormCells.swift
//  RadarWidgetExtension
//

import CoreLocation
import Foundation

/// A storm cell tracked by a NEXRAD radar's storm identification algorithm,
/// with the motion vector the radar derived from successive scans.
struct StormCell {
    let coordinate: CLLocationCoordinate2D
    /// Direction the cell is moving FROM, meteorological degrees.
    let fromDirectionDegrees: Double
    let speedKnots: Double
    let maxDBZ: Int
}

enum StormCellFeed {
    private struct FeatureCollection: Decodable {
        struct Feature: Decodable {
            struct Properties: Decodable {
                let drct: Int?
                let sknt: Int?
                let max_dbz: Int?
            }
            struct Geometry: Decodable {
                let coordinates: [Double]
            }
            let properties: Properties
            let geometry: Geometry?
        }
        let features: [Feature]
    }

    /// Nationwide tracked storm cells that are actually moving. Returns an
    /// empty array on any failure — arrows are an enhancement, never a
    /// reason to fail the render.
    static func activeCells() async -> [StormCell] {
        guard let url = URL(string: "https://mesonet.agron.iastate.edu/geojson/nexrad_attr.geojson"),
              let (data, _) = try? await RadarNetwork.session.data(from: url),
              let collection = try? JSONDecoder().decode(FeatureCollection.self, from: data)
        else {
            return []
        }
        return collection.features.compactMap { feature in
            guard let geometry = feature.geometry,
                  geometry.coordinates.count >= 2,
                  let direction = feature.properties.drct,
                  let speed = feature.properties.sknt,
                  speed >= 5  // skip stationary cells; no meaningful arrow
            else {
                return nil
            }
            return StormCell(
                coordinate: CLLocationCoordinate2D(
                    latitude: geometry.coordinates[1],
                    longitude: geometry.coordinates[0]
                ),
                fromDirectionDegrees: Double(direction),
                speedKnots: Double(speed),
                maxDBZ: feature.properties.max_dbz ?? 0
            )
        }
    }
}
