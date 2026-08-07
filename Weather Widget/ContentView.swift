//
//  ContentView.swift
//  Weather Widget
//
//  Created by Curtis Netterville on 8/7/26.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "cloud.rain.fill")
                .font(.system(size: 56))
                .foregroundStyle(.tint)

            Text("Weather Radar Widget")
                .font(.title)
                .fontWeight(.semibold)

            Text("This app provides a desktop radar widget — everything happens in the widget itself.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 10) {
                instructionRow(number: 1, text: "Right-click the desktop and choose “Edit Widgets…”")
                instructionRow(number: 2, text: "Find “Weather Radar” and add the Large or Extra Large widget.")
                instructionRow(number: 3, text: "Right-click the widget and choose “Edit Weather Radar” to pick your location and zoom level.")
            }
            .padding()
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        }
        .padding(32)
        .frame(minWidth: 460, minHeight: 380)
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
