//
//  VentuskyTests.swift
//  Weather WidgetTests
//

import CoreLocation
import Foundation
import Testing

struct VentuskyViewportTests {
    let large = CGSize(width: 344, height: 344)

    @Test(arguments: [0.35, 0.9, 1.75, 2.2, 5.0])
    func pageIsOneToTwoTimesTheWidget(span: Double) {
        for center in [
            CLLocationCoordinate2D(latitude: 29.76, longitude: -95.37),
            CLLocationCoordinate2D(latitude: 20.7, longitude: -105.3),
        ] {
            let viewport = VentuskyViewport(center: center, latitudeSpan: span, displaySize: large)
            #expect(viewport.cssSize.height >= large.height - 1, "span \(span)")
            #expect(viewport.cssSize.height < large.height * 2 + 1, "span \(span)")
        }
    }

    @Test func pageKeepsTheWidgetsShape() {
        let medium = CGSize(width: 344, height: 162)
        let viewport = VentuskyViewport(
            center: CLLocationCoordinate2D(latitude: 29.76, longitude: -95.37),
            latitudeSpan: 0.9,
            displaySize: medium
        )
        #expect(abs(viewport.cssSize.width / viewport.cssSize.height - medium.width / medium.height) < 0.01)
    }

    @Test func coversTheRequestedSpan() {
        let center = CLLocationCoordinate2D(latitude: 29.76, longitude: -95.37)
        let viewport = VentuskyViewport(center: center, latitudeSpan: 2.2, displaySize: large)
        let image = CGSize(width: 688, height: 688)
        let top = viewport.imagePoint(for: CLLocationCoordinate2D(latitude: 29.76 + 1.1, longitude: -95.37), imageSize: image)
        let bottom = viewport.imagePoint(for: CLLocationCoordinate2D(latitude: 29.76 - 1.1, longitude: -95.37), imageSize: image)
        // The full span fills the height. On a Mercator map the north half
        // of a centered span is a little taller than the south half, so
        // each edge sits a few pixels off the image's edge.
        #expect(abs((top.y - bottom.y) - image.height) < 2)
        #expect(abs(top.y - image.height) < 10)
        #expect(abs(bottom.y) < 10)
    }

    @Test func centerIsInTheMiddleAndNorthIsUp() {
        let center = CLLocationCoordinate2D(latitude: 20.7, longitude: -105.3)
        let viewport = VentuskyViewport(center: center, latitudeSpan: 0.9, displaySize: large)
        let image = CGSize(width: 688, height: 688)
        let middle = viewport.imagePoint(for: center, imageSize: image)
        #expect(abs(middle.x - 344) < 0.001 && abs(middle.y - 344) < 0.001)
        let north = viewport.imagePoint(for: CLLocationCoordinate2D(latitude: 20.8, longitude: -105.3), imageSize: image)
        let east = viewport.imagePoint(for: CLLocationCoordinate2D(latitude: 20.7, longitude: -105.2), imageSize: image)
        #expect(north.y > middle.y)
        #expect(east.x > middle.x)
    }

    @Test func urlUsesAWholeZoom() throws {
        let viewport = VentuskyViewport(
            center: CLLocationCoordinate2D(latitude: 29.76, longitude: -95.37),
            latitudeSpan: 2.2,
            displaySize: large
        )
        let url = try #require(viewport.url)
        #expect(url.absoluteString == "https://www.ventusky.com/?p=29.7600;-95.3700;\(viewport.zoom)&l=radar")
        #expect(VentuskyViewport.zoomRange.contains(viewport.zoom))
    }
}
