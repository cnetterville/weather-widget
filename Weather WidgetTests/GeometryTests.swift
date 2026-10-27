//
//  GeometryTests.swift
//  Weather WidgetTests
//

import CoreLocation
import Testing

/// A closed ring from (latitude, longitude) pairs.
func ring(_ points: [(Double, Double)]) -> [CLLocationCoordinate2D] {
    points.map { CLLocationCoordinate2D(latitude: $0.0, longitude: $0.1) }
}

struct GeometryTests {
    /// A 1° box around (30, -95), the shape of a typical rendered area.
    let view = GeoBounds(minLatitude: 29.5, maxLatitude: 30.5, minLongitude: -95.5, maxLongitude: -94.5)

    @Test func pointInPolygon() {
        let square = ring([(0, 0), (0, 10), (10, 10), (10, 0)])
        #expect(GeoPolygon.contains(CLLocationCoordinate2D(latitude: 5, longitude: 5), ring: square))
        #expect(!GeoPolygon.contains(CLLocationCoordinate2D(latitude: 15, longitude: 5), ring: square))
        #expect(!GeoPolygon.contains(CLLocationCoordinate2D(latitude: 5, longitude: -1), ring: square))
    }

    @Test func pointInConcavePolygon() {
        // An L shape: the notch at the top right is outside.
        let shape = ring([(0, 0), (10, 0), (10, 4), (4, 4), (4, 10), (0, 10)])
        #expect(GeoPolygon.contains(CLLocationCoordinate2D(latitude: 2, longitude: 8), ring: shape))
        #expect(!GeoPolygon.contains(CLLocationCoordinate2D(latitude: 8, longitude: 8), ring: shape))
    }

    @Test func overlapWithVertexInside() {
        let shape = ring([(30, -95), (31, -95), (31, -94)])
        #expect(GeoPolygon.ring(shape, overlaps: view))
    }

    /// The case that used to hide hurricane cones at close zoom: no vertex
    /// lands in view because the polygon surrounds it.
    @Test func overlapWhenPolygonSurroundsView() {
        let cone = ring([(20, -105), (40, -105), (40, -85), (20, -85)])
        #expect(!cone.contains(where: view.contains))
        #expect(GeoPolygon.ring(cone, overlaps: view))
    }

    @Test func overlapWhenEdgesCrossWithoutVertexInside() {
        // A thin band running straight through the view, ends far outside.
        let band = ring([(29.9, -100), (29.9, -90), (30.1, -90), (30.1, -100)])
        #expect(!band.contains(where: view.contains))
        #expect(GeoPolygon.ring(band, overlaps: view))
    }

    @Test func noOverlapWhenDisjoint() {
        let shape = ring([(40, -80), (41, -80), (41, -79)])
        #expect(!GeoPolygon.ring(shape, overlaps: view))
    }

    @Test func noOverlapWhenOnlyBoundingBoxesOverlap() {
        // A triangle whose bounding box covers the view's corner but whose
        // hypotenuse passes beyond it.
        let triangle = ring([(28, -98), (28, -95.6), (29.4, -98)])
        #expect(!GeoPolygon.ring(triangle, overlaps: view))
    }

    @Test func emptyRingNeverOverlaps() {
        #expect(!GeoPolygon.ring([], overlaps: view))
        #expect(!GeoPolygon.contains(view.center, ring: []))
    }

    @Test func stormWarningCoversLocation() {
        let warning = StormWarning(
            phenomena: "TO",
            rings: [ring([(29, -96), (31, -96), (31, -94), (29, -94)])],
            expires: nil
        )
        #expect(warning.contains(CLLocationCoordinate2D(latitude: 30, longitude: -95)))
        #expect(!warning.contains(CLLocationCoordinate2D(latitude: 32, longitude: -95)))
        #expect(warning.intersects(view))
        #expect(warning.eventName == "Tornado Warning")
    }

    @Test func tropicalConeSurroundingViewIntersects() {
        let cyclone = TropicalCyclone.sample(
            coneRings: [ring([(20, -105), (40, -105), (40, -85), (20, -85)])]
        )
        #expect(cyclone.intersects(view))
    }
}
