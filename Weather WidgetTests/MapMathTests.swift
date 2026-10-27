//
//  MapMathTests.swift
//  Weather WidgetTests
//

import CoreLocation
import Foundation
import Testing

struct TileMathTests {
    @Test func knownTileIndices() {
        let origin = RadarMapRenderer.tileIndex(latitude: 0.1, longitude: 0.1, zoom: 1)
        #expect(origin.x == 1 && origin.y == 0)
        let houston = RadarMapRenderer.tileIndex(latitude: 29.76, longitude: -95.37, zoom: 10)
        #expect(houston.x == 240 && houston.y == 423)
    }

    @Test func topLeftTileCornerIsMercatorLimit() {
        let corner = RadarMapRenderer.tileNorthWestCorner(x: 0, y: 0, zoom: 5)
        #expect(abs(corner.latitude - 85.0511) < 0.001)
        #expect(corner.longitude == -180)
    }

    @Test(arguments: [3, 7, 12])
    func cornerRoundTripsToItsTile(zoom: Int) {
        for (x, y) in [(0, 0), (1, 2), ((1 << zoom) - 1, (1 << zoom) - 1), ((1 << zoom) / 3, (1 << zoom) / 2)] {
            let northWest = RadarMapRenderer.tileNorthWestCorner(x: x, y: y, zoom: zoom)
            let southEast = RadarMapRenderer.tileNorthWestCorner(x: x + 1, y: y + 1, zoom: zoom)
            // The tile's own center maps back to the tile.
            let index = RadarMapRenderer.tileIndex(
                latitude: (northWest.latitude + southEast.latitude) / 2,
                longitude: (northWest.longitude + southEast.longitude) / 2,
                zoom: zoom
            )
            #expect(index.x == x && index.y == y, "zoom \(zoom) tile \(x),\(y)")
        }
    }
}

struct SolarTimeTests {
    let houston = CLLocationCoordinate2D(latitude: 29.76, longitude: -95.37)

    private func utc(_ string: String) -> Date {
        try! Date(string, strategy: .iso8601)
    }

    @Test func equinoxNoonAtEquatorIsOverhead() {
        let equator = CLLocationCoordinate2D(latitude: 0, longitude: 0)
        let elevation = SolarTime.elevationDegrees(at: equator, date: utc("2026-03-20T12:00:00Z"))
        #expect(elevation > 85)
    }

    @Test func midnightAtEquatorIsDeepNight() {
        let equator = CLLocationCoordinate2D(latitude: 0, longitude: 0)
        let elevation = SolarTime.elevationDegrees(at: equator, date: utc("2026-03-20T00:00:00Z"))
        #expect(elevation < -80)
    }

    /// Houston's midsummer sun peaks at 90 − 29.76 + 23.44 ≈ 83.7°, around
    /// 1:23 PM CDT (18:23 UTC).
    @Test func houstonSummerSolsticeNoon() {
        let elevation = SolarTime.elevationDegrees(at: houston, date: utc("2026-06-21T18:23:00Z"))
        #expect((82.5...84.5).contains(elevation))
    }

    /// Houston's midsummer sunset is about 8:26 PM CDT (01:26 UTC).
    @Test func houstonSummerSunset() {
        #expect(!SolarTime.isNight(at: houston, date: utc("2026-06-22T01:00:00Z")))
        #expect(SolarTime.isNight(at: houston, date: utc("2026-06-22T02:00:00Z")))
    }
}
