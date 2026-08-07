//
//  RadarConfiguration.swift
//  RadarWidgetExtension
//

import AppIntents
import WidgetKit

/// How much area the radar map covers, expressed as the latitude span of the
/// visible region.
enum RadarZoomLevel: String, AppEnum {
    case city
    case metro
    case regional
    case state

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        "Zoom Level"
    }

    static var caseDisplayRepresentations: [RadarZoomLevel: DisplayRepresentation] {
        [
            .city: "City (~25 mi)",
            .metro: "Metro (~60 mi)",
            .regional: "Regional (~150 mi)",
            .state: "State (~350 mi)",
        ]
    }

    /// Approximate north-south span of the visible map, in degrees of latitude.
    var latitudeSpan: Double {
        switch self {
        case .city: 0.35
        case .metro: 0.9
        case .regional: 2.2
        case .state: 5.0
        }
    }
}

/// The user-editable options shown when someone edits the radar widget.
struct RadarConfigurationIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource { "Radar Area" }
    static var description: IntentDescription {
        IntentDescription("Choose the area shown on the radar map.")
    }

    @Parameter(title: "Location", default: "New York, NY")
    var location: String

    @Parameter(title: "Zoom", default: .regional)
    var zoom: RadarZoomLevel
}
