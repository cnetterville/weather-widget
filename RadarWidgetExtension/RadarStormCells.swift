//
//  RadarStormCells.swift
//  RadarWidgetExtension
//

import CoreLocation
import Foundation

/// A storm cell tracked by a NEXRAD radar's storm identification algorithm,
/// with the motion vector and hazard signatures the radar derived from
/// successive scans.
struct StormCell {
    let coordinate: CLLocationCoordinate2D
    /// Direction the cell is moving FROM, meteorological degrees.
    let fromDirectionDegrees: Double
    let speedKnots: Double
    let maxDBZ: Int
    /// Tornado vortex signature detected by the radar.
    let hasTornadoSignature: Bool
    /// Mesocyclone (rotation) detected by the radar.
    let hasMesocyclone: Bool
    /// Probability of severe (1"+) hail, percent.
    let probabilityOfSevereHail: Int
    /// Radar-estimated maximum hail size, inches.
    let maxHailSizeInches: Double

    var isMoving: Bool { speedKnots >= 5 }
    var hasHailIndicator: Bool { probabilityOfSevereHail >= 50 || maxHailSizeInches >= 0.75 }
    var isFlagged: Bool { hasTornadoSignature || hasMesocyclone || hasHailIndicator }
}

enum StormCellFeed {
    private struct FeatureCollection: Decodable {
        struct Feature: Decodable {
            struct Properties: Decodable {
                let drct: Int?
                let sknt: Int?
                let max_dbz: Int?
                let tvs: String?
                let meso: String?
                let posh: Int?
                let max_size: Double?
            }
            struct Geometry: Decodable {
                let coordinates: [Double]
            }
            let properties: Properties
            let geometry: Geometry?
        }
        let features: [Feature]
    }

    /// Nationwide tracked storm cells that are moving or carry a hazard
    /// signature. Returns an empty array on any failure — cell markers are
    /// an enhancement, never a reason to fail the render.
    static func activeCells() async -> [StormCell] {
        guard let url = URL(string: "https://mesonet.agron.iastate.edu/geojson/nexrad_attr.geojson"),
              let (data, _) = try? await RadarNetwork.session.data(from: url),
              let collection = try? JSONDecoder().decode(FeatureCollection.self, from: data)
        else {
            return []
        }
        return collection.features.compactMap { feature in
            guard let geometry = feature.geometry, geometry.coordinates.count >= 2 else {
                return nil
            }
            let properties = feature.properties
            let meso = properties.meso ?? "NONE"
            let cell = StormCell(
                coordinate: CLLocationCoordinate2D(
                    latitude: geometry.coordinates[1],
                    longitude: geometry.coordinates[0]
                ),
                fromDirectionDegrees: Double(properties.drct ?? 0),
                speedKnots: Double(properties.sknt ?? 0),
                maxDBZ: properties.max_dbz ?? 0,
                hasTornadoSignature: (properties.tvs ?? "NONE") != "NONE",
                hasMesocyclone: meso != "NONE" && meso != "UNKN",
                probabilityOfSevereHail: properties.posh ?? 0,
                maxHailSizeInches: properties.max_size ?? 0
            )
            // Stationary, unremarkable cells get no marker at all.
            return (cell.isMoving || cell.isFlagged) ? cell : nil
        }
    }
}
