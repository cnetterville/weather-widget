//
//  RadarEntryCache.swift
//  RadarWidgetExtension
//

import AppKit
import CryptoKit
import Foundation

/// Persists the last successful render per widget configuration so a network
/// hiccup shows slightly stale radar instead of an error screen.
enum RadarEntryCache {
    struct Metadata: Codable {
        let savedAt: Date
        let radarTime: Date?
        let locationName: String
        let rainChance: Int?
        let warningTitle: String?
        let warningCode: String?
    }

    /// Ignore cached renders older than this — very old radar is worse
    /// than an honest error.
    static let maxAge: TimeInterval = 90 * 60

    private static var directory: URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        else { return nil }
        let directory = caches.appendingPathComponent("RadarCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// A stable key for one widget configuration and size.
    static func key(for configuration: RadarConfigurationIntent, displaySize: CGSize) -> String {
        let components = [
            configuration.useCurrentLocation ? "current-location" : configuration.location,
            configuration.zoom.rawValue,
            configuration.mapStyle.rawValue,
            "\(Int(displaySize.width))x\(Int(displaySize.height))",
        ]
        let digest = SHA256.hash(data: Data(components.joined(separator: "|").utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(24).lowercased()
    }

    static func save(image: NSImage, metadata: Metadata, key: String) {
        guard let directory,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]),
              let meta = try? JSONEncoder().encode(metadata)
        else { return }
        try? png.write(to: directory.appendingPathComponent("\(key).png"))
        try? meta.write(to: directory.appendingPathComponent("\(key).json"))
    }

    static func load(key: String) -> (image: NSImage, metadata: Metadata)? {
        guard let directory,
              let meta = try? Data(contentsOf: directory.appendingPathComponent("\(key).json")),
              let metadata = try? JSONDecoder().decode(Metadata.self, from: meta),
              Date().timeIntervalSince(metadata.savedAt) < maxAge,
              let image = NSImage(contentsOf: directory.appendingPathComponent("\(key).png"))
        else { return nil }
        return (image, metadata)
    }
}
