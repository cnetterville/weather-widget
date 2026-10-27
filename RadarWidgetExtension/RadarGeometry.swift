//
//  RadarGeometry.swift
//  RadarWidgetExtension
//

import CoreLocation
import Foundation

/// A latitude/longitude rectangle, such as the area a render covers.
struct GeoBounds {
    let minLatitude: Double
    let maxLatitude: Double
    let minLongitude: Double
    let maxLongitude: Double

    var center: CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: (minLatitude + maxLatitude) / 2,
            longitude: (minLongitude + maxLongitude) / 2
        )
    }

    func contains(_ point: CLLocationCoordinate2D) -> Bool {
        point.latitude >= minLatitude && point.latitude <= maxLatitude
            && point.longitude >= minLongitude && point.longitude <= maxLongitude
    }
}

/// Polygon tests on raw latitude/longitude, treated as a flat plane. That's
/// accurate enough at the scale of a warning polygon or a forecast cone.
enum GeoPolygon {
    /// Whether the point lies inside the ring (even-odd rule).
    static func contains(_ point: CLLocationCoordinate2D, ring: [CLLocationCoordinate2D]) -> Bool {
        guard ring.count > 2 else { return false }
        var inside = false
        var previous = ring[ring.count - 1]
        for current in ring {
            if (current.latitude > point.latitude) != (previous.latitude > point.latitude) {
                let crossingLongitude = current.longitude
                    + (point.latitude - current.latitude)
                    / (previous.latitude - current.latitude)
                    * (previous.longitude - current.longitude)
                if point.longitude < crossingLongitude {
                    inside.toggle()
                }
            }
            previous = current
        }
        return inside
    }

    /// Whether any part of the ring's area overlaps the bounds — including
    /// the case where the ring is larger than the bounds and surrounds them
    /// entirely, so none of its vertices fall inside.
    static func ring(_ ring: [CLLocationCoordinate2D], overlaps bounds: GeoBounds) -> Bool {
        guard let first = ring.first else { return false }

        // Cheap reject: the ring's bounding box misses the bounds entirely.
        var minLatitude = first.latitude, maxLatitude = first.latitude
        var minLongitude = first.longitude, maxLongitude = first.longitude
        for point in ring {
            minLatitude = min(minLatitude, point.latitude)
            maxLatitude = max(maxLatitude, point.latitude)
            minLongitude = min(minLongitude, point.longitude)
            maxLongitude = max(maxLongitude, point.longitude)
        }
        guard maxLatitude >= bounds.minLatitude, minLatitude <= bounds.maxLatitude,
              maxLongitude >= bounds.minLongitude, minLongitude <= bounds.maxLongitude
        else { return false }

        // Part of the ring is inside the bounds.
        if ring.contains(where: bounds.contains) {
            return true
        }
        // The ring surrounds the bounds.
        if contains(bounds.center, ring: ring) {
            return true
        }
        // The ring passes through the bounds without a vertex inside.
        let corners = [
            CLLocationCoordinate2D(latitude: bounds.minLatitude, longitude: bounds.minLongitude),
            CLLocationCoordinate2D(latitude: bounds.minLatitude, longitude: bounds.maxLongitude),
            CLLocationCoordinate2D(latitude: bounds.maxLatitude, longitude: bounds.maxLongitude),
            CLLocationCoordinate2D(latitude: bounds.maxLatitude, longitude: bounds.minLongitude),
        ]
        var previous = ring[ring.count - 1]
        for current in ring {
            for index in corners.indices {
                let edgeStart = corners[index]
                let edgeEnd = corners[(index + 1) % corners.count]
                if segmentsIntersect(previous, current, edgeStart, edgeEnd) {
                    return true
                }
            }
            previous = current
        }
        return false
    }

    private static func segmentsIntersect(
        _ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D,
        _ c: CLLocationCoordinate2D, _ d: CLLocationCoordinate2D
    ) -> Bool {
        func orientation(
            _ p: CLLocationCoordinate2D, _ q: CLLocationCoordinate2D, _ r: CLLocationCoordinate2D
        ) -> Double {
            (q.longitude - p.longitude) * (r.latitude - p.latitude)
                - (q.latitude - p.latitude) * (r.longitude - p.longitude)
        }
        let d1 = orientation(c, d, a)
        let d2 = orientation(c, d, b)
        let d3 = orientation(a, b, c)
        let d4 = orientation(a, b, d)
        return ((d1 > 0) != (d2 > 0)) && ((d3 > 0) != (d4 > 0))
    }
}
