//
//  RadarTropical.swift
//  RadarWidgetExtension
//

import AppKit
import CoreLocation
import Foundation

/// A coastal tropical watch/warning segment: TWA/TWR (tropical storm watch/
/// warning) or HWA/HWR (hurricane watch/warning) along a stretch of coastline.
struct TropicalWatchWarning {
    let code: String
    let points: [CLLocationCoordinate2D]

    /// Standard NHC display colors: hurricane warning red, hurricane watch
    /// pink, tropical storm warning blue, tropical storm watch yellow.
    var color: NSColor {
        switch code {
        case "HWR": .systemRed
        case "HWA": .systemPink
        case "TWR": .systemBlue
        case "TWA": .systemYellow
        default: .systemOrange
        }
    }
}

/// A line of equal forecast arrival time for tropical-storm-force winds.
struct ArrivalIsochrone {
    /// Human-readable arrival time from NHC, like "Sat 2 am".
    let label: String
    let points: [CLLocationCoordinate2D]
}

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
    /// Coastal watch/warning segments in effect for this storm.
    let watchWarnings: [TropicalWatchWarning]
    /// "Most likely arrival time of tropical-storm-force winds" isochrones.
    let arrivalIsochrones: [ArrivalIsochrone]

    /// The most likely arrival time of tropical-storm-force winds at a
    /// location, taken from the nearest isochrone when one passes close by.
    /// Returns nil when the location isn't meaningfully in the storm's path.
    func windArrival(at location: CLLocationCoordinate2D) -> String? {
        var nearest: (label: String, degrees: Double)?
        for isochrone in arrivalIsochrones {
            for point in isochrone.points {
                // Flat-earth approximation is fine at this scale.
                let dLatitude = point.latitude - location.latitude
                let dLongitude = (point.longitude - location.longitude)
                    * cos(location.latitude * .pi / 180)
                let degrees = (dLatitude * dLatitude + dLongitude * dLongitude).squareRoot()
                if nearest == nil || degrees < nearest!.degrees {
                    nearest = (isochrone.label, degrees)
                }
            }
        }
        // Isochrones are ~6 hours apart; within about 1 degree (~70 mi) the
        // nearest line is a fair estimate for "when winds reach here".
        guard let nearest, nearest.degrees < 1.0 else { return nil }
        return nearest.label
    }

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
    /// Related layers sit at fixed offsets from the cone: the forecast track
    /// one id below, coastal watches/warnings one above, and the "most likely
    /// arrival time of TS winds" isochrones twelve above.
    private static func trackLayer(for bin: String) -> Int? {
        coneLayer[bin].map { $0 - 1 }
    }
    private static func watchWarningLayer(for bin: String) -> Int? {
        coneLayer[bin].map { $0 + 1 }
    }
    private static func arrivalLayer(for bin: String) -> Int? {
        coneLayer[bin].map { $0 + 12 }
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
                    async let coneFeatures = features(layer: coneID)
                    async let trackFeatures = features(layer: trackLayer(for: bin) ?? -1)
                    async let watchFeatures = features(layer: watchWarningLayer(for: bin) ?? -1)
                    async let arrivalFeatures = features(layer: arrivalLayer(for: bin) ?? -1)
                    let rings = await coneFeatures.flatMap(\.rings)
                    guard !rings.isEmpty else { return nil }
                    return TropicalCyclone(
                        name: storm.name ?? "Tropical Cyclone",
                        classification: storm.classification ?? "",
                        intensityKnots: Int(storm.intensity ?? "") ?? 0,
                        center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                        coneRings: rings,
                        track: (await trackFeatures).flatMap(\.rings).first ?? [],
                        watchWarnings: (await watchFeatures).flatMap { feature in
                            feature.rings.compactMap { ring in
                                feature.watchWarningCode.map {
                                    TropicalWatchWarning(code: $0, points: ring)
                                }
                            }
                        },
                        arrivalIsochrones: (await arrivalFeatures).flatMap { feature in
                            feature.rings.compactMap { ring in
                                feature.arrivalTime.map {
                                    ArrivalIsochrone(label: $0, points: ring)
                                }
                            }
                        }
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
            struct Properties: Decodable {
                let tcww: String?
                let arrival_time: String?
            }
            let properties: Properties?
            let geometry: Geometry?
        }
        let features: [Feature]
    }

    /// One returned feature: its geometry plus the fields the overlay uses.
    struct LayerFeature {
        let rings: [[CLLocationCoordinate2D]]
        let watchWarningCode: String?
        let arrivalTime: String?
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

    /// Queries one MapServer layer for its features as GeoJSON.
    private static func features(layer: Int) async -> [LayerFeature] {
        guard layer >= 0 else { return [] }
        var components = URLComponents(string: "\(mapServer)/\(layer)/query")!
        components.queryItems = [
            URLQueryItem(name: "where", value: "1=1"),
            // "*" because field lists vary by layer and unknown names error out.
            URLQueryItem(name: "outFields", value: "*"),
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
        return collection.features.compactMap { feature in
            guard let rings = feature.geometry?.rings, !rings.isEmpty else { return nil }
            return LayerFeature(
                rings: rings,
                watchWarningCode: feature.properties?.tcww,
                arrivalTime: feature.properties?.arrival_time
            )
        }
    }
}
