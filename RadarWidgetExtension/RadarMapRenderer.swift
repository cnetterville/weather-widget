//
//  RadarMapRenderer.swift
//  RadarWidgetExtension
//

import AppKit
import CoreLocation
import Foundation
import MapKit

enum RadarRenderError: Error {
    case emptyLocation
    case locationNotFound
    case currentLocationUnavailable
}

/// Captures an Apple Maps snapshot of an area and composites the latest
/// NEXRAD precipitation radar tiles from the Iowa Environmental Mesonet
/// on top of it. Radar coverage is US-only; elsewhere the tiles are empty
/// and the widget shows the plain map.
extension RadarMapStyle {
    /// The MapKit configuration for this style. Standard styles exclude
    /// points of interest so pins don't clutter the weather map.
    var mapConfiguration: MKMapConfiguration {
        switch self {
        case .muted:
            let configuration = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
            configuration.pointOfInterestFilter = .excludingAll
            return configuration
        case .standard:
            let configuration = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .default)
            configuration.pointOfInterestFilter = .excludingAll
            return configuration
        case .satellite:
            return MKImageryMapConfiguration(elevationStyle: .flat)
        }
    }
}

struct RadarMapRenderer {
    let coordinate: CLLocationCoordinate2D
    let latitudeSpan: Double
    let mapStyle: RadarMapStyle
    let size: CGSize

    private static let radarTileAlpha: CGFloat = 0.7
    private static let maximumTileCount = 48
    private static let tileZoomRange = 2...12
    // In image pixels; the image renders at 2x the widget's point size.
    private static let locationDotRadius: CGFloat = 7
    private static let locationDotRingWidth: CGFloat = 3

    struct Result {
        let image: NSImage
        let radarTime: Date?
        /// The most dangerous active warning visible in the rendered area.
        let topWarning: StormWarning?
    }

    func render() async throws -> Result {
        let snapshot = try await takeSnapshot()
        let zoom = tileZoom()
        // Radar being briefly unreachable shouldn't blank the widget; with no
        // tiles, draw() still produces the map with the location dot.
        async let tilesTask = fetchTileImages(tiles: tileRange(zoom: zoom), zoom: zoom)
        async let warningsTask = StormWarningFeed.activeWarnings()
        let tiles = await tilesTask
        let visibleWarnings = visible(warnings: await warningsTask)

        let composited = draw(tiles: tiles, warnings: visibleWarnings, zoom: zoom, over: snapshot)
        let radarTime = tiles.isEmpty ? nil : await Self.radarTimestamp()
        let topWarning = StormWarning.priority
            .compactMap { code in visibleWarnings.first { $0.phenomena == code } }
            .first
        return Result(image: composited, radarTime: radarTime, topWarning: topWarning)
    }

    /// Warnings that overlap the rendered area (with the same margin used
    /// for tile coverage).
    private func visible(warnings: [StormWarning]) -> [StormWarning] {
        let center = region.center
        let span = region.span
        return warnings.filter {
            $0.intersects(
                minLatitude: center.latitude - span.latitudeDelta * 0.7,
                maxLatitude: center.latitude + span.latitudeDelta * 0.7,
                minLongitude: center.longitude - span.longitudeDelta * 0.7,
                maxLongitude: center.longitude + span.longitudeDelta * 0.7
            )
        }
    }

    // MARK: - Map snapshot

    /// The requested region. The snapshotter may fit this to the image aspect
    /// ratio, so tile coverage adds a margin around it.
    private var region: MKCoordinateRegion {
        let aspect = Double(size.width / max(size.height, 1))
        let latitudeRadians = coordinate.latitude * .pi / 180
        let longitudeSpan = min(latitudeSpan * aspect / max(cos(latitudeRadians), 0.2), 340)
        return MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: latitudeSpan, longitudeDelta: longitudeSpan)
        )
    }

    private func takeSnapshot() async throws -> MKMapSnapshotter.Snapshot {
        let options = MKMapSnapshotter.Options()
        options.region = region
        options.size = size
        options.preferredConfiguration = mapStyle.mapConfiguration
        return try await MKMapSnapshotter(options: options).start()
    }

    // MARK: - IEM NEXRAD radar data

    /// The IEM base-reflectivity CONUS composite, regenerated about every
    /// 5 minutes. Standard XYZ Web Mercator tiles, 256 px.
    private static let tileURLTemplate =
        "https://mesonet.agron.iastate.edu/cache/tile.py/1.0.0/nexrad-n0q-900913"

    private struct TileServices: Decodable {
        struct Service: Decodable {
            let id: String
            let utc_valid: String
        }
        let services: [Service]
    }

    /// The generation time of the current composite, from IEM's tile-service
    /// index. Purely informational — the overlay works without it.
    private static func radarTimestamp() async -> Date? {
        let url = URL(string: "https://mesonet.agron.iastate.edu/json/tms.json")!
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let index = try? JSONDecoder().decode(TileServices.self, from: data),
              let service = index.services.first(where: { $0.id == "ridge_uscomp_n0q" })
        else {
            return nil
        }
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: service.utc_valid)
    }

    // MARK: - Tile math (Web Mercator, shared by IEM and Apple Maps)

    private struct TileCoordinate: Hashable {
        // Deliberately not wrapped to 0..<n so tile geometry stays continuous
        // across the antimeridian; wrapping happens when building the URL.
        let x: Int
        let y: Int
    }

    private static func tileIndex(latitude: Double, longitude: Double, zoom: Int) -> (x: Int, y: Int) {
        let n = Double(1 << zoom)
        let x = Int(floor((longitude + 180) / 360 * n))
        let latitudeRadians = latitude * .pi / 180
        let y = Int(floor((1 - log(tan(latitudeRadians) + 1 / cos(latitudeRadians)) / .pi) / 2 * n))
        return (x, y)
    }

    private static func tileNorthWestCorner(x: Int, y: Int, zoom: Int) -> CLLocationCoordinate2D {
        let n = Double(1 << zoom)
        let longitude = Double(x) / n * 360 - 180
        let latitudeRadians = atan(sinh(.pi * (1 - 2 * Double(y) / n)))
        return CLLocationCoordinate2D(latitude: latitudeRadians * 180 / .pi, longitude: longitude)
    }

    /// Picks a tile zoom whose resolution roughly matches the snapshot,
    /// backing off until the tile count is reasonable.
    private func tileZoom() -> Int {
        let pixelsPerLongitudeDegree = Double(size.width) / region.span.longitudeDelta
        let ideal = Int((log2(pixelsPerLongitudeDegree * 360 / 256)).rounded())
        var zoom = min(max(ideal, Self.tileZoomRange.lowerBound), Self.tileZoomRange.upperBound)
        while zoom > Self.tileZoomRange.lowerBound, tileRange(zoom: zoom).count > Self.maximumTileCount {
            zoom -= 1
        }
        return zoom
    }

    /// Tiles covering the requested region plus a margin, since the
    /// snapshotter can expand the region to fit the image aspect ratio.
    private func tileRange(zoom: Int) -> [TileCoordinate] {
        let center = region.center
        let span = region.span
        let maxLatitude = min(center.latitude + span.latitudeDelta * 0.7, 85)
        let minLatitude = max(center.latitude - span.latitudeDelta * 0.7, -85)
        let minLongitude = center.longitude - span.longitudeDelta * 0.7
        let maxLongitude = center.longitude + span.longitudeDelta * 0.7

        let topLeft = Self.tileIndex(latitude: maxLatitude, longitude: minLongitude, zoom: zoom)
        let bottomRight = Self.tileIndex(latitude: minLatitude, longitude: maxLongitude, zoom: zoom)
        let n = 1 << zoom

        var tiles: [TileCoordinate] = []
        for x in topLeft.x...bottomRight.x {
            for y in max(topLeft.y, 0)...min(bottomRight.y, n - 1) {
                tiles.append(TileCoordinate(x: x, y: y))
            }
        }
        return tiles
    }

    // MARK: - Compositing

    private func fetchTileImages(
        tiles: [TileCoordinate],
        zoom: Int
    ) async -> [(tile: TileCoordinate, image: NSImage)] {
        let n = 1 << zoom
        return await withTaskGroup(of: (TileCoordinate, NSImage?).self) { group in
            for tile in tiles {
                group.addTask {
                    let wrappedX = ((tile.x % n) + n) % n
                    let urlString = "\(Self.tileURLTemplate)/\(zoom)/\(wrappedX)/\(tile.y).png"
                    guard let url = URL(string: urlString),
                          let (data, response) = try? await URLSession.shared.data(from: url),
                          (response as? HTTPURLResponse)?.statusCode == 200,
                          let image = NSImage(data: data)
                    else {
                        return (tile, nil)
                    }
                    return (tile, image)
                }
            }
            var results: [(tile: TileCoordinate, image: NSImage)] = []
            for await (tile, image) in group {
                if let image {
                    results.append((tile, image))
                }
            }
            return results
        }
    }

    private func draw(
        tiles: [(tile: TileCoordinate, image: NSImage)],
        warnings: [StormWarning],
        zoom: Int,
        over snapshot: MKMapSnapshotter.Snapshot
    ) -> NSImage {
        let mapImage = snapshot.image
        let imageSize = mapImage.size
        guard imageSize.width > 0, imageSize.height > 0,
              let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(imageSize.width),
                pixelsHigh: Int(imageSize.height),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap)
        else {
            return mapImage
        }
        bitmap.size = imageSize

        // point(for:) may use a top-left or bottom-left origin depending on
        // platform; calibrate with a coordinate known to be north of center.
        let centerPoint = snapshot.point(for: region.center)
        let northCoordinate = CLLocationCoordinate2D(
            latitude: min(region.center.latitude + region.span.latitudeDelta / 4, 85),
            longitude: region.center.longitude
        )
        let yIncreasesUpward = snapshot.point(for: northCoordinate).y > centerPoint.y

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        mapImage.draw(in: NSRect(origin: .zero, size: imageSize))

        let imageBounds = NSRect(origin: .zero, size: imageSize)
        for (tile, image) in tiles {
            let northWest = snapshot.point(for: Self.tileNorthWestCorner(x: tile.x, y: tile.y, zoom: zoom))
            let southEast = snapshot.point(for: Self.tileNorthWestCorner(x: tile.x + 1, y: tile.y + 1, zoom: zoom))

            let width = abs(southEast.x - northWest.x)
            let height = abs(southEast.y - northWest.y)
            let left = min(northWest.x, southEast.x)
            // The drawing context uses a bottom-left origin.
            let bottom = yIncreasesUpward
                ? min(northWest.y, southEast.y)
                : imageSize.height - max(northWest.y, southEast.y)

            let rect = NSRect(x: left, y: bottom, width: width, height: height)
            guard rect.intersects(imageBounds) else { continue }
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: Self.radarTileAlpha)
        }

        // Outline active warning polygons, least dangerous first so the most
        // dangerous draw on top.
        let toImagePoint = { (coordinate: CLLocationCoordinate2D) -> NSPoint in
            let point = snapshot.point(for: coordinate)
            return NSPoint(
                x: point.x,
                y: yIncreasesUpward ? point.y : imageSize.height - point.y
            )
        }
        for code in StormWarning.priority.reversed() {
            for warning in warnings where warning.phenomena == code {
                for ring in warning.rings where ring.count > 2 {
                    let path = NSBezierPath()
                    path.move(to: toImagePoint(ring[0]))
                    for coordinate in ring.dropFirst() {
                        path.line(to: toImagePoint(coordinate))
                    }
                    path.close()
                    path.lineWidth = 4
                    warning.color.withAlphaComponent(0.9).setStroke()
                    path.stroke()
                }
            }
        }

        // Mark the configured location with a small white-ringed blue dot.
        let markerPoint = snapshot.point(for: coordinate)
        let marker = NSPoint(
            x: markerPoint.x,
            y: yIncreasesUpward ? markerPoint.y : imageSize.height - markerPoint.y
        )
        let ringRadius = Self.locationDotRadius + Self.locationDotRingWidth
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(
            x: marker.x - ringRadius,
            y: marker.y - ringRadius,
            width: ringRadius * 2,
            height: ringRadius * 2
        )).fill()
        NSColor.systemBlue.setFill()
        NSBezierPath(ovalIn: NSRect(
            x: marker.x - Self.locationDotRadius,
            y: marker.y - Self.locationDotRadius,
            width: Self.locationDotRadius * 2,
            height: Self.locationDotRadius * 2
        )).fill()

        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        let composited = NSImage(size: imageSize)
        composited.addRepresentation(bitmap)
        return composited
    }
}
