//
//  RadarRefreshIntent.swift
//  RadarWidgetExtension
//

import AppIntents

/// Runs from the widget's refresh button. WidgetKit reloads the widget's
/// timeline after an interactive intent finishes, which fetches fresh radar,
/// so there's nothing to do here beyond returning.
struct RefreshRadarIntent: AppIntent {
    static var title: LocalizedStringResource { "Refresh Radar" }
    static var description: IntentDescription {
        IntentDescription("Reloads the radar map with the latest data.")
    }
    // Only meaningful from the widget, not Shortcuts or Spotlight.
    static var isDiscoverable: Bool { false }

    func perform() async throws -> some IntentResult {
        .result()
    }
}
