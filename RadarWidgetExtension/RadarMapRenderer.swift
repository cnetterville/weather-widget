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
    /// The widget's size in points.
    let displaySize: CGSize
    /// Image pixels per widget point. Overlay sizes below are in points and
    /// multiplied by this, so they look the same at any render scale.
    let scale: CGFloat

    private static let radarTileAlpha: CGFloat = 0.7
    /// Opacity of the thickest clouds; thinner ones scale down from this.
    private static let cloudMaxAlpha = 0.6
    /// Luminance where satellite pixels start to count as cloud, and where
    /// they're fully cloud. Bright desert falls in this range too but is
    /// told apart by its color (see `cloudLayer`); snow cover can't be and
    /// shows as cloud, much as it does on the satellite image itself.
    private static let cloudLuminanceRange = 0.35...0.75
    private static let maximumTileCount = 48
    private static let locationDotRadius: CGFloat = 3.5
    private static let locationDotRingWidth: CGFloat = 1.5

    /// The rendered image size, in pixels.
    private var size: CGSize {
        CGSize(width: displaySize.width * scale, height: displaySize.height * scale)
    }

    struct Result {
        let image: NSImage
        let radarTime: Date?
        /// The warning to badge: the most dangerous one covering the
        /// widget's location, or failing that, the most dangerous in view.
        let topWarning: StormWarning?
        /// Whether `topWarning` covers the widget's location itself.
        let warningCoversLocation: Bool
        /// NHC's most likely arrival time of tropical-storm-force winds at the
        /// widget's location, like "Sat 2 am", when a storm is inbound.
        let tropicalWindArrival: String?
    }

    func render() async throws -> Result {
        // Ventusky draws its own map and radar; if its page can't be
        // captured, fall back to the Apple map with RainViewer radar.
        if radarSource == .ventusky, let result = await renderVentusky() {
            return result
        }
        return try await renderMapKit()
    }

    /// Apple Maps snapshot with radar, cloud and snow tiles composited on.
    private func renderMapKit() async throws -> Result {
        // Every source is fetched at once. WidgetKit gives a render a short
        // budget, and each request can take seconds on a slow network, so
        // waiting on them one after another risks running out of time.
        async let snapshotTask = takeSnapshot()
        async let radarTask = radarTiles()
        async let cloudTask = cloudTiles()
        async let snowTask = snowOverlay()
        async let warningsTask = StormWarningFeed.activeWarnings()
        async let cellsTask = StormCellFeed.activeCells()
        async let cyclonesTask = TropicalCycloneFeed.activeCyclones(
            near: region.center,
            spanDegrees: region.span.latitudeDelta
        )

        let snapshot = try await snapshotTask
        let radar = await radarTask
        let visibleWarnings = visible(warnings: await warningsTask)
        let visibleCyclones = visible(cyclones: await cyclonesTask)

        let composited = draw(
            radar: radar.tiles,
            clouds: await cloudTask,
            snowImage: await snowTask,
            warnings: visibleWarnings,
            cells: visible(cells: await cellsTask),
            cyclones: visibleCyclones,
            over: mapBase(for: snapshot)
        )
        return result(image: composited, radarTime: radar.time, warnings: visibleWarnings, cyclones: visibleCyclones)
    }

    /// Ventusky's map, which already includes its radar, with the warning,
    /// storm and location overlays drawn on top. Nil if the page couldn't
    /// be loaded or captured in time.
    private func renderVentusky() async -> Result? {
        async let warningsTask = StormWarningFeed.activeWarnings()
        async let cellsTask = StormCellFeed.activeCells()
        async let cyclonesTask = TropicalCycloneFeed.activeCyclones(
            near: region.center,
            spanDegrees: region.span.latitudeDelta
        )
        let viewport = VentuskyViewport(center: coordinate, latitudeSpan: latitudeSpan, displaySize: displaySize)
        guard let image = await VentuskySnapshotter.capture(viewport, pixelSize: size) else { return nil }

        let visibleWarnings = visible(warnings: await warningsTask)
        let visibleCyclones = visible(cyclones: await cyclonesTask)
        let composited = draw(
            radar: TileSet(),
            clouds: TileSet(),
            snowImage: nil,
            warnings: visibleWarnings,
            cells: visible(cells: await cellsTask),
            cyclones: visibleCyclones,
            over: MapBase(image: image) { viewport.imagePoint(for: $0, imageSize: image.size) }
        )
        // Ventusky's page doesn't expose its radar frame time, so there's
        // none to show (or flag as old).
        return result(image: composited, radarTime: nil, warnings: visibleWarnings, cyclones: visibleCyclones)
    }

    private func result(
        image: NSImage,
        radarTime: Date?,
        warnings: [StormWarning],
        cyclones: [TropicalCyclone]
    ) -> Result {
        let badge = topWarning(in: warnings)
        let arrival = cyclones
            .compactMap { $0.windArrival(at: coordinate) }
            .first
        return Result(
            image: image,
            radarTime: radarTime,
            topWarning: badge?.warning,
            warningCoversLocation: badge?.coversLocation ?? false,
            tropicalWindArrival: arrival
        )
    }

    /// The most dangerous warning covering the widget's location, or failing
    /// that, the most dangerous one in view.
    private func topWarning(in warnings: [StormWarning]) -> (warning: StormWarning, coversLocation: Bool)? {
        let local = warnings.filter { $0.contains(coordinate) }
        for (candidates, coversLocation) in [(local, true), (warnings, false)] {
            for code in StormWarning.priority {
                if let warning = candidates.first(where: { $0.phenomena == code }) {
                    return (warning, coversLocation)
                }
            }
        }
        return nil
    }

    /// Warnings that overlap the rendered area (with the same margin used
    /// for tile coverage).
    private func visible(warnings: [StormWarning]) -> [StormWarning] {
        let bounds = coverageBounds
        return warnings.filter { $0.intersects(bounds) }
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
        let bounds = coverageBounds
        return cyclones.filter { $0.intersects(bounds) }
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
            tileSize: 256,
            zoomRange: 1...7,
            urlPrefix: "https://gibs.earthdata.nasa.gov/wmts/epsg3857/best/\(satellite)/default/default/GoogleMapsCompatible_Level7",
            urlSuffix: ".png",
            swapsXY: true
        )
    }

    /// IEM's MRMS Hybrid Scan Reflectivity mosaic (q2-hsr): a
    /// quality-controlled US composite that suppresses ground clutter and
    /// anomalous propagation, unlike the raw base-reflectivity (n0q)
    /// product. Regenerated about every 2 minutes.
    private static let nexradLayer = TileLayer(
        tileSize: 256,
        zoomRange: 2...12,
        urlPrefix: "https://mesonet.agron.iastate.edu/cache/tile.py/1.0.0/q2-hsr-900913",
        urlSuffix: ".png"
    )

    /// Tiles fetched for one layer, at the zoom they were fetched for.
    private struct TileSet {
        var tiles: [(tile: TileCoordinate, image: NSImage)] = []
        var zoom = 0
    }

    /// The radar tiles plus the time of the frame they show. Radar being
    /// briefly unreachable shouldn't blank the widget; with no tiles, draw()
    /// still produces the map with the location dot.
    private func radarTiles() async -> (tiles: TileSet, time: Date?) {
        switch radarSource {
        case .nexrad:
            // IEM's tile URLs always serve the newest mosaic, so the
            // timestamp lookup can run alongside the tile downloads.
            async let time = Self.nexradTimestamp()
            let tiles = await fetchTiles(for: Self.nexradLayer)
            return (tiles, tiles.tiles.isEmpty ? nil : await time)
        case .ventusky:
            // Only reached when Ventusky's page can't be captured. RainViewer
            // aggregates national radar networks worldwide. The
            // free API caps tiles at zoom 7, Universal Blue color scheme.
            guard let frame = await Self.rainViewerFrame() else { return (TileSet(), nil) }
            let layer = TileLayer(
                tileSize: 512,
                zoomRange: 2...7,
                urlPrefix: "\(frame.host)\(frame.path)/512",
                urlSuffix: "/2/1_1.png"
            )
            let tiles = await fetchTiles(for: layer)
            return (tiles, tiles.tiles.isEmpty ? nil : frame.time)
        }
    }

    /// Satellite cloud tiles, or none when turned off or out of coverage.
    private func cloudTiles() async -> TileSet {
        guard showsClouds, let layer = cloudLayer() else { return TileSet() }
        return await fetchTiles(for: layer)
    }

    private func fetchTiles(for layer: TileLayer) async -> TileSet {
        let zoom = tileZoom(for: layer)
        let tiles = await fetchTileImages(tiles: tileRange(zoom: zoom), zoom: zoom, layer: layer)
        return TileSet(tiles: tiles, zoom: zoom)
    }

    // MARK: - Winter precipitation type

    /// The geographic bounds the overlays cover: the requested region plus the
    /// same margin used for tile coverage.
    private var coverageBounds: GeoBounds {
        let center = region.center
        let span = region.span
        return GeoBounds(
            minLatitude: max(center.latitude - span.latitudeDelta * 0.7, -85),
            maxLatitude: min(center.latitude + span.latitudeDelta * 0.7, 85),
            minLongitude: center.longitude - span.longitudeDelta * 0.7,
            maxLongitude: center.longitude + span.longitudeDelta * 0.7
        )
    }

    /// MRMS surface precipitation type from the NWS map server, reduced to just
    /// the snow category and recolored pale blue-white, so frozen precipitation
    /// reads differently from rain. Nil outside CONUS, on any failure, or —
    /// most of the year — when nothing in view is snow.
    private func snowOverlay() async -> NSImage? {
        // Only the US radar source shares this product's coverage area.
        guard radarSource == .nexrad else { return nil }
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
    static func snowPixels(in image: NSImage) -> NSImage? {
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

    static func tileIndex(latitude: Double, longitude: Double, zoom: Int) -> (x: Int, y: Int) {
        let n = Double(1 << zoom)
        let x = Int(floor((longitude + 180) / 360 * n))
        let latitudeRadians = latitude * .pi / 180
        let y = Int(floor((1 - log(tan(latitudeRadians) + 1 / cos(latitudeRadians)) / .pi) / 2 * n))
        return (x, y)
    }

    static func tileNorthWestCorner(x: Int, y: Int, zoom: Int) -> CLLocationCoordinate2D {
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

    /// Draws the tiles at full opacity into a transparent bitmap the size
    /// of the snapshot.
    private func tileBitmap(
        tiles: [(tile: TileCoordinate, image: NSImage)],
        zoom: Int,
        imageSize: NSSize,
        toImagePoint: (CLLocationCoordinate2D) -> NSPoint
    ) -> NSBitmapImageRep? {
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
        return bitmap
    }

    /// The radar tiles as one layer, smoothing the ~1 km radar data cells
    /// when they'd read as visible blocks.
    private func radarLayer(
        tiles: [(tile: TileCoordinate, image: NSImage)],
        zoom: Int,
        imageSize: NSSize,
        toImagePoint: (CLLocationCoordinate2D) -> NSPoint
    ) -> NSImage? {
        guard let bitmap = tileBitmap(tiles: tiles, zoom: zoom, imageSize: imageSize, toImagePoint: toImagePoint)
        else { return nil }

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

    /// The satellite tiles reduced to just the clouds. GeoColor imagery
    /// also shows the ground (true color by day, city lights at night), and
    /// laying that over the map tints everything; clouds are the bright,
    /// nearly colorless pixels, so those keep their color and everything
    /// else fades out. At close zooms each satellite pixel covers many
    /// image pixels, so the result is blurred to hide the blocks.
    private func cloudLayer(
        tiles: [(tile: TileCoordinate, image: NSImage)],
        zoom: Int,
        imageSize: NSSize,
        toImagePoint: (CLLocationCoordinate2D) -> NSPoint
    ) -> NSImage? {
        guard let bitmap = tileBitmap(tiles: tiles, zoom: zoom, imageSize: imageSize, toImagePoint: toImagePoint),
            let data = bitmap.bitmapData,
            bitmap.samplesPerPixel == 4, bitmap.bitsPerSample == 8,
            !bitmap.bitmapFormat.contains(.alphaFirst)
        else { return nil }

        func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
            let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
            return t * t * (3 - 2 * t)
        }
        let premultiplied = !bitmap.bitmapFormat.contains(.alphaNonpremultiplied)
        for row in 0..<bitmap.pixelsHigh {
            let rowStart = row * bitmap.bytesPerRow
            for column in 0..<bitmap.pixelsWide {
                let offset = rowStart + column * 4
                let alpha = Double(data[offset + 3]) / 255
                guard alpha > 0 else { continue }
                // Back to straight color to judge it.
                let divisor = premultiplied ? alpha : 1
                let red = Double(data[offset]) / 255 / divisor
                let green = Double(data[offset + 1]) / 255 / divisor
                let blue = Double(data[offset + 2]) / 255 / divisor
                let brightest = max(red, green, blue)
                let luminance = 0.299 * red + 0.587 * green + 0.114 * blue
                let saturation = brightest > 0 ? (brightest - min(red, green, blue)) / brightest : 0
                let cloudiness = smoothstep(Self.cloudLuminanceRange.lowerBound,
                                            Self.cloudLuminanceRange.upperBound, luminance)
                    * (1 - smoothstep(0.12, 0.35, saturation))
                let newAlpha = alpha * cloudiness * Self.cloudMaxAlpha
                let scale = premultiplied ? newAlpha : 1
                data[offset] = UInt8(min(red * scale, 1) * 255)
                data[offset + 1] = UInt8(min(green * scale, 1) * 255)
                data[offset + 2] = UInt8(min(blue * scale, 1) * 255)
                data[offset + 3] = UInt8(newAlpha * 255)
            }
        }

        // Image pixels per 256-pixel-tile satellite pixel at this zoom.
        let degreesPerSourcePixel = 360 / (Double(1 << zoom) * 256)
        let imagePixelsPerDegree = Double(imageSize.width) / region.span.longitudeDelta
        let blurRadius = degreesPerSourcePixel * imagePixelsPerDegree * 0.5
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
        shadow.shadowBlurRadius = 1.5 * scale
        shadow.shadowOffset = .zero
        let string = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 10 * scale, weight: .semibold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph,
            .shadow: shadow,
        ])
        let size = string.size()
        var origin = NSPoint(x: point.x - size.width / 2, y: point.y - size.height)
        let inset = 2 * scale
        origin.x = min(max(origin.x, inset), imageBounds.maxX - size.width - inset)
        origin.y = min(max(origin.y, inset), imageBounds.maxY - size.height - inset)
        string.draw(at: origin)
    }

    /// The map the overlays are drawn on, and where a coordinate falls on
    /// it (bottom-left origin, like the AppKit drawing context).
    private struct MapBase {
        let image: NSImage
        let point: (CLLocationCoordinate2D) -> NSPoint
    }

    private func mapBase(for snapshot: MKMapSnapshotter.Snapshot) -> MapBase {
        let imageSize = snapshot.image.size
        // point(for:) may use a top-left or bottom-left origin depending on
        // platform; calibrate with a coordinate known to be north of center.
        let centerPoint = snapshot.point(for: region.center)
        let northCoordinate = CLLocationCoordinate2D(
            latitude: min(region.center.latitude + region.span.latitudeDelta / 4, 85),
            longitude: region.center.longitude
        )
        let yIncreasesUpward = snapshot.point(for: northCoordinate).y > centerPoint.y
        return MapBase(image: snapshot.image) { coordinate in
            let point = snapshot.point(for: coordinate)
            return NSPoint(
                x: point.x,
                y: yIncreasesUpward ? point.y : imageSize.height - point.y
            )
        }
    }

    private func draw(
        radar: TileSet,
        clouds: TileSet,
        snowImage: NSImage?,
        warnings: [StormWarning],
        cells: [StormCell],
        cyclones: [TropicalCyclone],
        over base: MapBase
    ) -> NSImage {
        let mapImage = base.image
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
        let toImagePoint = base.point

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        mapImage.draw(in: NSRect(origin: .zero, size: imageSize))
        let imageBounds = NSRect(origin: .zero, size: imageSize)

        // Clouds under the radar, so cloud cover shows on dry days without
        // hiding the map. Their translucency is baked into the layer.
        if let cloudLayer = cloudLayer(
            tiles: clouds.tiles, zoom: clouds.zoom, imageSize: imageSize, toImagePoint: toImagePoint
        ) {
            cloudLayer.draw(in: imageBounds, from: .zero, operation: .sourceOver, fraction: 1)
        }

        // Composite the tiles into their own layer so close zooms can be
        // smoothed before blending onto the map.
        if let radarLayer = radarLayer(tiles: radar.tiles, zoom: radar.zoom, imageSize: imageSize, toImagePoint: toImagePoint) {
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
                    path.lineWidth = 2 * scale
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
                path.lineWidth = 1 * scale
                path.setLineDash([3 * scale, 2 * scale], count: 2, phase: 0)
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
                line.lineWidth = 2.5 * scale
                line.stroke()
                cyclone.color.setStroke()
                line.lineWidth = 1.25 * scale
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
                line.lineWidth = 4 * scale
                line.stroke()
                segment.color.setStroke()
                line.lineWidth = 2.5 * scale
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
            let length = min(13 + cell.speedKnots * 0.3, 30) * scale
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
                    x: head.x + sin(barbAngle) * 5.5 * scale,
                    y: head.y + cos(barbAngle) * 5.5 * scale
                ))
            }

            // Dark halo first so the arrow reads over any radar color.
            NSColor.black.withAlphaComponent(0.55).setStroke()
            arrow.lineWidth = 3 * scale
            arrow.stroke()
            NSColor.white.setStroke()
            arrow.lineWidth = 1.25 * scale
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
                triangle.move(to: NSPoint(x: origin.x - 4.5 * scale, y: origin.y + 4 * scale))
                triangle.line(to: NSPoint(x: origin.x + 4.5 * scale, y: origin.y + 4 * scale))
                triangle.line(to: NSPoint(x: origin.x, y: origin.y - 5 * scale))
                triangle.close()
                NSColor.systemRed.setFill()
                triangle.fill()
                NSColor.white.setStroke()
                triangle.lineWidth = 1 * scale
                triangle.stroke()
            } else if cell.hasMesocyclone {
                let radius = 5.5 * scale
                let ring = NSBezierPath(ovalIn: NSRect(
                    x: origin.x - radius, y: origin.y - radius, width: radius * 2, height: radius * 2
                ))
                NSColor.black.withAlphaComponent(0.55).setStroke()
                ring.lineWidth = 2.75 * scale
                ring.stroke()
                NSColor.systemOrange.setStroke()
                ring.lineWidth = 1.5 * scale
                ring.stroke()
            }

            if cell.hasHailIndicator {
                // Offset right so it doesn't sit on a rotation marker.
                let center = NSPoint(x: origin.x + 8 * scale, y: origin.y)
                let diamond = NSBezierPath()
                diamond.move(to: NSPoint(x: center.x, y: center.y + 4 * scale))
                diamond.line(to: NSPoint(x: center.x + 3.5 * scale, y: center.y))
                diamond.line(to: NSPoint(x: center.x, y: center.y - 4 * scale))
                diamond.line(to: NSPoint(x: center.x - 3.5 * scale, y: center.y))
                diamond.close()
                NSColor.systemCyan.setFill()
                diamond.fill()
                NSColor.black.withAlphaComponent(0.7).setStroke()
                diamond.lineWidth = 0.75 * scale
                diamond.stroke()
            }
        }

        // Mark each cyclone's current center with a hurricane glyph and label.
        for cyclone in cyclones {
            let center = toImagePoint(cyclone.center)
            guard imageBounds.contains(center) else { continue }

            let configuration = NSImage.SymbolConfiguration(pointSize: 16 * scale, weight: .bold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [cyclone.color]))
            if let glyph = NSImage(systemSymbolName: "hurricane", accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration) {
                let size = glyph.size
                let pad = 1.5 * scale
                let dark = NSBezierPath(ovalIn: NSRect(
                    x: center.x - size.width / 2 - pad,
                    y: center.y - size.height / 2 - pad,
                    width: size.width + pad * 2,
                    height: size.height + pad * 2
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
                at: NSPoint(x: center.x, y: center.y - 13 * scale),
                imageBounds: imageBounds
            )
        }

        // Mark the configured location with a small white-ringed blue dot.
        let marker = toImagePoint(coordinate)
        let dotRadius = Self.locationDotRadius * scale
        let ringRadius = (Self.locationDotRadius + Self.locationDotRingWidth) * scale
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(
            x: marker.x - ringRadius,
            y: marker.y - ringRadius,
            width: ringRadius * 2,
            height: ringRadius * 2
        )).fill()
        NSColor.systemBlue.setFill()
        NSBezierPath(ovalIn: NSRect(
            x: marker.x - dotRadius,
            y: marker.y - dotRadius,
            width: dotRadius * 2,
            height: dotRadius * 2
        )).fill()

        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        let composited = NSImage(size: imageSize)
        composited.addRepresentation(bitmap)
        return composited
    }
}
