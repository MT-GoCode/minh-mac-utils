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

    /// True if (lat,lon) is inside this zone. `accuracy` (meters) widens a circle so a
    /// fuzzy fix near the edge isn't a false "outside".
    func contains(lat: Double, lon: Double, accuracy: Double) -> Bool {
        switch shape {
        case .circle(let clat, let clon, let r):
            let here = CLLocation(latitude: lat, longitude: lon)
            let center = CLLocation(latitude: clat, longitude: clon)
            return here.distance(from: center) <= r + max(accuracy, 0)
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
    static func load(from path: String = Paths.zonesFile) -> [Zone] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return [] }
        return (try? JSONDecoder().decode([Zone].self, from: data)) ?? []
    }

    static func save(_ zones: [Zone], to path: String = Paths.zonesFile) throws {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(zones).write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// Names of all zones containing the point.
    static func containing(lat: Double, lon: Double, accuracy: Double, zones: [Zone]) -> [String] {
        zones.filter { $0.contains(lat: lat, lon: lon, accuracy: accuracy) }.map(\.name)
    }

    static func hasZone(named name: String, in zones: [Zone]) -> Bool {
        zones.contains { $0.name == name }
    }
}
