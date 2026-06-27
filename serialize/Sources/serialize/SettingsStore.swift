import Foundation
import Combine

/// The five on-screen placements. Trapezoids float + hide-on-hover; bars reserve space.
enum OverlayPosition: String, CaseIterable, Codable {
    case topNotch, left, right, topBar, bottomBar

    var label: String {
        switch self {
        case .topNotch:  return "Top — around notch"
        case .left:      return "Left edge"
        case .right:     return "Right edge"
        case .topBar:    return "Top bar — reserves space"
        case .bottomBar: return "Bottom bar — reserves space"
        }
    }
    var isBar: Bool { self == .topBar || self == .bottomBar }
    var isTrapezoid: Bool { !isBar }
}

/// Persisted in UserDefaults(suiteName: "com.serialize"). Box size is fully decoupled from font
/// size: width/height of the floating boxes and bar thickness are explicit, so changing the font
/// never reshapes the box. Observable so the SwiftUI overlay + settings update live.
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()
    private let d = UserDefaults(suiteName: "com.serialize") ?? .standard

    // defaults
    enum Def {
        static let taskText = "What am I working on?"
        static let position = OverlayPosition.topNotch
        static let fontSize = 14.0
        static let notchOffset = 25.0      // px down to clear the camera block
        static let notchWidth = 380.0
        static let notchHeight = 72.0
        static let sideWidth = 230.0
        static let sideHeight = 440.0      // tall: text wraps down like a textbox
        static let barThickness = 30.0
        static let gradient = false
        static let gradientBrightness = 0.9   // 0…1.6; >1 lifts luminance past the old fixed cap
    }

    @Published var taskText: String       { didSet { d.set(taskText, forKey: "taskText") } }
    @Published var position: OverlayPosition { didSet { d.set(position.rawValue, forKey: "position") } }
    @Published var fontSize: Double       { didSet { d.set(fontSize, forKey: "fontSize") } }
    @Published var notchOffset: Double    { didSet { d.set(notchOffset, forKey: "notchOffset") } }
    @Published var notchWidth: Double     { didSet { d.set(notchWidth, forKey: "notchWidth") } }
    @Published var notchHeight: Double    { didSet { d.set(notchHeight, forKey: "notchHeight") } }
    @Published var sideWidth: Double      { didSet { d.set(sideWidth, forKey: "sideWidth") } }
    @Published var sideHeight: Double     { didSet { d.set(sideHeight, forKey: "sideHeight") } }
    @Published var barThickness: Double   { didSet { d.set(barThickness, forKey: "barThickness") } }
    @Published var gradient: Bool         { didSet { d.set(gradient, forKey: "gradient") } }
    @Published var gradientBrightness: Double { didSet { d.set(gradientBrightness, forKey: "gradientBrightness") } }

    private init() {
        let dd = UserDefaults(suiteName: "com.serialize") ?? .standard
        func num(_ k: String, _ def: Double) -> Double { dd.object(forKey: k) != nil ? dd.double(forKey: k) : def }
        taskText = dd.string(forKey: "taskText") ?? Def.taskText
        position = OverlayPosition(rawValue: dd.string(forKey: "position") ?? "") ?? Def.position
        fontSize = num("fontSize", Def.fontSize)
        notchOffset = num("notchOffset", Def.notchOffset)
        notchWidth = num("notchWidth", Def.notchWidth)
        notchHeight = num("notchHeight", Def.notchHeight)
        sideWidth = num("sideWidth", Def.sideWidth)
        sideHeight = num("sideHeight", Def.sideHeight)
        barThickness = num("barThickness", Def.barThickness)
        gradient = dd.object(forKey: "gradient") != nil ? dd.bool(forKey: "gradient") : Def.gradient
        gradientBrightness = num("gradientBrightness", Def.gradientBrightness)
    }

    /// Restore every layout setting to its default. Keeps the task text.
    func resetToDefaults() {
        position = Def.position
        fontSize = Def.fontSize
        notchOffset = Def.notchOffset
        notchWidth = Def.notchWidth
        notchHeight = Def.notchHeight
        sideWidth = Def.sideWidth
        sideHeight = Def.sideHeight
        barThickness = Def.barThickness
        gradient = Def.gradient
        gradientBrightness = Def.gradientBrightness
    }
}
