import Foundation
import simd

/// The built-in dot globe: land dots on a sphere, lit by the real sun, with
/// markers. Pure math here; GizmoUI draws it.
public struct GlobeMarker: Sendable, Equatable, Codable {
    public var lat: Double
    public var lon: Double
    public var color: String?
    public var pulse: Bool
    public var label: String?

    public init(lat: Double, lon: Double, color: String? = nil, pulse: Bool = false, label: String? = nil) {
        self.lat = lat
        self.lon = lon
        self.color = color
        self.pulse = pulse
        self.label = label
    }
}

public enum GlobeMath {
    /// Land dots as (lat, lon) in degrees, every `step` cells of the 4° mask
    /// (1 in a popover, 2 on the bar). Longitudes thin out toward the poles
    /// so dots stay evenly spaced.
    public static func landDots(step: Int = 1) -> [SIMD2<Double>] {
        var out: [SIMD2<Double>] = []
        let rows = LandMask.rows
        for (r, row) in rows.enumerated() where r % step == 0 {
            let lat = 88.0 - 4.0 * Double(r)
            let chars = Array(row)
            let thin = max(1, Int((1 / max(cos(lat * .pi / 180), 0.15)).rounded())) * step
            for c in stride(from: 0, to: chars.count, by: thin) where chars[c] == "#" {
                out.append(SIMD2(lat, -178.0 + 4.0 * Double(c)))
            }
        }
        return out
    }

    /// Unit vector for a point on the globe (y up, z toward the viewer at lon 0).
    public static func vector(lat: Double, lon: Double) -> SIMD3<Double> {
        let φ = lat * .pi / 180, λ = lon * .pi / 180
        return SIMD3(cos(φ) * sin(λ), sin(φ), cos(φ) * cos(λ))
    }

    /// Projects onto the disc: x/y in -1...1 (y up), `z` > 0 when facing
    /// the viewer. `centerLon` is the longitude facing the viewer and `tilt`
    /// leans the north pole toward the viewer, in degrees.
    public static func project(lat: Double, lon: Double, centerLon: Double, tilt: Double = 18) -> SIMD3<Double> {
        let v = vector(lat: lat, lon: lon - centerLon)
        let t = tilt * .pi / 180
        // Rotate about the x axis.
        let y = v.y * cos(t) - v.z * sin(t)
        let z = v.y * sin(t) + v.z * cos(t)
        return SIMD3(v.x, y, z)
    }

    /// The subsolar point (where the sun is overhead) at `date`, from the
    /// NOAA low-precision formulas; good to about a degree.
    public static func subsolarPoint(at date: Date) -> (lat: Double, lon: Double) {
        let jd = date.timeIntervalSince1970 / 86400 + 2440587.5
        let n = jd - 2451545.0
        let L = (280.460 + 0.9856474 * n).truncatingRemainder(dividingBy: 360)
        let g = (357.528 + 0.9856003 * n).truncatingRemainder(dividingBy: 360) * .pi / 180
        let λ = (L + 1.915 * sin(g) + 0.020 * sin(2 * g)) * .pi / 180
        let ε = (23.439 - 0.0000004 * n) * .pi / 180
        let decl = asin(sin(ε) * sin(λ)) * 180 / .pi
        // Equation of time (minutes) from right ascension.
        let ra = atan2(cos(ε) * sin(λ), cos(λ)) * 180 / .pi
        var eot = (L - ra).truncatingRemainder(dividingBy: 360)
        if eot > 180 { eot -= 360 }
        if eot < -180 { eot += 360 }
        let utcHours = (date.timeIntervalSince1970.truncatingRemainder(dividingBy: 86400)) / 3600
        var lon = -15 * (utcHours - 12 + eot * 4 / 60)
        lon = (lon + 540).truncatingRemainder(dividingBy: 360) - 180
        return (decl, lon)
    }

    /// 1 in full daylight, 0 at night, with a soft terminator.
    public static func daylight(lat: Double, lon: Double, sun: (lat: Double, lon: Double)) -> Double {
        let d = simd_dot(vector(lat: lat, lon: lon), vector(lat: sun.lat, lon: sun.lon))
        return min(max((d + 0.1) / 0.2, 0), 1)
    }

    /// Where a few common time zones are, for clock markers.
    public static let zoneCoordinates: [String: (lat: Double, lon: Double)] = [
        "America/New_York": (40.7, -74.0), "America/Chicago": (41.9, -87.6), "America/Denver": (39.7, -105.0),
        "America/Los_Angeles": (34.1, -118.2), "America/Toronto": (43.7, -79.4), "America/Mexico_City": (19.4, -99.1),
        "America/Sao_Paulo": (-23.6, -46.6), "America/Buenos_Aires": (-34.6, -58.4), "America/Bogota": (4.7, -74.1),
        "Europe/London": (51.5, -0.1), "Europe/Paris": (48.9, 2.4), "Europe/Berlin": (52.5, 13.4), "Europe/Madrid": (40.4, -3.7),
        "Europe/Rome": (41.9, 12.5), "Europe/Amsterdam": (52.4, 4.9), "Europe/Stockholm": (59.3, 18.1), "Europe/Moscow": (55.8, 37.6),
        "Europe/Istanbul": (41.0, 29.0), "Africa/Addis_Ababa": (9.0, 38.7), "Africa/Nairobi": (-1.3, 36.8), "Africa/Lagos": (6.5, 3.4),
        "Africa/Cairo": (30.0, 31.2), "Africa/Johannesburg": (-26.2, 28.0), "Asia/Dubai": (25.2, 55.3), "Asia/Kolkata": (22.6, 88.4),
        "Asia/Singapore": (1.35, 103.8), "Asia/Shanghai": (31.2, 121.5), "Asia/Hong_Kong": (22.3, 114.2), "Asia/Tokyo": (35.7, 139.7),
        "Asia/Seoul": (37.6, 127.0), "Australia/Sydney": (-33.9, 151.2), "Australia/Melbourne": (-37.8, 145.0),
        "Pacific/Auckland": (-36.8, 174.8), "Pacific/Honolulu": (21.3, -157.9), "UTC": (51.5, 0.0), "GMT": (51.5, 0.0),
    ]
}
