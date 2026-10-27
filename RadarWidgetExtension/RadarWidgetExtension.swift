//
//  RadarWidgetExtension.swift
//  RadarWidgetExtension
//
//  Created by Curtis Netterville on 8/7/26.
//

import AppIntents
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
        .description("Live precipitation radar for a location you choose.")
        .supportedFamilies([.systemMedium, .systemLarge, .systemExtraLarge])
        .contentMarginsDisabled()
    }
}

struct RadarWidgetEntryView: View {
    var entry: RadarEntry
    @Environment(\.widgetFamily) private var family

    /// The medium widget is short, so it gets a pared-down caption.
    private var isCompact: Bool { family == .systemMedium }
    private var inset: CGFloat { isCompact ? 8 : 12 }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topTrailing) {
                // Nothing to refresh while the first render is still loading.
                if entry.image != nil || entry.errorMessage != nil {
                    refreshButton
                        .padding(inset)
                }
            }
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
                        // Keep clear of the refresh button.
                        .padding(.trailing, 32)
                }
                Spacer()
                HStack {
                    caption
                    Spacer()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(inset)
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

    private var refreshButton: some View {
        Button(intent: RefreshRadarIntent()) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(.black.opacity(0.35), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Refresh Radar")
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.locationName)
                .font(isCompact ? .subheadline.bold() : .headline)
            if isCompact {
                compactDetail
            } else {
                if let rainChance = entry.rainChance {
                    Label("\(rainChance)% chance of rain for the rest of today", systemImage: "umbrella.fill")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.9))
                }
                if let arrival = entry.tropicalWindArrival {
                    Label("Tropical storm winds ~\(arrival)", systemImage: "wind")
                        .font(.caption.bold())
                        .foregroundStyle(.orange)
                }
                // Only worth the space when rain is actually plausible soon.
                if entry.hourlyRain.max() ?? 0 >= 10 {
                    hourlyRainStrip
                }
            }
            radarTimeLine
                // Dims while a refresh is in flight.
                .invalidatableContent()
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.6), radius: 1)
        .padding(.horizontal, isCompact ? 8 : 10)
        .padding(.vertical, isCompact ? 4 : 6)
        // A light translucent tint rather than a material: widget snapshots
        // render materials as nearly opaque, hiding radar under the caption.
        .background(.black.opacity(0.3), in: RoundedRectangle(cornerRadius: isCompact ? 8 : 10))
    }

    /// The medium widget's single detail line, most pressing first: an
    /// inbound tropical storm, then rain in the next few hours, then the
    /// chance for the rest of the day.
    @ViewBuilder
    private var compactDetail: some View {
        if let arrival = entry.tropicalWindArrival {
            Label("TS winds ~\(arrival)", systemImage: "wind")
                .font(.caption2.bold())
                .foregroundStyle(.orange)
        } else if let soon = rainSoon, soon.chance >= 30 {
            Label(soon.summary, systemImage: "cloud.rain.fill")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.9))
        } else if let rainChance = entry.rainChance {
            Label("\(rainChance)% rain rest of today", systemImage: "umbrella.fill")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.9))
        }
    }

    /// When the radar is from, turning orange once it can't be trusted to
    /// be current: either the last refresh failed, or the radar has aged.
    @ViewBuilder
    private var radarTimeLine: some View {
        switch entry.freshness {
        case .current:
            if let radarTime = entry.radarTime {
                Text("Radar as of \(radarTime, style: .time)")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.75))
            }
        case .old, .notUpdated:
            Label {
                staleText
            } icon: {
                Image(systemName: "clock.badge.exclamationmark")
            }
            .font(.caption2.bold())
            .foregroundStyle(.orange)
        }
    }

    private var staleText: Text {
        let failed = entry.freshness == .notUpdated
        guard let radarTime = entry.radarTime else {
            return Text("Couldn’t update radar")
        }
        switch (failed, isCompact) {
        case (true, true):
            return Text("Not updated · \(radarTime, style: .time)")
        case (true, false):
            return Text("Couldn’t update · radar from \(radarTime, style: .time)")
        case (false, true):
            return Text("Out of date · \(radarTime, style: .time)")
        case (false, false):
            return Text("Radar from \(radarTime, style: .time) may be out of date")
        }
    }

    /// The next few hours' peak rain chance and when it arrives, worded
    /// like "Rain likely ~5 PM (60%)". Nil when no hour reaches 10%.
    private var rainSoon: (summary: String, chance: Int)? {
        let hours = Array(entry.hourlyRain.prefix(6))
        guard let peak = hours.max(), peak >= 10,
              let index = hours.firstIndex(of: peak)
        else { return nil }
        let likelihood = switch peak {
        case 50...: "Rain likely"
        case 30...: "Rain possible"
        default: "Slight chance of rain"
        }
        // The first hour is the current one.
        let when = if index == 0 {
            "now"
        } else if let start = entry.hourlyRainStart {
            "~" + start.addingTimeInterval(Double(index) * 3600).formatted(.dateTime.hour())
        } else {
            "in \(index) hr"
        }
        return ("\(likelihood) \(when) (\(peak)%)", peak)
    }

    /// A tiny bar chart of the next few hours' precipitation chance under a
    /// one-line summary, so you can see at a glance whether rain is imminent.
    private var hourlyRainStrip: some View {
        let hours = Array(entry.hourlyRain.prefix(6))
        let barWidth: CGFloat = 7
        let barSpacing: CGFloat = 3
        // Size the chart to the tallest bar so low chances don't leave a big
        // empty gap between this strip and the radar timestamp below it.
        let chartHeight = max(2, CGFloat(hours.max() ?? 0) / 100 * 16)
        return VStack(alignment: .leading, spacing: 2) {
            if let soon = rainSoon {
                Text(soon.summary)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.85))
            }
            HStack(alignment: .bottom, spacing: barSpacing) {
                ForEach(Array(hours.enumerated()), id: \.offset) { _, chance in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.cyan.opacity(0.35 + Double(chance) / 100 * 0.6))
                        .frame(width: barWidth, height: max(2, CGFloat(chance) / 100 * 16))
                }
            }
            .frame(height: chartHeight, alignment: .bottom)
            // Ends of the time axis: this hour and the last bar's hour.
            HStack(spacing: 0) {
                Text("Now")
                Spacer(minLength: 4)
                if let start = entry.hourlyRainStart, hours.count > 1 {
                    Text(start.addingTimeInterval(Double(hours.count - 1) * 3600), format: .dateTime.hour())
                } else {
                    Text("+\(max(hours.count - 1, 0))h")
                }
            }
            .font(.system(size: 8, weight: .medium))
            .foregroundStyle(.white.opacity(0.6))
            .frame(width: CGFloat(hours.count) * (barWidth + barSpacing) - barSpacing, alignment: .leading)
        }
    }

    private func warningBadge(_ title: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(isCompact ? .caption.bold() : .callout.bold())
            if isCompact {
                // No room for the detail line; the ring still marks "here".
                Text(title)
                    .font(.caption.bold())
                    .lineLimit(1)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(.caption.bold())
                    Text(warningDetail)
                        .font(.caption2.weight(.medium))
                        .opacity(0.85)
                }
            }
        }
        .foregroundStyle(badgeTextColor)
        .padding(.horizontal, isCompact ? 8 : 10)
        .padding(.vertical, isCompact ? 4 : 5)
        .background(badgeColor, in: RoundedRectangle(cornerRadius: 10))
        // A warning covering the location itself gets a white ring so it
        // reads as more urgent than one elsewhere on the map.
        .overlay {
            if entry.warningCoversLocation {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(.white, lineWidth: 2)
            }
        }
    }

    /// "In effect here until 4:15 PM" or "Nearby until Thu 7:30 PM" — flood
    /// warnings often run for days, so a later day is named.
    private var warningDetail: String {
        let place = entry.warningCoversLocation ? "In effect here" : "Nearby"
        guard let expires = entry.warningExpires else { return place }
        let format: Date.FormatStyle = Calendar.current.isDateInToday(expires)
            ? .dateTime.hour().minute()
            : .dateTime.weekday(.abbreviated).hour().minute()
        return "\(place) until \(expires.formatted(format))"
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
