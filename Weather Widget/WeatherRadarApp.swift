//
//  WeatherRadarApp.swift
//  Weather Radar
//
//  Created by Curtis Netterville on 8/7/26.
//

import CoreLocation
import Observation
import SwiftUI
import WidgetKit

/// Requests location permission on the widget's behalf and keeps every
/// radar widget in sync with the result. Widgets can't show the
/// authorization prompt themselves; the containing app has to. The manager
/// lives as long as the app so the prompt isn't dismissed early.
///
/// Rebuilding and reinstalling from Xcode can re-sign the app with a new
/// identity, which sometimes orphans its old entry in System Settings —
/// if location access mysteriously stops working during development, a
/// fresh reinstall (not just a rebuild) usually fixes it.
@Observable
final class LocationPermission: NSObject, CLLocationManagerDelegate {
    static let shared = LocationPermission()

    private let manager = CLLocationManager()
    private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined

    override init() {
        super.init()
        manager.delegate = self
    }

    /// No-op beyond making sure `manager.delegate` is already attached —
    /// the real work happens in `locationManagerDidChangeAuthorization`.
    /// Kept as an explicit call site so construction is deferred until the
    /// window is up (macOS can ignore authorization requests made before
    /// the app is active).
    func requestIfNeeded() {}

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        // CLLocationManager reports the real authorization status here as
        // soon as a delegate is attached. Reading `manager.authorizationStatus`
        // synchronously right after construction instead (as this used to)
        // races the XPC connection to locationd — on an identity that's
        // never talked to locationd before (a freshly signed build's very
        // first launch), that read can lose the race, return something
        // other than `.notDetermined`, and silently skip the request with
        // no prompt, no error, and no entry ever appearing in System
        // Settings. Doing the check here instead, as Apple's own sample
        // code does, avoids that.
        authorizationStatus = manager.authorizationStatus
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        // The widget only re-checks authorization on its next timeline
        // refresh (as infrequently as every 5 minutes); reload now so a
        // freshly granted "Use My Current Location" takes effect right away.
        WidgetCenter.shared.reloadAllTimelines()
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
