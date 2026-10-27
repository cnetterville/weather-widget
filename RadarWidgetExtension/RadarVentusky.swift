//
//  RadarVentusky.swift
//  RadarWidgetExtension
//

import AppKit
import CoreLocation
import WebKit

/// Where a Ventusky map shows a region, and how to place coordinates on it.
///
/// Ventusky's `?p=latitude;longitude;zoom` URL centers a Web Mercator map
/// whose world is 512 × 2^zoom CSS pixels wide. Only whole zooms load the
/// base map (fractional ones show radar over a blank background), so the
/// viewport is sized to fit the requested span at the next whole zoom in,
/// and the capture is scaled down to the widget's size.
struct VentuskyViewport {
    let center: CLLocationCoordinate2D
    let zoom: Int
    /// The page's size in CSS pixels.
    let cssSize: CGSize

    static let zoomRange = 2...11

    init(center: CLLocationCoordinate2D, latitudeSpan: Double, displaySize: CGSize) {
        self.center = center
        // The span's height in world pixels at zoom 0, then the smallest
        // whole zoom where it's at least as tall as the widget. That keeps
        // the page between 1x and 2x the widget's size, so map labels end up
        // between full and half size once scaled down.
        let north = min(center.latitude + latitudeSpan / 2, 85)
        let south = max(center.latitude - latitudeSpan / 2, -85)
        let heightAtZoom0 = Self.worldY(latitude: south, zoom: 0) - Self.worldY(latitude: north, zoom: 0)
        let ideal = Int(log2(Double(displaySize.height) / max(heightAtZoom0, 1e-9)).rounded(.up))
        zoom = min(max(ideal, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        let height = heightAtZoom0 * pow(2, Double(zoom))
        let aspect = displaySize.width / max(displaySize.height, 1)
        cssSize = CGSize(width: (height * aspect).rounded(), height: height.rounded())
    }

    var url: URL? {
        URL(string: String(
            format: "https://www.ventusky.com/?p=%.4f;%.4f;%d&l=radar",
            center.latitude, center.longitude, zoom
        ))
    }

    static func worldX(longitude: Double, zoom: Int) -> Double {
        (longitude + 180) / 360 * 512 * pow(2, Double(zoom))
    }

    static func worldY(latitude: Double, zoom: Int) -> Double {
        let radians = latitude * .pi / 180
        return (1 - log(tan(radians) + 1 / cos(radians)) / .pi) / 2 * 512 * pow(2, Double(zoom))
    }

    /// Where a coordinate falls in an image of `imageSize` captured from
    /// this viewport, with a bottom-left origin to match AppKit drawing.
    func imagePoint(for coordinate: CLLocationCoordinate2D, imageSize: CGSize) -> NSPoint {
        let dx = Self.worldX(longitude: coordinate.longitude, zoom: zoom)
            - Self.worldX(longitude: center.longitude, zoom: zoom)
        let dy = Self.worldY(latitude: coordinate.latitude, zoom: zoom)
            - Self.worldY(latitude: center.latitude, zoom: zoom)
        let scale = imageSize.width / cssSize.width
        return NSPoint(
            x: imageSize.width / 2 + dx * scale,
            y: imageSize.height / 2 - dy * scale
        )
    }
}

/// Loads Ventusky's radar map in an off-screen web view and captures it.
/// Ventusky has no tile API, so — as in the Weather Station App — the page
/// itself is shown, with the site's controls hidden and radar smoothing on.
@MainActor
final class VentuskySnapshotter: NSObject, WKNavigationDelegate {
    /// Hides Ventusky's timeline bars, layer-name pill (#i), logo
    /// (#logo/#header), search/menu buttons (menu) and webcam/fronts toggles
    /// (#d/#p). The site's minified names; may need updating if it changes.
    /// Kept in step with the Weather Station App's VentuskyRadarView.
    private static let hiddenElementsCSS = "#date,#hour,.jz,.rc,#i,#logo,#header,menu,#d,#p{display:none !important}"

    /// The page finishes loading in about half a second, but its radar and
    /// map tiles keep drawing after that; coastlines and terrain can take
    /// several seconds more at wide zooms.
    private static let settleTime: Duration = .seconds(6)
    private static let loadTimeout: Duration = .seconds(10)

    private var loadContinuation: CheckedContinuation<Bool, Never>?

    /// The map for the viewport, drawn at `pixelSize`, or nil if the page
    /// didn't load or couldn't be captured.
    static func capture(_ viewport: VentuskyViewport, pixelSize: CGSize) async -> NSImage? {
        guard let url = viewport.url else { return nil }
        return await VentuskySnapshotter().capture(url: url, cssSize: viewport.cssSize, pixelSize: pixelSize)
    }

    private func capture(url: URL, cssSize: CGSize, pixelSize: CGSize) async -> NSImage? {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(WKUserScript(
            source: """
            var style = document.createElement('style');
            style.textContent = '\(Self.hiddenElementsCSS)';
            document.documentElement.appendChild(style);
            // Ventusky keeps its "interpolation" setting in localStorage; at
            // "0" the radar draws as blocky grid cells. Force smoothing on
            // before the site's scripts read it.
            try { localStorage.setItem('interpolation', '1'); } catch (e) {}
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        // No window: the page lays out and draws (WebGL included) without
        // one, and a widget extension shouldn't be opening windows.
        let webView = WKWebView(frame: CGRect(origin: .zero, size: cssSize), configuration: configuration)
        webView.navigationDelegate = self
        defer { webView.stopLoading() }

        let timeout = Task { [weak self] in
            try? await Task.sleep(for: Self.loadTimeout)
            self?.finishLoading(false)
        }
        let loaded = await withCheckedContinuation { continuation in
            loadContinuation = continuation
            webView.load(URLRequest(url: url))
        }
        timeout.cancel()
        guard loaded else { return nil }

        try? await Task.sleep(for: Self.settleTime)
        guard let snapshot = try? await webView.takeSnapshot(configuration: nil) else { return nil }
        return Self.resized(snapshot, to: pixelSize)
    }

    private func finishLoading(_ loaded: Bool) {
        guard let continuation = loadContinuation else { return }
        loadContinuation = nil
        continuation.resume(returning: loaded)
    }

    /// Redraws the capture at exactly the render size, one image point per
    /// pixel like the MapKit snapshot path, so overlays line up the same way.
    private static func resized(_ image: NSImage, to pixelSize: CGSize) -> NSImage? {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(pixelSize.width),
            pixelsHigh: Int(pixelSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap)
        else { return nil }
        bitmap.size = pixelSize
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: pixelSize))
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        let result = NSImage(size: pixelSize)
        result.addRepresentation(bitmap)
        return result
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishLoading(true)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishLoading(false)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        finishLoading(false)
    }
}
