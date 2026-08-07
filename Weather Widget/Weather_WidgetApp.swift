//
//  Weather_WidgetApp.swift
//  Weather Widget
//
//  Created by Curtis Netterville on 8/7/26.
//

import SwiftUI
import WidgetKit

@main
struct Weather_WidgetApp: App {
    init() {
        // Launching the app refreshes every radar widget immediately, so
        // configuration or code changes show up without waiting for the
        // next scheduled timeline reload.
        WidgetCenter.shared.reloadAllTimelines()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
