//
//  RadarMapRenderer.swift
//  RadarWidgetExtension
//

import AppKit
import CoreImage
import CoreLocation
import Foundation
import MapKit

enum RadarRenderError: Error {
    case emptyLocation
    case locationNotFound
    case currentLocationUnavailable
}

/// Shared session with tight timeouts. WidgetKit gives a render a short
/// budget; a stalled request must fail fast (dropping that tile or data
/// layer) rather than time the whole render out and leave stale content.
enum RadarNetwork {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 15
        return URLSession(configuration: configuration)
    }()
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
    let radarSource: RadarSource
    let size: CGSize

    private static let radarTileAlpha: CGFloat = 0.7
    private static let maximumTileCount = 48
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
        async let warningsTask = StormWarningFeed.activeWarnings()
        async let cellsTask = StormCellFeed.activeCells()

        // Radar being briefly unreachable shouldn't blank the widget; with no
        // layer or tiles, draw() still produces the map with the location dot.
        var tiles: [(tile: TileCoordinate, image: NSImage)] = []
        var zoom = 0
        let layer = await tileLayer()
        if let layer {
            zoom = tileZoom(for: layer)
            tiles = await fetchTileImages(tiles: tileRange(zoom: zoom), zoom: zoom, layer: layer)
        }
        let visibleWarnings = visible(warnings: await warningsTask)
        let visibleCells = visible(cells: await cellsTask)

        let composited = draw(
            tiles: tiles,
            warnings: visibleWarnings,
            cells: visibleCells,
            zoom: zoom,
            over: snapshot
        )
        let radarTime = tiles.isEmpty ? nil : layer?.time
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

    /// The strongest tracked storm cells inside the rendered area, capped so
    /// arrows never crowd the map at wide zooms.
    private func visible(cells: [StormCell]) -> [StormCell] {
        let center = region.center
        let span = region.span
        return cells
            .filter {
                abs($0.coordinate.latitude - center.latitude) < span.latitudeDelta / 2
                    && abs($0.coordinate.longitude - center.longitude) < span.longitudeDelta / 2
            }
            .sorted { $0.maxDBZ > $1.maxDBZ }
            .prefix(10)
            .map { $0 }
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

    // MARK: - Radar tile sources

    /// A resolved tile layer: where tiles live and what they look like.
    private struct TileLayer {
        let time: Date?
        let tileSize: Double
        let zoomRange: ClosedRange<Int>
        /// URL pieces around the /{z}/{x}/{y} path component.
        let urlPrefix: String
        let urlSuffix: String

        func url(zoom: Int, x: Int, y: Int) -> URL? {
            URL(string: "\(urlPrefix)/\(zoom)/\(x)/\(y)\(urlSuffix)")
        }
    }

    private func tileLayer() async -> TileLayer? {
        switch radarSource {
        case .nexrad:
            // IEM's base-reflectivity US composite, regenerated about every
            // 5 minutes. Real detail well past zoom 7.
            return TileLayer(
                time: await Self.nexradTimestamp(),
                tileSize: 256,
                zoomRange: 2...12,
                urlPrefix: "https://mesonet.agron.iastate.edu/cache/tile.py/1.0.0/nexrad-n0q-900913",
                urlSuffix: ".png"
            )
        case .worldwide:
            // RainViewer aggregates national radar networks worldwide. The
            // free API caps tiles at zoom 7, Universal Blue color scheme.
            guard let frame = await Self.rainViewerFrame() else { return nil }
            return TileLayer(
                time: frame.time,
                tileSize: 512,
                zoomRange: 2...7,
                urlPrefix: "\(frame.host)\(frame.path)/512",
                urlSuffix: "/2/1_1.png"
            )
        }
    }

    private struct TileServices: Decodable {
        struct Service: Decodable {
            let id: String
            let utc_valid: String
        }
        let services: [Service]
    }

    /// The generation time of the current IEM composite, from its
    /// tile-service index. Purely informational — the overlay works without it.
    private static func nexradTimestamp() async -> Date? {
        let url = URL(string: "https://mesonet.agron.iastate.edu/json/tms.json")!
        guard let (data, _) = try? await RadarNetwork.session.data(from: url),
              let index = try? JSONDecoder().decode(TileServices.self, from: data),
              let service = index.services.first(where: { $0.id == "ridge_uscomp_n0q" })
        else {
            return nil
        }
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: service.utc_valid)
    }

    private struct WeatherMaps: Decodable {
        struct Frame: Decodable {
            let time: Int
            let path: String
        }
        struct Radar: Decodable {
            let past: [Frame]
        }
        let host: String
        let radar: Radar
    }

    /// The newest RainViewer radar frame (host + path + capture time).
    private static func rainViewerFrame() async -> (host: String, path: String, time: Date)? {
        let url = URL(string: "https://api.rainviewer.com/public/weather-maps.json")!
        guard let (data, _) = try? await RadarNetwork.session.data(from: url),
              let maps = try? JSONDecoder().decode(WeatherMaps.self, from: data),
              let latest = maps.radar.past.max(by: { $0.time < $1.time })
        else {
            return nil
        }
        return (maps.host, latest.path, Date(timeIntervalSince1970: TimeInterval(latest.time)))
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
    private func tileZoom(for layer: TileLayer) -> Int {
        let pixelsPerLongitudeDegree = Double(size.width) / region.span.longitudeDelta
        let ideal = Int((log2(pixelsPerLongitudeDegree * 360 / layer.tileSize)).rounded())
        var zoom = min(max(ideal, layer.zoomRange.lowerBound), layer.zoomRange.upperBound)
        while zoom > layer.zoomRange.lowerBound, tileRange(zoom: zoom).count > Self.maximumTileCount {
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
        zoom: Int,
        layer: TileLayer
    ) async -> [(tile: TileCoordinate, image: NSImage)] {
        let n = 1 << zoom
        return await withTaskGroup(of: (TileCoordinate, NSImage?).self) { group in
            for tile in tiles {
                group.addTask {
                    let wrappedX = ((tile.x % n) + n) % n
                    guard let url = layer.url(zoom: zoom, x: wrappedX, y: tile.y),
                          let (data, response) = try? await RadarNetwork.session.data(from: url),
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

    /// Draws the tiles at full opacity into a transparent layer, smoothing
    /// the ~1 km radar data cells when they'd read as visible blocks.
    private func radarLayer(
        tiles: [(tile: TileCoordinate, image: NSImage)],
        zoom: Int,
        imageSize: NSSize,
        toImagePoint: (CLLocationCoordinate2D) -> NSPoint
    ) -> NSImage? {
        guard !tiles.isEmpty,
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
            return nil
        }
        bitmap.size = imageSize

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let imageBounds = NSRect(origin: .zero, size: imageSize)
        for (tile, image) in tiles {
            let northWest = toImagePoint(Self.tileNorthWestCorner(x: tile.x, y: tile.y, zoom: zoom))
            let southEast = toImagePoint(Self.tileNorthWestCorner(x: tile.x + 1, y: tile.y + 1, zoom: zoom))
            let rect = NSRect(
                x: min(northWest.x, southEast.x),
                y: min(northWest.y, southEast.y),
                width: abs(southEast.x - northWest.x),
                height: abs(southEast.y - northWest.y)
            )
            guard rect.intersects(imageBounds) else { continue }
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        }
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        // Size of one ~1 km radar data cell in image pixels; only smooth
        // when cells are large enough to look blocky.
        let pixelsPerKilometer = Double(imageSize.height) / (latitudeSpan * 111)
        let blurRadius = pixelsPerKilometer * 0.5
        if blurRadius >= 1.5, let smoothed = Self.blurred(bitmap, radius: blurRadius) {
            return smoothed
        }
        let image = NSImage(size: imageSize)
        image.addRepresentation(bitmap)
        return image
    }

    private static func blurred(_ bitmap: NSBitmapImageRep, radius: Double) -> NSImage? {
        guard let cgImage = bitmap.cgImage else { return nil }
        let input = CIImage(cgImage: cgImage)
        let filter = CIFilter(name: "CIGaussianBlur")
        filter?.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        filter?.setValue(radius, forKey: kCIInputRadiusKey)
        guard let output = filter?.outputImage?.cropped(to: input.extent),
              let result = CIContext().createCGImage(output, from: input.extent)
        else {
            return nil
        }
        return NSImage(cgImage: result, size: bitmap.size)
    }

    private func draw(
        tiles: [(tile: TileCoordinate, image: NSImage)],
        warnings: [StormWarning],
        cells: [StormCell],
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

        // Converts a coordinate to the drawing context's bottom-left origin.
        let toImagePoint = { (coordinate: CLLocationCoordinate2D) -> NSPoint in
            let point = snapshot.point(for: coordinate)
            return NSPoint(
                x: point.x,
                y: yIncreasesUpward ? point.y : imageSize.height - point.y
            )
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        mapImage.draw(in: NSRect(origin: .zero, size: imageSize))

        // Composite the tiles into their own layer so close zooms can be
        // smoothed before blending onto the map.
        if let radarLayer = radarLayer(tiles: tiles, zoom: zoom, imageSize: imageSize, toImagePoint: toImagePoint) {
            radarLayer.draw(
                in: NSRect(origin: .zero, size: imageSize),
                from: .zero,
                operation: .sourceOver,
                fraction: Self.radarTileAlpha
            )
        }

        // Outline active warning polygons, least dangerous first so the most
        // dangerous draw on top.
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

        // Arrows showing where tracked storm cells are heading, from the
        // radar's own cell-motion vectors.
        let imageBounds = NSRect(origin: .zero, size: imageSize)
        for cell in cells {
            let origin = toImagePoint(cell.coordinate)
            guard imageBounds.contains(origin) else { continue }

            // drct is the direction the cell moves FROM; the arrow points
            // where it's heading. North is up (+y) in this context.
            let heading = (cell.fromDirectionDegrees + 180) * .pi / 180
            let length = min(26 + cell.speedKnots * 0.6, 60)
            let head = NSPoint(
                x: origin.x + sin(heading) * length,
                y: origin.y + cos(heading) * length
            )

            let arrow = NSBezierPath()
            arrow.lineCapStyle = .round
            arrow.lineJoinStyle = .round
            arrow.move(to: origin)
            arrow.line(to: head)
            for barbOffset in [Double.pi * 5 / 6, -Double.pi * 5 / 6] {
                let barbAngle = heading + barbOffset
                arrow.move(to: head)
                arrow.line(to: NSPoint(
                    x: head.x + sin(barbAngle) * 11,
                    y: head.y + cos(barbAngle) * 11
                ))
            }

            // Dark halo first so the arrow reads over any radar color.
            NSColor.black.withAlphaComponent(0.55).setStroke()
            arrow.lineWidth = 6
            arrow.stroke()
            NSColor.white.setStroke()
            arrow.lineWidth = 2.5
            arrow.stroke()
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
