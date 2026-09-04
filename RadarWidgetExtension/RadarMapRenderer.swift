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
    let showsClouds: Bool
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
        /// NHC's most likely arrival time of tropical-storm-force winds at the
        /// widget's location, like "Sat 2 am", when a storm is inbound.
        let tropicalWindArrival: String?
    }

    func render() async throws -> Result {
        let snapshot = try await takeSnapshot()
        async let warningsTask = StormWarningFeed.activeWarnings()
        async let cellsTask = StormCellFeed.activeCells()
        async let cyclonesTask = TropicalCycloneFeed.activeCyclones(
            near: region.center,
            spanDegrees: region.span.latitudeDelta
        )

        // Radar being briefly unreachable shouldn't blank the widget; with no
        // layer or tiles, draw() still produces the map with the location dot.
        var tiles: [(tile: TileCoordinate, image: NSImage)] = []
        var zoom = 0
        let layer = await tileLayer()
        if let layer {
            zoom = tileZoom(for: layer)
            tiles = await fetchTileImages(tiles: tileRange(zoom: zoom), zoom: zoom, layer: layer)
        }

        var cloudTiles: [(tile: TileCoordinate, image: NSImage)] = []
        var cloudZoom = 0
        if showsClouds, let clouds = cloudLayer() {
            cloudZoom = tileZoom(for: clouds)
            cloudTiles = await fetchTileImages(tiles: tileRange(zoom: cloudZoom), zoom: cloudZoom, layer: clouds)
        }

        // Snow overlay only applies to the US source's coverage area.
        var snowImage: NSImage?
        if radarSource == .nexrad {
            snowImage = await snowOverlay()
        }

        let visibleWarnings = visible(warnings: await warningsTask)
        let visibleCells = visible(cells: await cellsTask)
        let visibleCyclones = visible(cyclones: await cyclonesTask)

        let composited = draw(
            tiles: tiles,
            cloudTiles: cloudTiles,
            snowImage: snowImage,
            warnings: visibleWarnings,
            cells: visibleCells,
            cyclones: visibleCyclones,
            zoom: zoom,
            cloudZoom: cloudZoom,
            over: snapshot
        )
        let radarTime = tiles.isEmpty ? nil : layer?.time
        let topWarning = StormWarning.priority
            .compactMap { code in visibleWarnings.first { $0.phenomena == code } }
            .first
        let arrival = visibleCyclones
            .compactMap { $0.windArrival(at: coordinate) }
            .first
        return Result(
            image: composited,
            radarTime: radarTime,
            topWarning: topWarning,
            tropicalWindArrival: arrival
        )
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
            .sorted {
                // Hazard-flagged cells always make the cut before strong ones.
                if $0.isFlagged != $1.isFlagged {
                    return $0.isFlagged
                }
                return $0.maxDBZ > $1.maxDBZ
            }
            .prefix(10)
            .map { $0 }
    }

    /// Cyclones whose forecast cone overlaps the rendered area (same margin
    /// used for tile coverage).
    private func visible(cyclones: [TropicalCyclone]) -> [TropicalCyclone] {
        let center = region.center
        let span = region.span
        return cyclones.filter {
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
        // After sunset, render the vector map dark so it reads as night and the
        // radar stands out. Satellite imagery is unaffected by appearance.
        if mapStyle != .satellite, SolarTime.isNight(at: coordinate) {
            options.appearance = NSAppearance(named: .darkAqua)
        }
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
        /// GIBS-style services order the path {z}/{y}/{x}.
        var swapsXY = false

        func url(zoom: Int, x: Int, y: Int) -> URL? {
            let path = swapsXY ? "\(zoom)/\(y)/\(x)" : "\(zoom)/\(x)/\(y)"
            return URL(string: "\(urlPrefix)/\(path)\(urlSuffix)")
        }
    }

    /// NASA GIBS GeoColor imagery from whichever GOES satellite best views
    /// the area (day: true color; night: infrared). Nil outside GOES
    /// coverage of the Americas.
    private func cloudLayer() -> TileLayer? {
        guard (-170.0...(-20.0)).contains(coordinate.longitude), abs(coordinate.latitude) < 60 else {
            return nil
        }
        let satellite = coordinate.longitude < -105 ? "GOES-West_ABI_GeoColor" : "GOES-East_ABI_GeoColor"
        return TileLayer(
            time: nil,
            tileSize: 256,
            zoomRange: 1...7,
            urlPrefix: "https://gibs.earthdata.nasa.gov/wmts/epsg3857/best/\(satellite)/default/default/GoogleMapsCompatible_Level7",
            urlSuffix: ".png",
            swapsXY: true
        )
    }

    private func tileLayer() async -> TileLayer? {
        switch radarSource {
        case .nexrad:
            // IEM's MRMS Hybrid Scan Reflectivity mosaic (q2-hsr): a
            // quality-controlled US composite that suppresses ground clutter
            // and anomalous propagation, unlike the raw base-reflectivity
            // (n0q) product. Regenerated about every 2 minutes.
            return TileLayer(
                time: await Self.nexradTimestamp(),
                tileSize: 256,
                zoomRange: 2...12,
                urlPrefix: "https://mesonet.agron.iastate.edu/cache/tile.py/1.0.0/q2-hsr-900913",
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

    // MARK: - Winter precipitation type

    /// The geographic bounds the overlays cover: the requested region plus the
    /// same margin used for tile coverage.
    private var coverageBounds: (
        minLatitude: Double, maxLatitude: Double,
        minLongitude: Double, maxLongitude: Double
    ) {
        let center = region.center
        let span = region.span
        return (
            max(center.latitude - span.latitudeDelta * 0.7, -85),
            min(center.latitude + span.latitudeDelta * 0.7, 85),
            center.longitude - span.longitudeDelta * 0.7,
            center.longitude + span.longitudeDelta * 0.7
        )
    }

    /// MRMS surface precipitation type from the NWS map server, reduced to just
    /// the snow category and recolored pale blue-white, so frozen precipitation
    /// reads differently from rain. Nil outside CONUS, on any failure, or —
    /// most of the year — when nothing in view is snow.
    private func snowOverlay() async -> NSImage? {
        let bounds = coverageBounds
        // The product covers CONUS only; skip the fetch entirely elsewhere.
        guard bounds.maxLatitude > 21, bounds.minLatitude < 53,
              bounds.maxLongitude > -128, bounds.minLongitude < -65
        else { return nil }

        // Web Mercator meters, matching both the WMS request and the snapshot.
        func mercator(_ latitude: Double, _ longitude: Double) -> (x: Double, y: Double) {
            let r = 20_037_508.342789244
            let x = longitude * r / 180
            let y = log(tan((90 + latitude) * .pi / 360)) / .pi * r
            return (x, y)
        }
        let southWest = mercator(bounds.minLatitude, bounds.minLongitude)
        let northEast = mercator(bounds.maxLatitude, bounds.maxLongitude)

        // Half the snapshot resolution is still finer than the ~1 km data grid.
        let width = Int(size.width / 2)
        let height = Int(size.height / 2)
        var components = URLComponents(
            string: "https://opengeo.ncep.noaa.gov/geoserver/conus/conus_pcpn_typ/ows"
        )!
        components.queryItems = [
            URLQueryItem(name: "service", value: "WMS"),
            URLQueryItem(name: "version", value: "1.3.0"),
            URLQueryItem(name: "request", value: "GetMap"),
            URLQueryItem(name: "layers", value: "conus_pcpn_typ"),
            URLQueryItem(name: "crs", value: "EPSG:3857"),
            URLQueryItem(
                name: "bbox",
                value: "\(southWest.x),\(southWest.y),\(northEast.x),\(northEast.y)"
            ),
            URLQueryItem(name: "width", value: "\(width)"),
            URLQueryItem(name: "height", value: "\(height)"),
            URLQueryItem(name: "format", value: "image/png"),
            URLQueryItem(name: "transparent", value: "true"),
        ]
        guard let url = components.url,
              let (data, response) = try? await RadarNetwork.session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let image = NSImage(data: data)
        else { return nil }
        return Self.snowPixels(in: image)
    }

    /// Keeps only the snow category of the MRMS precipitation-type palette
    /// (a fixed gray, rendered without antialiasing) and recolors it. Returns
    /// nil when the image contains no snow at all.
    private static func snowPixels(in image: NSImage) -> NSImage? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.bitmapData,
              bitmap.samplesPerPixel == 4, bitmap.bitsPerSample == 8
        else { return nil }
        var snowPixelCount = 0
        for row in 0..<bitmap.pixelsHigh {
            let rowStart = row * bitmap.bytesPerRow
            for column in 0..<bitmap.pixelsWide {
                let offset = rowStart + column * 4
                let red = data[offset], green = data[offset + 1], blue = data[offset + 2]
                let alpha = data[offset + 3]
                // Snow in this palette is exactly (200, 200, 200); allow a
                // little tolerance for PNG round-trips.
                if alpha > 0,
                   (197...203).contains(red), (197...203).contains(green),
                   (197...203).contains(blue) {
                    data[offset] = 235
                    data[offset + 1] = 245
                    data[offset + 2] = 255
                    data[offset + 3] = 255
                    snowPixelCount += 1
                } else {
                    data[offset + 3] = 0
                }
            }
        }
        guard snowPixelCount > 0 else { return nil }
        let result = NSImage(size: image.size)
        result.addRepresentation(bitmap)
        return result
    }

    private struct TileServices: Decodable {
        struct Service: Decodable {
            let id: String
            let utc_valid: String
        }
        let services: [Service]
    }

    /// Generation time of the current MRMS mosaic. The exact product time comes
    /// from NCEP's SeamlessHSR directory listing (the newest file is the frame
    /// IEM tiles are built from); if that's unreachable, fall back to IEM's n0q
    /// index, which regenerates on the same pipeline within a couple of
    /// minutes. Purely informational — the overlay works without it.
    private static func nexradTimestamp() async -> Date? {
        if let exact = await mrmsProductTime() {
            return exact
        }
        return await n0qCompositeTime()
    }

    private static func mrmsProductTime() async -> Date? {
        let url = URL(string: "https://mrms.ncep.noaa.gov/2D/SeamlessHSR/?C=M;O=D")!
        guard let (data, _) = try? await RadarNetwork.session.data(from: url),
              let listing = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        // File names look like SeamlessHSR_00.00_20260904-231600; the largest
        // stamp is the newest product regardless of listing order.
        let pattern = /SeamlessHSR_00\.00_(\d{8})-(\d{6})/
        guard let newest = listing.matches(of: pattern).map({ "\($0.1)\($0.2)" }).max()
        else {
            return nil
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMddHHmmss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.date(from: newest)
    }

    private static func n0qCompositeTime() async -> Date? {
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

    /// Draws centered white text with a dark halo, nudged to stay on-screen.
    private func drawLabel(_ text: String, at point: NSPoint, imageBounds: NSRect) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let shadow = NSShadow()
        shadow.shadowColor = .black
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = .zero
        let string = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph,
            .shadow: shadow,
        ])
        let size = string.size()
        var origin = NSPoint(x: point.x - size.width / 2, y: point.y - size.height)
        origin.x = min(max(origin.x, 4), imageBounds.maxX - size.width - 4)
        origin.y = min(max(origin.y, 4), imageBounds.maxY - size.height - 4)
        string.draw(at: origin)
    }

    private func draw(
        tiles: [(tile: TileCoordinate, image: NSImage)],
        cloudTiles: [(tile: TileCoordinate, image: NSImage)],
        snowImage: NSImage?,
        warnings: [StormWarning],
        cells: [StormCell],
        cyclones: [TropicalCyclone],
        zoom: Int,
        cloudZoom: Int,
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
        let imageBounds = NSRect(origin: .zero, size: imageSize)

        // Semi-transparent satellite imagery under the radar, so cloud cover
        // shows on dry days without hiding the map.
        for (tile, image) in cloudTiles {
            let northWest = toImagePoint(Self.tileNorthWestCorner(x: tile.x, y: tile.y, zoom: cloudZoom))
            let southEast = toImagePoint(Self.tileNorthWestCorner(x: tile.x + 1, y: tile.y + 1, zoom: cloudZoom))
            let rect = NSRect(
                x: min(northWest.x, southEast.x),
                y: min(northWest.y, southEast.y),
                width: abs(southEast.x - northWest.x),
                height: abs(southEast.y - northWest.y)
            )
            guard rect.intersects(imageBounds) else { continue }
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.5)
        }

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

        // Where MRMS flags the precipitation as snow, tint it pale blue-white
        // over the reflectivity so winter precipitation reads at a glance.
        // Semi-transparent so intensity still shows through.
        if let snowImage {
            let bounds = coverageBounds
            let northWest = toImagePoint(CLLocationCoordinate2D(
                latitude: bounds.maxLatitude, longitude: bounds.minLongitude
            ))
            let southEast = toImagePoint(CLLocationCoordinate2D(
                latitude: bounds.minLatitude, longitude: bounds.maxLongitude
            ))
            let rect = NSRect(
                x: min(northWest.x, southEast.x),
                y: min(northWest.y, southEast.y),
                width: abs(southEast.x - northWest.x),
                height: abs(southEast.y - northWest.y)
            )
            snowImage.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.7)
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

        // Hurricane forecast cones: a translucent white "cone of uncertainty"
        // with a dashed edge, the colored forecast track through it, and a
        // marker at the current center. Drawn over radar but under the local
        // cell markers so nearby storm detail stays legible.
        for cyclone in cyclones {
            for ring in cyclone.coneRings where ring.count > 2 {
                let path = NSBezierPath()
                path.move(to: toImagePoint(ring[0]))
                for coordinate in ring.dropFirst() {
                    path.line(to: toImagePoint(coordinate))
                }
                path.close()
                NSColor.white.withAlphaComponent(0.16).setFill()
                path.fill()
                NSColor.white.withAlphaComponent(0.8).setStroke()
                path.lineWidth = 2
                path.setLineDash([6, 4], count: 2, phase: 0)
                path.stroke()
            }

            let trackPoints = cyclone.track.map(toImagePoint)
            if trackPoints.count > 1 {
                let line = NSBezierPath()
                line.move(to: trackPoints[0])
                for point in trackPoints.dropFirst() {
                    line.line(to: point)
                }
                NSColor.black.withAlphaComponent(0.5).setStroke()
                line.lineWidth = 5
                line.stroke()
                cyclone.color.setStroke()
                line.lineWidth = 2.5
                line.stroke()
            }

            // Coastal watch/warning segments in NHC's standard colors, thick
            // enough to read as highlighted coastline.
            for segment in cyclone.watchWarnings where segment.points.count > 1 {
                let line = NSBezierPath()
                line.lineCapStyle = .round
                line.move(to: toImagePoint(segment.points[0]))
                for coordinate in segment.points.dropFirst() {
                    line.line(to: toImagePoint(coordinate))
                }
                NSColor.black.withAlphaComponent(0.5).setStroke()
                line.lineWidth = 8
                line.stroke()
                segment.color.setStroke()
                line.lineWidth = 5
                line.stroke()
            }
        }

        // Arrows showing where tracked storm cells are heading, from the
        // radar's own cell-motion vectors.
        for cell in cells {
            let origin = toImagePoint(cell.coordinate)
            guard imageBounds.contains(origin), cell.isMoving else { continue }

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

        // Hazard markers from the radar's cell signatures, drawn over the
        // arrows: red inverted triangle for a tornado vortex signature,
        // orange ring for a mesocyclone, cyan diamond for likely hail.
        for cell in cells {
            let origin = toImagePoint(cell.coordinate)
            guard imageBounds.contains(origin) else { continue }

            if cell.hasTornadoSignature {
                let triangle = NSBezierPath()
                triangle.move(to: NSPoint(x: origin.x - 9, y: origin.y + 8))
                triangle.line(to: NSPoint(x: origin.x + 9, y: origin.y + 8))
                triangle.line(to: NSPoint(x: origin.x, y: origin.y - 10))
                triangle.close()
                NSColor.systemRed.setFill()
                triangle.fill()
                NSColor.white.setStroke()
                triangle.lineWidth = 2
                triangle.stroke()
            } else if cell.hasMesocyclone {
                let ring = NSBezierPath(ovalIn: NSRect(x: origin.x - 11, y: origin.y - 11, width: 22, height: 22))
                NSColor.black.withAlphaComponent(0.55).setStroke()
                ring.lineWidth = 5.5
                ring.stroke()
                NSColor.systemOrange.setStroke()
                ring.lineWidth = 3
                ring.stroke()
            }

            if cell.hasHailIndicator {
                // Offset right so it doesn't sit on a rotation marker.
                let center = NSPoint(x: origin.x + 16, y: origin.y)
                let diamond = NSBezierPath()
                diamond.move(to: NSPoint(x: center.x, y: center.y + 8))
                diamond.line(to: NSPoint(x: center.x + 7, y: center.y))
                diamond.line(to: NSPoint(x: center.x, y: center.y - 8))
                diamond.line(to: NSPoint(x: center.x - 7, y: center.y))
                diamond.close()
                NSColor.systemCyan.setFill()
                diamond.fill()
                NSColor.black.withAlphaComponent(0.7).setStroke()
                diamond.lineWidth = 1.5
                diamond.stroke()
            }
        }

        // Mark each cyclone's current center with a hurricane glyph and label.
        for cyclone in cyclones {
            let center = toImagePoint(cyclone.center)
            guard imageBounds.contains(center) else { continue }

            let configuration = NSImage.SymbolConfiguration(pointSize: 24, weight: .bold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [cyclone.color]))
            if let glyph = NSImage(systemSymbolName: "hurricane", accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration) {
                let size = glyph.size
                let dark = NSBezierPath(ovalIn: NSRect(
                    x: center.x - size.width / 2 - 3,
                    y: center.y - size.height / 2 - 3,
                    width: size.width + 6,
                    height: size.height + 6
                ))
                NSColor.black.withAlphaComponent(0.45).setFill()
                dark.fill()
                glyph.draw(
                    in: NSRect(
                        x: center.x - size.width / 2,
                        y: center.y - size.height / 2,
                        width: size.width,
                        height: size.height
                    ),
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1
                )
            }

            drawLabel(
                "\(cyclone.name) · \(cyclone.summary)",
                at: NSPoint(x: center.x, y: center.y - 20),
                imageBounds: imageBounds
            )
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
