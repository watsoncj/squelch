import Foundation
import CoreLocation

/// Maidenhead grid locator conversion.
enum Maidenhead {
    /// Center coordinate of a 4- or 6-character grid square.
    static func coordinate(forGrid grid: String) -> CLLocationCoordinate2D? {
        let g = Array(grid.uppercased().unicodeScalars.map { Character($0) })
        guard g.count >= 4,
              let f0 = fieldValue(g[0], max: 17), let f1 = fieldValue(g[1], max: 17),
              let d0 = g[2].wholeNumberValue, let d1 = g[3].wholeNumberValue,
              (0...9).contains(d0), (0...9).contains(d1)
        else { return nil }

        var lon = -180.0 + Double(f0) * 20.0 + Double(d0) * 2.0
        var lat = -90.0 + Double(f1) * 10.0 + Double(d1) * 1.0

        if g.count >= 6,
           let s0 = subsquareValue(g[4]), let s1 = subsquareValue(g[5]) {
            lon += Double(s0) * (2.0 / 24.0) + (1.0 / 24.0)
            lat += Double(s1) * (1.0 / 24.0) + (0.5 / 24.0)
        } else {
            lon += 1.0 // center of the 2° x 1° square
            lat += 0.5
        }

        guard (-90.0...90.0).contains(lat), (-180.0...180.0).contains(lon) else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    /// 6-character grid locator for a coordinate.
    static func grid(for coordinate: CLLocationCoordinate2D) -> String {
        let lon = coordinate.longitude + 180.0
        let lat = coordinate.latitude + 90.0
        let a = Int(UnicodeScalar("A").value)
        var out = ""
        out.append(Character(UnicodeScalar(a + Int(lon / 20.0))!))
        out.append(Character(UnicodeScalar(a + Int(lat / 10.0))!))
        out.append(String(Int(lon.truncatingRemainder(dividingBy: 20.0) / 2.0)))
        out.append(String(Int(lat.truncatingRemainder(dividingBy: 10.0) / 1.0)))
        let lonRem = lon.truncatingRemainder(dividingBy: 2.0)
        let latRem = lat.truncatingRemainder(dividingBy: 1.0)
        let aLower = Int(UnicodeScalar("a").value)
        out.append(Character(UnicodeScalar(aLower + Int(lonRem * 12.0))!))
        out.append(Character(UnicodeScalar(aLower + Int(latRem * 24.0))!))
        return out
    }

    /// Initial great-circle bearing, degrees clockwise from true north.
    static func bearingDegrees(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Double {
        let lat1 = from.latitude * .pi / 180
        let lat2 = to.latitude * .pi / 180
        let dLon = (to.longitude - from.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let deg = atan2(y, x) * 180 / .pi
        return (deg + 360).truncatingRemainder(dividingBy: 360)
    }

    static func isValidGrid(_ s: String) -> Bool {
        guard s.count == 4 || s.count == 6 else { return false }
        return coordinate(forGrid: s) != nil && s.uppercased() != "RR73"
    }

    private static func fieldValue(_ c: Character, max: Int) -> Int? {
        guard let scalar = c.unicodeScalars.first else { return nil }
        let v = Int(scalar.value) - Int(UnicodeScalar("A").value)
        return (0...max).contains(v) ? v : nil
    }

    private static func subsquareValue(_ c: Character) -> Int? {
        guard let scalar = c.unicodeScalars.first else { return nil }
        let lower = Character(String(c).lowercased())
        guard let ls = lower.unicodeScalars.first else { return nil }
        _ = scalar
        let v = Int(ls.value) - Int(UnicodeScalar("a").value)
        return (0...23).contains(v) ? v : nil
    }
}
