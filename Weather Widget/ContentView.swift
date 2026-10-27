//
//  ContentView.swift
//  Weather Radar
//
//  Created by Curtis Netterville on 8/7/26.
//

import CoreLocation
import SwiftUI

struct ContentView: View {
    private var locationPermission = LocationPermission.shared
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "cloud.rain.fill")
                .font(.system(size: 56))
                .foregroundStyle(.tint)

            Text("Weather Radar")
                .font(.title)
                .fontWeight(.semibold)

            Text("This app provides a desktop radar widget — everything happens in the widget itself.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            locationStatusRow

            VStack(alignment: .leading, spacing: 10) {
                instructionRow(number: 1, text: "Right-click the desktop and choose “Edit Widgets…”")
                instructionRow(number: 2, text: "Find “Weather Radar” and add the Medium, Large, or Extra Large widget.")
                instructionRow(number: 3, text: "Right-click the widget and choose “Edit Weather Radar” to pick your location and zoom level.")
                instructionRow(number: 4, text: "To follow your current location instead, allow location access when this app asks, then turn on “Use My Current Location” in the widget’s settings.")
            }
            .padding()
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        }
        .padding(32)
        .frame(minWidth: 460, minHeight: 380)
    }

    /// Surfaces the app's current location authorization so a denial (or a
    /// stuck "Not Determined" from a stale build) is visible here instead of
    /// only showing up as a mysteriously non-functional widget toggle.
    private var locationStatusRow: some View {
        HStack(spacing: 8) {
            Image(systemName: statusIcon)
                .foregroundStyle(statusColor)
            Text(statusText)
                .font(.callout)
                .foregroundStyle(.secondary)
            if showsSettingsButton {
                Button("Open Location Settings") {
                    guard let url = URL(
                        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices"
                    ) else { return }
                    openURL(url)
                }
                .font(.callout)
                .buttonStyle(.link)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(statusColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    private var statusText: String {
        switch locationPermission.authorizationStatus {
        case .notDetermined:
            "Location access hasn’t been requested yet."
        case .denied:
            "Location access denied — “Use My Current Location” won’t work."
        case .restricted:
            "Location access is restricted on this Mac."
        case .authorizedAlways, .authorizedWhenInUse:
            "Location access granted."
        default:
            "Location access status unknown."
        }
    }

    private var statusIcon: String {
        switch locationPermission.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            "checkmark.circle.fill"
        case .notDetermined:
            "questionmark.circle.fill"
        default:
            "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch locationPermission.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            .green
        case .notDetermined:
            .secondary
        default:
            .orange
        }
    }

    private var showsSettingsButton: Bool {
        switch locationPermission.authorizationStatus {
        case .denied, .restricted:
            true
        default:
            false
        }
    }

    private func instructionRow(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.callout.bold())
                .frame(width: 24, height: 24)
                .background(.tint, in: Circle())
                .foregroundStyle(.white)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#Preview {
    ContentView()
}
