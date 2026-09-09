import AppKit
import CoreLocation
import Foundation
import MapKit

// One program for viewing + managing zones. Runs as your user (root has no Location).
// Adding a zone LOOSENS the policy → escalates via the admin prompt.
// Deleting a zone can LOOSEN the policy (a name used under NOT) → gated like adding: admin now, or delayed.
// No in-place modification of existing zones.

private enum DrawMode { case idle, circle, polygon }

// MARK: - map subclass: double-click drops a point (and doesn't zoom) while drawing

final class DrawMapView: MKMapView {
    /// Return true to consume the double-click (drawing); false to let the map zoom.
    var onDoubleClick: ((CLLocationCoordinate2D) -> Bool)?
    override func mouseDown(with e: NSEvent) {
        if e.clickCount == 2, let h = onDoubleClick {
            let coord = convert(convert(e.locationInWindow, from: nil), toCoordinateFrom: self)
            if h(coord) { return }
        }
        super.mouseDown(with: e)
    }
}

// MARK: - a visible vertex dot for in-progress polygons

final class VertexView: MKAnnotationView {
    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = NSRect(x: 0, y: 0, width: 13, height: 13)
        wantsLayer = true
        layer?.backgroundColor = NSColor.systemBlue.cgColor
        layer?.cornerRadius = 6.5
        layer?.borderColor = NSColor.white.cgColor
        layer?.borderWidth = 2
    }
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - controller

final class ZonesController: NSObject, NSApplicationDelegate, MKMapViewDelegate,
                              NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private var window: NSWindow!
    private var map: DrawMapView!
    private var table: NSTableView!
    private var search: NSSearchField!
    private var nameField: NSTextField!
    private var radiusSlider: NSSlider!
    private var radiusLabel: NSTextField!
    private var instr: NSTextField!
    private var saveButton: NSButton!
    private var cancelButton: NSButton!

    private var zones: [Zone] = []
    private var mode: DrawMode = .idle
    private var circleCenter: CLLocationCoordinate2D?
    private var polyVerts: [CLLocationCoordinate2D] = []

    func applicationDidFinishLaunching(_ n: Notification) {
        zones = ZoneStore.load()
        let w: CGFloat = 1120, h: CGFloat = 760, side: CGFloat = 256, bar: CGFloat = 72
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.center(); window.title = "Demonlock — zones"
        let content = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))

        // ---- map (right of sidebar, below the toolbar) ----
        map = DrawMapView(frame: NSRect(x: side, y: 0, width: w - side, height: h - bar))
        map.autoresizingMask = [.width, .height]
        map.delegate = self
        map.showsUserLocation = true
        map.onDoubleClick = { [weak self] c in self?.handleDoubleClick(c) ?? false }
        content.addSubview(map)

        // ---- toolbar over the map ----
        let toolbar = NSView(frame: NSRect(x: side, y: h - bar, width: w - side, height: bar))
        toolbar.autoresizingMask = [.width, .minYMargin]
        toolbar.wantsLayer = true; toolbar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        let addCircle = button("+ Circle", NSRect(x: 12, y: bar - 34, width: 92, height: 26), #selector(startCircle))
        let addPoly = button("+ Polygon", NSRect(x: 110, y: bar - 34, width: 96, height: 26), #selector(startPolygon))
        nameField = NSTextField(frame: NSRect(x: 218, y: bar - 34, width: 200, height: 26))
        nameField.placeholderString = "new zone name"
        radiusSlider = NSSlider(value: 100, minValue: 20, maxValue: 3000, target: self, action: #selector(radiusChanged))
        radiusSlider.frame = NSRect(x: 426, y: bar - 33, width: 130, height: 24); radiusSlider.isHidden = true
        radiusLabel = label(NSRect(x: 562, y: bar - 32, width: 80, height: 20), ""); radiusLabel.isHidden = true
        saveButton = button("Save zone", NSRect(x: 12, y: 8, width: 110, height: 26), #selector(saveZone))
        saveButton.keyEquivalent = "\r"; saveButton.isHidden = true
        cancelButton = button("Cancel", NSRect(x: 128, y: 8, width: 80, height: 26), #selector(cancelDraw))
        cancelButton.isHidden = true
        instr = label(NSRect(x: 220, y: 8, width: w - side - 240, height: 22), "Pick a zone to fly to it · + Circle / + Polygon to add (admin) · select + Delete to remove")
        instr.autoresizingMask = [.width]
        instr.textColor = .secondaryLabelColor
        [addCircle, addPoly, nameField, radiusSlider, radiusLabel, saveButton, cancelButton, instr].forEach { toolbar.addSubview($0) }
        content.addSubview(toolbar)

        // ---- sidebar ----
        let sidebar = NSView(frame: NSRect(x: 0, y: 0, width: side, height: h))
        sidebar.autoresizingMask = [.height, .maxXMargin]
        search = NSSearchField(frame: NSRect(x: 12, y: h - 36, width: side - 24, height: 24))
        search.placeholderString = "search address…"
        search.target = self; search.action = #selector(doSearch); search.delegate = self
        let locBtn = button("◎ My location", NSRect(x: 12, y: h - 68, width: 124, height: 24), #selector(goToMe))
        let mapType = NSSegmentedControl(labels: ["Map", "Satellite", "Hybrid"], trackingMode: .selectOne, target: self, action: #selector(changeMapType))
        mapType.frame = NSRect(x: 12, y: h - 100, width: side - 24, height: 24); mapType.selectedSegment = 0
        let zonesLabel = label(NSRect(x: 14, y: h - 126, width: side - 24, height: 18), "ZONES")
        zonesLabel.font = .systemFont(ofSize: 11, weight: .semibold); zonesLabel.textColor = .secondaryLabelColor
        let scroll = NSScrollView(frame: NSRect(x: 12, y: 52, width: side - 24, height: h - 126 - 60))
        scroll.autoresizingMask = [.height]; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        table = NSTableView(frame: scroll.bounds)
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("z")); col.width = side - 44
        table.addTableColumn(col); table.headerView = nil; table.dataSource = self; table.delegate = self
        table.doubleAction = #selector(flyToSelected)
        scroll.documentView = table
        let delBtn = button("Delete selected", NSRect(x: 12, y: 14, width: side - 24, height: 28), #selector(deleteSelected))
        [search, locBtn, mapType, zonesLabel, scroll, delBtn].forEach { sidebar.addSubview($0) }
        content.addSubview(sidebar)

        window.contentView = content
        renderAll()
        if let r = regionFor(zones) { map.setRegion(r, animated: false) }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: drawing

    private func handleDoubleClick(_ c: CLLocationCoordinate2D) -> Bool {
        switch mode {
        case .circle:
            circleCenter = c; renderAll()
            instr.stringValue = "Adjust the radius, name it, then Save zone — or double-click to move the center"
            return true
        case .polygon:
            polyVerts.append(c); renderAll()
            instr.stringValue = "\(polyVerts.count) corner(s) — double-click to add more, then Save zone (need ≥3)"
            return true
        case .idle:
            return false   // let the map zoom normally
        }
    }

    @objc private func startCircle() { beginDraw(.circle); radiusSlider.isHidden = false; radiusLabel.isHidden = false; radiusChanged()
        instr.stringValue = "Double-click the map to place the circle's center" }
    @objc private func startPolygon() { beginDraw(.polygon)
        instr.stringValue = "Double-click the map to drop each corner, then Save zone (need ≥3)" }

    private func beginDraw(_ m: DrawMode) {
        mode = m; circleCenter = nil; polyVerts = []
        saveButton.isHidden = false; cancelButton.isHidden = false
        radiusSlider.isHidden = (m != .circle); radiusLabel.isHidden = (m != .circle)
        setMapZoomOnDoubleClick(false)
        renderAll()
    }

    @objc private func cancelDraw() {
        mode = .idle; circleCenter = nil; polyVerts = []
        saveButton.isHidden = true; cancelButton.isHidden = true; radiusSlider.isHidden = true; radiusLabel.isHidden = true
        setMapZoomOnDoubleClick(true)
        renderAll(); instr.stringValue = "Cancelled."
    }

    @objc private func radiusChanged() { radiusLabel.stringValue = "\(Int(radiusSlider.doubleValue)) m"; renderAll() }

    @objc private func saveZone() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { instr.stringValue = "Type a name for the zone first."; return }
        var current = ZoneStore.load()
        guard !current.contains(where: { $0.name == name }) else { instr.stringValue = "A zone named \"\(name)\" already exists."; return }

        let newZone: Zone
        switch mode {
        case .circle:
            guard let c = circleCenter else { instr.stringValue = "Double-click the map to place the center first."; return }
            newZone = Zone(name: name, shape: .circle(centerLat: c.latitude, centerLon: c.longitude, radius: radiusSlider.doubleValue))
        case .polygon:
            guard polyVerts.count >= 3 else { instr.stringValue = "A polygon needs at least 3 corners."; return }
            guard isSimplePolygon(polyVerts) else { instr.stringValue = "✗ The polygon's edges cross — draw a simple shape."; return }
            newZone = Zone(name: name, shape: .polygon(points: polyVerts.map { Coord(lat: $0.latitude, lon: $0.longitude) }))
        case .idle:
            return
        }
        current.append(newZone)
        switch askSaveMode(name) {
        case .immediate:
            if saveWithAdmin(current) {
                nameField.stringValue = ""; cancelDraw(); reload(); instr.stringValue = "✓ added \"\(name)\""
            } else {
                instr.stringValue = "Add cancelled — needs admin."
            }
        case .delayed:
            if saveWithDelay(current) {
                nameField.stringValue = ""; cancelDraw()
                instr.stringValue = "⏳ queued \"\(name)\" — lands in \(zonesDelayH)h (no admin). `demonlock status` to watch · `demonlock delayzones --abort` to cancel."
            } else {
                instr.stringValue = "Couldn't queue the change (is demonlock installed?)."
            }
        case .cancel:
            instr.stringValue = "Save cancelled."
        }
    }

    private enum SaveMode { case immediate, delayed, cancel }

    /// The delayed zone-change landing delay, in hours (tunable via `sudo demonlock delayzones set-delay`).
    private var zonesDelayH: Int { Int(Bounds.clamp(Settings.load().zonesDelaySec, Bounds.zonesDelay) / 3600) }

    /// Adding a zone LOOSENS the policy, so it's gated: do it NOW with admin, or queue it for the delay
    /// (no admin — the daemon installs it later, the same commitment-device idea as the release valve /
    /// `delay-set-policy`).
    private func askSaveMode(_ name: String) -> SaveMode {
        let a = NSAlert()
        a.messageText = "Add zone “\(name)”?"
        a.informativeText = "Adding a zone loosens the policy.\n\n• Save now — needs admin (you'll be asked to authenticate).\n• Save in \(zonesDelayH)h — no admin; the change lands automatically after \(zonesDelayH) hours."
        a.addButton(withTitle: "Save now (admin)")
        a.addButton(withTitle: "Save in \(zonesDelayH)h")
        a.addButton(withTitle: "Cancel")
        switch a.runModal() {
        case .alertFirstButtonReturn:  return .immediate
        case .alertSecondButtonReturn: return .delayed
        default:                       return .cancel
        }
    }

    @objc private func deleteSelected() {
        let i = table.selectedRow
        guard i >= 0, i < zones.count else { instr.stringValue = "Select a zone in the list to delete it."; return }
        let name = zones[i].name
        // Deleting a zone is NOT monotone — a name used under NOT loosens the policy when removed — so it
        // is gated exactly like adding: admin now, or delayed. (The free _zonedel grant is gone. review H3)
        var remaining = ZoneStore.load(); remaining.removeAll { $0.name == name }
        switch askDeleteMode(name) {
        case .immediate:
            if saveWithAdmin(remaining) { reload(); instr.stringValue = "✓ deleted \"\(name)\"" }
            else { instr.stringValue = "Delete cancelled — needs admin." }
        case .delayed:
            if saveWithDelay(remaining) { instr.stringValue = "⏳ queued deletion of \"\(name)\" — lands in \(zonesDelayH)h. `demonlock delayzones --abort` to cancel." }
            else { instr.stringValue = "Couldn't queue the change (is demonlock installed?)." }
        case .cancel:
            instr.stringValue = "Delete cancelled."
        }
    }

    private func askDeleteMode(_ name: String) -> SaveMode {
        let a = NSAlert()
        a.messageText = "Delete zone “\(name)”?"
        a.informativeText = "Deleting a zone can LOOSEN the policy (a zone used under NOT).\n\n• Delete now — needs admin.\n• Delete in \(zonesDelayH)h — no admin; the change lands automatically."
        a.addButton(withTitle: "Delete now (admin)")
        a.addButton(withTitle: "Delete in \(zonesDelayH)h")
        a.addButton(withTitle: "Cancel")
        switch a.runModal() {
        case .alertFirstButtonReturn:  return .immediate
        case .alertSecondButtonReturn: return .delayed
        default:                       return .cancel
        }
    }

    // MARK: privilege bridges

    /// Adding loosens the policy → require admin.
    private func saveWithAdmin(_ zs: [Zone]) -> Bool {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(zs) else { return false }
        let tmp = NSTemporaryDirectory() + "demonlock-zones-new.json"
        guard (try? data.write(to: URL(fileURLWithPath: tmp))) != nil else { return false }
        let script = "do shell script \"mkdir -p '\(Paths.supportDir)' && cp '\(tmp)' '\(Paths.zonesFile)' && chown root:wheel '\(Paths.zonesFile)' && chmod 644 '\(Paths.zonesFile)'\" with administrator privileges"
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript"); p.arguments = ["-e", script]
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 } catch { return false }
    }

    /// Queue the new zones set as a DELAYED change (no admin): write the full zones.json to the
    /// user-owned inbox marker; the daemon validates + installs it after 36h. Same encoding as
    /// `saveWithAdmin` so what lands is byte-identical to an immediate save.
    private func saveWithDelay(_ zs: [Zone]) -> Bool {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(zs), let json = String(data: data, encoding: .utf8) else { return false }
        return (try? json.write(toFile: Paths.dzRequestMarker, atomically: true, encoding: .utf8)) != nil
    }

    // MARK: rendering

    private func reload() { zones = ZoneStore.load(); table.reloadData(); renderAll() }

    private func renderAll() {
        map.removeOverlays(map.overlays)
        map.removeAnnotations(map.annotations.filter { !($0 is MKUserLocation) })
        for z in zones { if let o = overlay(for: z) { map.addOverlay(o) } }
        if mode == .circle, let c = circleCenter {
            map.addOverlay(draftCircle(center: c, radius: radiusSlider.doubleValue))
        }
        if mode == .polygon, polyVerts.count >= 1 {
            for v in polyVerts { let a = MKPointAnnotation(); a.coordinate = v; a.title = "vertex"; map.addAnnotation(a) }
            if polyVerts.count >= 2 { let p = MKPolygon(coordinates: polyVerts, count: polyVerts.count); p.title = "draft"; map.addOverlay(p) }
        }
    }

    private func setMapZoomOnDoubleClick(_ on: Bool) {
        for gr in map.gestureRecognizers {
            if let c = gr as? NSClickGestureRecognizer, c.numberOfClicksRequired == 2 { c.isEnabled = on }
        }
    }

    // MARK: search / location / map type

    @objc private func doSearch() {
        let q = search.stringValue.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        let req = MKLocalSearch.Request(); req.naturalLanguageQuery = q; req.region = map.region
        MKLocalSearch(request: req).start { [weak self] resp, _ in
            guard let self, let item = resp?.mapItems.first else { return }
            DispatchQueue.main.async {
                self.map.setRegion(MKCoordinateRegion(center: item.placemark.coordinate,
                    latitudinalMeters: 500, longitudinalMeters: 500), animated: true)
            }
        }
    }
    @objc private func goToMe() {
        let c = map.userLocation.coordinate
        if CLLocationCoordinate2DIsValid(c), c.latitude != 0 || c.longitude != 0 {
            map.setRegion(MKCoordinateRegion(center: c, latitudinalMeters: 400, longitudinalMeters: 400), animated: true)
        } else { instr.stringValue = "Current location not available yet." }
    }
    @objc private func changeMapType(_ s: NSSegmentedControl) {
        map.mapType = [.standard, .satellite, .hybrid][s.selectedSegment]
    }

    // MARK: table

    func numberOfRows(in t: NSTableView) -> Int { zones.count }
    func tableView(_ t: NSTableView, viewFor c: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let tf = (t.makeView(withIdentifier: id, owner: self) as? NSTextField) ?? {
            let f = NSTextField(); f.identifier = id; f.isEditable = false; f.isBordered = false; f.drawsBackground = false; return f
        }()
        let z = zones[row]
        let glyph = { if case .circle = z.shape { return "◯" } else { return "⬠" } }()
        tf.stringValue = "\(glyph)  \(z.name)"
        return tf
    }
    func tableViewSelectionDidChange(_ n: Notification) { flyToSelected() }
    @objc private func flyToSelected() {
        let i = table.selectedRow
        guard i >= 0, i < zones.count, let r = regionFor([zones[i]]) else { return }
        map.setRegion(r, animated: true)
    }

    // MARK: map delegate

    func mapView(_ m: MKMapView, rendererFor o: MKOverlay) -> MKOverlayRenderer { greenRenderer(o) }
    func mapView(_ m: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
        if annotation is MKUserLocation { return nil }
        if (annotation.title ?? nil) == "vertex" {
            return VertexView(annotation: annotation, reuseIdentifier: "vertex")
        }
        return nil
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }

    // MARK: small builders
    private func label(_ f: NSRect, _ s: String) -> NSTextField {
        let l = NSTextField(frame: f); l.isEditable = false; l.isBordered = false; l.drawsBackground = false; l.stringValue = s; return l
    }
    private func button(_ t: String, _ f: NSRect, _ sel: Selector) -> NSButton {
        let b = NSButton(title: t, target: self, action: sel); b.frame = f; b.bezelStyle = .rounded; return b
    }
}

// MARK: - overlay helpers

private func overlay(for zone: Zone) -> MKOverlay? {
    switch zone.shape {
    case .circle(let lat, let lon, let r):
        return MKCircle(center: CLLocationCoordinate2D(latitude: lat, longitude: lon), radius: r)
    case .polygon(let pts):
        let c = pts.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
        return MKPolygon(coordinates: c, count: c.count)
    }
}
private func draftCircle(center: CLLocationCoordinate2D, radius: Double) -> MKCircle {
    let c = MKCircle(center: center, radius: radius); c.title = "draft"; return c
}
private func greenRenderer(_ o: MKOverlay) -> MKOverlayRenderer {
    let draft = (o.title ?? nil) == "draft"
    let stroke: NSColor = draft ? .systemBlue : .systemGreen
    if let c = o as? MKCircle {
        let r = MKCircleRenderer(circle: c); r.fillColor = stroke.withAlphaComponent(0.20); r.strokeColor = stroke; r.lineWidth = 2; return r
    }
    if let p = o as? MKPolygon {
        let r = MKPolygonRenderer(polygon: p); r.fillColor = stroke.withAlphaComponent(0.20); r.strokeColor = stroke; r.lineWidth = 2; return r
    }
    return MKOverlayRenderer(overlay: o)
}
private func regionFor(_ zones: [Zone]) -> MKCoordinateRegion? {
    var lats: [Double] = [], lons: [Double] = []
    for z in zones {
        switch z.shape {
        case .circle(let lat, let lon, let r):
            let dLat = r / 111_000.0, dLon = r / (111_000.0 * max(cos(lat * .pi / 180), 0.1))
            lats += [lat - dLat, lat + dLat]; lons += [lon - dLon, lon + dLon]
        case .polygon(let pts): lats += pts.map(\.lat); lons += pts.map(\.lon)
        }
    }
    guard let a = lats.min(), let b = lats.max(), let c = lons.min(), let d = lons.max() else { return nil }
    return MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: (a + b) / 2, longitude: (c + d) / 2),
                              span: MKCoordinateSpan(latitudeDelta: max((b - a) * 1.5, 0.008),
                                                     longitudeDelta: max((d - c) * 1.5, 0.008)))
}

private func ccw(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D, _ c: CLLocationCoordinate2D) -> Bool {
    (c.latitude - a.latitude) * (b.longitude - a.longitude) > (b.latitude - a.latitude) * (c.longitude - a.longitude)
}
private func segsIntersect(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D, _ c: CLLocationCoordinate2D, _ d: CLLocationCoordinate2D) -> Bool {
    ccw(a, c, d) != ccw(b, c, d) && ccw(a, b, c) != ccw(a, b, d)
}
func isSimplePolygon(_ p: [CLLocationCoordinate2D]) -> Bool {
    let n = p.count; guard n >= 3 else { return false }
    for i in 0..<n {
        for j in (i + 1)..<n {
            if j == i + 1 || (i == 0 && j == n - 1) { continue }
            if segsIntersect(p[i], p[(i + 1) % n], p[j], p[(j + 1) % n]) { return false }
        }
    }
    return true
}

// MARK: - entry points

func runZones() {
    if geteuid() == 0 {
        FileHandle.standardError.write(Data("demonlock zones: run as your user (not sudo) — root has no Location.\n".utf8))
        exit(1)
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let d = ZonesController()
    app.delegate = d
    app.run()
}

