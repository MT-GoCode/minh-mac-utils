import CoreLocation
import Foundation

struct Coord: Codable, Equatable { var lat: Double; var lon: Double }

/// A named zone is either a circle (center + radius in meters) or a simple polygon.
enum ZoneShape: Codable, Equatable {
    case circle(centerLat: Double, centerLon: Double, radius: Double)
    case polygon(points: [Coord])
}

struct Zone: Codable, Equatable {
    var name: String
    var shape: ZoneShape

    /// True if (lat,lon) is inside this zone — EXACT geometry, no fuzz. We deliberately
    /// do NOT widen the circle by the fix's accuracy: widening is fail-OPEN (it grants a
    /// halo of access around every zone whenever the fix is uncertain). Fix *quality* is
    /// gated upstream in the enforcer instead — a too-fuzzy or stale fix is rejected as
    /// "unknown" → fail-closed, never silently expanded into an allow.
    func contains(lat: Double, lon: Double) -> Bool {
        switch shape {
        case .circle(let clat, let clon, let r):
            let here = CLLocation(latitude: lat, longitude: lon)
            let center = CLLocation(latitude: clat, longitude: clon)
            return here.distance(from: center) <= r
        case .polygon(let pts):
            return Zone.pointInPolygon(lat: lat, lon: lon, points: pts)
        }
    }

    /// Ray-casting point-in-polygon (works for any simple polygon). lon=x, lat=y.
    static func pointInPolygon(lat: Double, lon: Double, points: [Coord]) -> Bool {
        guard points.count >= 3 else { return false }
        var inside = false
        var j = points.count - 1
        for i in 0..<points.count {
            let xi = points[i].lon, yi = points[i].lat
            let xj = points[j].lon, yj = points[j].lat
            if ((yi > lat) != (yj > lat)) &&
               (lon < (xj - xi) * (lat - yi) / (yj - yi) + xi) {
                inside.toggle()
            }
            j = i
        }
        return inside
    }
}

enum ZoneStore {
    static func load(from path: String = Paths.zonesFile) -> [Zone] { loadJSON(path) ?? [] }

    /// Names of all zones containing the point (exact geometry).
    static func containing(lat: Double, lon: Double, zones: [Zone]) -> [String] {
        zones.filter { $0.contains(lat: lat, lon: lon) }.map(\.name)
    }

    static func hasZone(named name: String, in zones: [Zone]) -> Bool {
        zones.contains { $0.name == name }
    }
}
