//
//  SnowOverlayTests.swift
//  Weather WidgetTests
//

import AppKit
import Testing

struct SnowOverlayTests {
    /// A 2x2 RGBA image with the given pixels, row by row.
    private func image(_ pixels: [[UInt8]]) -> NSImage {
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        for (index, pixel) in pixels.enumerated() {
            let offset = (index / 2) * bitmap.bytesPerRow + (index % 2) * 4
            for channel in 0..<4 {
                bitmap.bitmapData![offset + channel] = pixel[channel]
            }
        }
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.addRepresentation(bitmap)
        return image
    }

    private func pixel(_ image: NSImage, _ index: Int) -> [UInt8] {
        let bitmap = image.representations.compactMap { $0 as? NSBitmapImageRep }.first!
        let offset = (index / 2) * bitmap.bytesPerRow + (index % 2) * 4
        return (0..<4).map { bitmap.bitmapData![offset + $0] }
    }

    @Test func keepsOnlySnowAndRecolorsIt() throws {
        let snow: [UInt8] = [200, 200, 200, 255]
        let rain: [UInt8] = [0, 160, 0, 255]
        let result = try #require(RadarMapRenderer.snowPixels(in: image([snow, rain, rain, [199, 201, 200, 255]])))
        #expect(pixel(result, 0) == [235, 245, 255, 255])
        #expect(pixel(result, 1)[3] == 0)
        #expect(pixel(result, 2)[3] == 0)
        // Within the PNG round-trip tolerance, still snow.
        #expect(pixel(result, 3) == [235, 245, 255, 255])
    }

    @Test func nilWhenNothingIsSnow() {
        let rain: [UInt8] = [0, 160, 0, 255]
        let clear: [UInt8] = [200, 200, 200, 0]
        #expect(RadarMapRenderer.snowPixels(in: image([rain, rain, clear, [180, 180, 180, 255]])) == nil)
    }
}
