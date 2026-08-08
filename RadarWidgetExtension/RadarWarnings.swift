//
//  RadarWarnings.swift
//  RadarWidgetExtension
//

import AppKit
import CoreLocation
import Foundation

/// An active NWS storm-based warning polygon, from the Iowa Environmental
/// Mesonet's nationwide feed.
struct StormWarning {
    /// NWS phenomena code: TO (tornado), SV (severe thunderstorm), etc.
    let phenomena: String
    /// Polygon rings as coordinate sequences.
    let rings: [[CLLocationCoordinate2D]]

    /// Draw and badge priority, most dangerous first.
    static let priority = ["TO", "SV", "FF", "MA", "FA", "FL"]

    private static let names: [String: String] = [
        "TO": "Tornado Warning",
        "SV": "Severe Thunderstorm Warning",
        "FF": "Flash Flood Warning",
        "MA": "Special Marine Warning",
        "FA": "Flood Warning",
        "FL": "Flood Warning",
    ]

    private static let colors: [String: NSColor] = [
        "TO": .systemRed,
        "SV": .systemYellow,
        "FF": .systemGreen,
        "MA": .systemPurple,
        "FA": .systemTeal,
        "FL": .systemTeal,
    ]

    var eventName: String { Self.names[phenomena] ?? "Weather Warning" }
    var color: NSColor { Self.colors[phenomena] ?? .systemOrange }

    /// Whether any part of the warning falls inside the given bounds.
    func intersects(
        minLatitude: Double, maxLatitude: Double,
        minLongitude: Double, maxLongitude: Double
    ) -> Bool {
        for ring in rings {
            for coordinate in ring
            where coordinate.latitude >= minLatitude && coordinate.latitude <= maxLatitude
                && coordinate.longitude >= minLongitude && coordinate.longitude <= maxLongitude {
                return true
            }
        }
        return false
    }
}

enum StormWarningFeed {
    private struct FeatureCollection: Decodable {
        struct Feature: Decodable {
            struct Properties: Decodable {
                let phenomena: String?
                let significance: String?
            }
            let properties: Properties
            let geometry: Geometry?
        }
        let features: [Feature]
    }

    /// GeoJSON geometry that flattens Polygon and MultiPolygon into rings.
    private struct Geometry: Decodable {
        let rings: [[CLLocationCoordinate2D]]

        enum CodingKeys: String, CodingKey {
            case type
            case coordinates
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            switch type {
            case "Polygon":
                let raw = try container.decode([[[Double]]].self, forKey: .coordinates)
                rings = Self.convert(raw)
            case "MultiPolygon":
                let raw = try container.decode([[[[Double]]]].self, forKey: .coordinates)
                rings = raw.flatMap(Self.convert)
            default:
                rings = []
            }
        }

        private static func convert(_ polygon: [[[Double]]]) -> [[CLLocationCoordinate2D]] {
            polygon.map { ring in
                ring.compactMap { point in
                    point.count >= 2
                        ? CLLocationCoordinate2D(latitude: point[1], longitude: point[0])
                        : nil
                }
            }
        }
    }

    /// All active storm-based warnings nationwide. Returns an empty array on
    /// any failure — warnings are an enhancement, never a reason to fail the
    /// whole render.
    static func activeWarnings() async -> [StormWarning] {
        guard let url = URL(string: "https://mesonet.agron.iastate.edu/geojson/sbw.geojson"),
              let (data, _) = try? await RadarNetwork.session.data(from: url),
              let collection = try? JSONDecoder().decode(FeatureCollection.self, from: data)
        else {
            return []
        }
        return collection.features.compactMap { feature in
            guard feature.properties.significance == "W",
                  let phenomena = feature.properties.phenomena,
                  StormWarning.priority.contains(phenomena),
                  let geometry = feature.geometry,
                  !geometry.rings.isEmpty
            else {
                return nil
            }
            return StormWarning(phenomena: phenomena, rings: geometry.rings)
        }
    }
}
