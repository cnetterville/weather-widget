//
//  RadarTropical.swift
//  RadarWidgetExtension
//

import AppKit
import CoreLocation
import Foundation

/// An active tropical cyclone from the National Hurricane Center: its current
/// center plus the official forecast track and error cone.
struct TropicalCyclone {
    let name: String
    /// NHC classification code: HU (hurricane), TS (tropical storm),
    /// TD (depression), PTC/PC (potential), STS/STD (subtropical), etc.
    let classification: String
    /// Maximum sustained wind, knots.
    let intensityKnots: Int
    /// Current center of circulation.
    let center: CLLocationCoordinate2D
    /// Forecast "cone of uncertainty" polygon rings.
    let coneRings: [[CLLocationCoordinate2D]]
    /// Ordered forecast track points (current position forward).
    let track: [CLLocationCoordinate2D]

    /// A short label such as "Cat 3 Hurricane" or "Tropical Storm".
    var summary: String {
        switch classification {
        case "HU", "MH", "TY", "STY", "HR":
            let category: String
            switch intensityKnots {
            case 137...: category = "Cat 5 "
            case 113...136: category = "Cat 4 "
            case 96...112: category = "Cat 3 "
            case 83...95: category = "Cat 2 "
            case 64...82: category = "Cat 1 "
            default: category = ""
            }
            return "\(category)Hurricane"
        case "TS": return "Tropical Storm"
        case "TD": return "Tropical Depression"
        case "STS": return "Subtropical Storm"
        case "STD": return "Subtropical Depression"
        case "PTC", "PC": return "Potential Cyclone"
        default: return "Tropical Cyclone"
        }
    }

    /// Threat-tiered color for the storm marker and label.
    var color: NSColor {
        switch classification {
        case "HU", "MH", "TY", "STY", "HR":
            return intensityKnots >= 96 ? .systemPurple : .systemRed
        case "TS", "STS": return .systemOrange
        default: return .systemYellow
        }
    }

    /// Whether any part of the cone falls inside the given bounds.
    func intersects(
        minLatitude: Double, maxLatitude: Double,
        minLongitude: Double, maxLongitude: Double
    ) -> Bool {
        for ring in coneRings {
            for point in ring
            where point.latitude >= minLatitude && point.latitude <= maxLatitude
                && point.longitude >= minLongitude && point.longitude <= maxLongitude {
                return true
            }
        }
        return false
    }
}

enum TropicalCycloneFeed {
    /// NHC bin numbers map to fixed layers in NOAA's tropical MapServer. The
    /// service has hosted these 15 slots (5 Atlantic, 5 East Pacific, 5 Central
    /// Pacific) for years; if the layout ever drifts, a stale id simply returns
    /// no features and the overlay disappears rather than drawing the wrong storm.
    private static let coneLayer: [String: Int] = [
        "AT1": 8, "AT2": 34, "AT3": 60, "AT4": 86, "AT5": 112,
        "EP1": 138, "EP2": 164, "EP3": 190, "EP4": 216, "EP5": 242,
        "CP1": 268, "CP2": 294, "CP3": 320, "CP4": 346, "CP5": 372,
    ]
    /// The forecast-track layer sits one id below the matching cone layer.
    private static func trackLayer(for bin: String) -> Int? {
        coneLayer[bin].map { $0 - 1 }
    }

    private static let mapServer =
        "https://mapservices.weather.noaa.gov/tropical/rest/services/tropical/NHC_tropical_weather/MapServer"

    private struct StormIndex: Decodable {
        struct Storm: Decodable {
            let name: String?
            let classification: String?
            let intensity: String?
            let latitudeNumeric: Double?
            let longitudeNumeric: Double?
            let binNumber: String?
        }
        let activeStorms: [Storm]?
    }

    /// Active cyclones whose current center is within reach of the shown region.
    /// Only storms plausibly near the map are queried for their cone and track,
    /// so the common case (no nearby storm) costs a single index request.
    /// Returns an empty array on any failure — the overlay is an enhancement.
    static func activeCyclones(
        near center: CLLocationCoordinate2D,
        spanDegrees: Double
    ) async -> [TropicalCyclone] {
        guard let url = URL(string: "https://www.nhc.noaa.gov/CurrentStorms.json"),
              let (data, _) = try? await RadarNetwork.session.data(from: url),
              let index = try? JSONDecoder().decode(StormIndex.self, from: data),
              let storms = index.activeStorms
        else {
            return []
        }

        // A 5-day cone can extend a long way from the present center, so use a
        // generous margin; the renderer clips precisely to the visible region.
        let margin = spanDegrees / 2 + 20

        return await withTaskGroup(of: TropicalCyclone?.self) { group in
            for storm in storms {
                guard let bin = storm.binNumber,
                      let latitude = storm.latitudeNumeric,
                      let longitude = storm.longitudeNumeric,
                      abs(latitude - center.latitude) < margin,
                      abs(longitude - center.longitude) < margin,
                      let coneID = coneLayer[bin]
                else {
                    continue
                }
                group.addTask {
                    async let coneRings = geometry(layer: coneID, name: storm.name)
                    async let track = geometry(layer: trackLayer(for: bin) ?? -1, name: storm.name)
                    let rings = await coneRings
                    guard !rings.isEmpty else { return nil }
                    return TropicalCyclone(
                        name: storm.name ?? "Tropical Cyclone",
                        classification: storm.classification ?? "",
                        intensityKnots: Int(storm.intensity ?? "") ?? 0,
                        center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                        coneRings: rings,
                        track: (await track).first ?? []
                    )
                }
            }
            var results: [TropicalCyclone] = []
            for await cyclone in group where cyclone != nil {
                results.append(cyclone!)
            }
            return results
        }
    }

    // MARK: - ArcGIS GeoJSON parsing

    private struct FeatureCollection: Decodable {
        struct Feature: Decodable {
            let geometry: Geometry?
        }
        let features: [Feature]
    }

    /// Flattens Polygon/MultiPolygon/LineString/MultiLineString into coordinate
    /// rings; a single LineString comes back as one ring.
    private struct Geometry: Decodable {
        let rings: [[CLLocationCoordinate2D]]

        enum CodingKeys: String, CodingKey { case type, coordinates }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(String.self, forKey: .type) {
            case "Polygon":
                let raw = try container.decode([[[Double]]].self, forKey: .coordinates)
                rings = Self.convert(raw)
            case "MultiPolygon":
                let raw = try container.decode([[[[Double]]]].self, forKey: .coordinates)
                rings = raw.flatMap(Self.convert)
            case "LineString":
                let raw = try container.decode([[Double]].self, forKey: .coordinates)
                rings = Self.convert([raw])
            case "MultiLineString":
                let raw = try container.decode([[[Double]]].self, forKey: .coordinates)
                rings = Self.convert(raw)
            default:
                rings = []
            }
        }

        private static func convert(_ lines: [[[Double]]]) -> [[CLLocationCoordinate2D]] {
            lines.map { line in
                line.compactMap { point in
                    point.count >= 2
                        ? CLLocationCoordinate2D(latitude: point[1], longitude: point[0])
                        : nil
                }
            }
        }
    }

    /// Queries one MapServer layer for the named storm's geometry as GeoJSON.
    private static func geometry(layer: Int, name: String?) async -> [[CLLocationCoordinate2D]] {
        guard layer >= 0 else { return [] }
        var components = URLComponents(string: "\(mapServer)/\(layer)/query")!
        components.queryItems = [
            URLQueryItem(name: "where", value: "1=1"),
            URLQueryItem(name: "outFields", value: "stormname"),
            URLQueryItem(name: "outSR", value: "4326"),
            URLQueryItem(name: "returnGeometry", value: "true"),
            URLQueryItem(name: "f", value: "geojson"),
        ]
        guard let url = components.url,
              let (data, _) = try? await RadarNetwork.session.data(from: url),
              let collection = try? JSONDecoder().decode(FeatureCollection.self, from: data)
        else {
            return []
        }
        return collection.features.compactMap { $0.geometry?.rings }.flatMap { $0 }
    }
}
