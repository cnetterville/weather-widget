//
//  RadarWidgetExtension.swift
//  RadarWidgetExtension
//
//  Created by Curtis Netterville on 8/7/26.
//

import SwiftUI
import WidgetKit

struct RadarWidget: Widget {
    let kind = "RadarWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: RadarConfigurationIntent.self,
            provider: RadarProvider()
        ) { entry in
            RadarWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Weather Radar")
        .description("Live NEXRAD precipitation radar for a US area you choose.")
        .supportedFamilies([.systemLarge, .systemExtraLarge])
        .contentMarginsDisabled()
    }
}

struct RadarWidgetEntryView: View {
    var entry: RadarEntry

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .containerBackground(for: .widget) {
                background
            }
    }

    @ViewBuilder
    private var content: some View {
        if entry.image != nil {
            VStack(alignment: .leading) {
                if let warningTitle = entry.warningTitle {
                    warningBadge(warningTitle)
                }
                Spacer()
                HStack {
                    caption
                    Spacer()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        } else if let message = entry.errorMessage {
            statusView(systemImage: "exclamationmark.triangle", title: "Radar Unavailable", message: message)
        } else {
            statusView(systemImage: "cloud.rain", title: "Weather Radar", message: "Loading radar…")
        }
    }

    @ViewBuilder
    private var background: some View {
        if let image = entry.image {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
        } else {
            LinearGradient(
                colors: [Color(red: 0.09, green: 0.15, blue: 0.27), Color(red: 0.13, green: 0.23, blue: 0.38)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.locationName)
                .font(.headline)
            if let rainChance = entry.rainChance {
                Label("\(rainChance)% chance of rain today", systemImage: "umbrella.fill")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.9))
            }
            if !entry.hourlyRain.isEmpty {
                hourlyRainStrip
            }
            if let radarTime = entry.radarTime {
                Text("Radar as of \(radarTime, style: .time)")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.6), radius: 1)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        // A light translucent tint rather than a material: widget snapshots
        // render materials as nearly opaque, hiding radar under the caption.
        .background(.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
    }

    /// A tiny bar chart of the next few hours' precipitation chance, so you can
    /// see at a glance whether rain is imminent.
    private var hourlyRainStrip: some View {
        let hours = Array(entry.hourlyRain.prefix(6))
        return VStack(alignment: .leading, spacing: 2) {
            Text("Rain next \(hours.count) hrs")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.7))
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(hours.enumerated()), id: \.offset) { _, chance in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.cyan.opacity(0.35 + Double(chance) / 100 * 0.6))
                        .frame(width: 5, height: max(2, CGFloat(chance) / 100 * 16))
                }
            }
            .frame(height: 16, alignment: .bottom)
        }
    }

    private func warningBadge(_ title: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(title)
        }
        .font(.caption.bold())
        .foregroundStyle(badgeTextColor)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(badgeColor, in: Capsule())
    }

    private var badgeColor: Color {
        switch entry.warningCode {
        case "TO": .red
        case "SV": .yellow
        case "FF": .green
        case "MA": .purple
        case "FA", "FL": .teal
        default: .orange
        }
    }

    private var badgeTextColor: Color {
        // Dark text on the light badge colors, white on the dark ones.
        switch entry.warningCode {
        case "SV", "FF", "FA", "FL": .black
        default: .white
        }
    }

    private func statusView(systemImage: String, title: String, message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 36))
                .foregroundStyle(.white.opacity(0.85))
            Text(title)
                .font(.headline)
                .foregroundStyle(.white)
            Text(message)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}

#Preview(as: .systemLarge) {
    RadarWidget()
} timeline: {
    RadarEntry.placeholder()
}
