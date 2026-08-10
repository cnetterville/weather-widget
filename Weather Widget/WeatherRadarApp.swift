//
//  WeatherRadarApp.swift
//  Weather Radar
//
//  Created by Curtis Netterville on 8/7/26.
//

import CoreLocation
import SwiftUI
import WidgetKit

/// Requests location permission on the widget's behalf. Widgets can't show
/// the authorization prompt themselves; the containing app has to. The
/// manager lives as long as the app so the prompt isn't dismissed early.
final class LocationPermission {
    static let shared = LocationPermission()
    private let manager = CLLocationManager()

    func requestIfNeeded() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }
}

@main
struct WeatherRadarApp: App {
    init() {
        // Launching the app refreshes every radar widget immediately, so
        // configuration or code changes show up without waiting for the
        // next scheduled timeline reload.
        WidgetCenter.shared.reloadAllTimelines()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear {
                    // Deferred until the window is up: macOS can ignore
                    // authorization requests made before the app is active.
                    LocationPermission.shared.requestIfNeeded()
                }
        }
    }
}
