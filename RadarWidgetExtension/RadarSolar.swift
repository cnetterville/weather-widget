//
//  RadarSolar.swift
//  RadarWidgetExtension
//

import CoreLocation
import Foundation

/// Determines whether it's currently night at a location, so the map can adopt
/// a dark appearance after sunset. Computed locally with the NOAA solar
/// position formulas — no network, works anywhere.
enum SolarTime {
    /// Whether the sun is below the horizon at the coordinate right now.
    static func isNight(at coordinate: CLLocationCoordinate2D, date: Date = Date()) -> Bool {
        elevationDegrees(at: coordinate, date: date) <= 0
    }

    /// The sun's altitude above the horizon, in degrees (negative below).
    static func elevationDegrees(at coordinate: CLLocationCoordinate2D, date: Date) -> Double {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let components = calendar.dateComponents(
            [.dayOfYear, .hour, .minute, .second], from: date
        )
        let dayOfYear = Double(components.dayOfYear ?? 1)
        let hour = Double(components.hour ?? 0)
        let minute = Double(components.minute ?? 0)
        let second = Double(components.second ?? 0)

        // Fractional year, radians.
        let gamma = 2 * .pi / 365 * (dayOfYear - 1 + (hour - 12) / 24)

        // Equation of time (minutes) and solar declination (radians).
        let eqTime = 229.18 * (0.000075
            + 0.001868 * cos(gamma) - 0.032077 * sin(gamma)
            - 0.014615 * cos(2 * gamma) - 0.040849 * sin(2 * gamma))
        let declination = 0.006918
            - 0.399912 * cos(gamma) + 0.070257 * sin(gamma)
            - 0.006758 * cos(2 * gamma) + 0.000907 * sin(2 * gamma)
            - 0.002697 * cos(3 * gamma) + 0.00148 * sin(3 * gamma)

        // True solar time in minutes (UTC, longitude east-positive).
        let minutesUTC = hour * 60 + minute + second / 60
        let trueSolarTime = minutesUTC + eqTime + 4 * coordinate.longitude
        // Hour angle, degrees then radians.
        let hourAngle = (trueSolarTime / 4 - 180) * .pi / 180

        let latitude = coordinate.latitude * .pi / 180
        let cosZenith = sin(latitude) * sin(declination)
            + cos(latitude) * cos(declination) * cos(hourAngle)
        let zenith = acos(min(max(cosZenith, -1), 1))
        return 90 - zenith * 180 / .pi
    }
}
