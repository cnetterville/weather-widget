//
//  TropicalTests.swift
//  Weather WidgetTests
//

import CoreLocation
import Testing

extension TropicalCyclone {
    static func sample(
        classification: String = "HU",
        intensityKnots: Int = 100,
        coneRings: [[CLLocationCoordinate2D]] = [],
        arrivalIsochrones: [ArrivalIsochrone] = []
    ) -> TropicalCyclone {
        TropicalCyclone(
            name: "Test",
            classification: classification,
            intensityKnots: intensityKnots,
            center: CLLocationCoordinate2D(latitude: 25, longitude: -90),
            coneRings: coneRings,
            track: [],
            watchWarnings: [],
            arrivalIsochrones: arrivalIsochrones
        )
    }
}

struct TropicalTests {
    let houston = CLLocationCoordinate2D(latitude: 29.76, longitude: -95.37)

    /// A north-south isochrone line at the given longitude.
    private func isochrone(_ label: String, longitude: Double) -> ArrivalIsochrone {
        ArrivalIsochrone(label: label, points: (0...20).map {
            CLLocationCoordinate2D(latitude: 25 + Double($0) * 0.5, longitude: longitude)
        })
    }

    @Test func windArrivalPicksNearestIsochrone() {
        let cyclone = TropicalCyclone.sample(arrivalIsochrones: [
            isochrone("Sat 2 am", longitude: -94.0),
            isochrone("Sat 8 am", longitude: -95.5),
            isochrone("Sat 2 pm", longitude: -97.0),
        ])
        #expect(cyclone.windArrival(at: houston) == "Sat 8 am")
    }

    @Test func noWindArrivalWhenStormIsFar() {
        let cyclone = TropicalCyclone.sample(arrivalIsochrones: [isochrone("Sat 2 am", longitude: -85)])
        #expect(cyclone.windArrival(at: houston) == nil)
    }

    @Test func noWindArrivalWithoutIsochrones() {
        #expect(TropicalCyclone.sample().windArrival(at: houston) == nil)
    }

    @Test(arguments: [
        ("HU", 64, "Cat 1 Hurricane"),
        ("HU", 95, "Cat 2 Hurricane"),
        ("HU", 100, "Cat 3 Hurricane"),
        ("MH", 120, "Cat 4 Hurricane"),
        ("HU", 140, "Cat 5 Hurricane"),
        ("TS", 45, "Tropical Storm"),
        ("TD", 30, "Tropical Depression"),
        ("PTC", 30, "Potential Cyclone"),
    ])
    func summary(classification: String, knots: Int, expected: String) {
        let cyclone = TropicalCyclone.sample(classification: classification, intensityKnots: knots)
        #expect(cyclone.summary == expected)
    }
}
