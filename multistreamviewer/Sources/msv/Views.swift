import SwiftUI
import AppKit

// MARK: - Uniform grid (equal cells, columns-first growth)

struct UniformGrid<Cell: View>: View {
    let count: Int
    @ViewBuilder let cell: (Int) -> Cell

    var body: some View {
        let (cols, rows) = gridDims(count)
        VStack(spacing: 6) {
            ForEach(0..<max(1, rows), id: \.self) { r in
                HStack(spacing: 6) {
                    ForEach(0..<cols, id: \.self) { col in
                        let i = r * cols + col
                        if i < count {
                            cell(i).frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Overlay: all desktops + fullscreen strip

struct GridView: View {
    @EnvironmentObject var c: Controller

    var body: some View {
        VStack(spacing: 6) {
            if c.workspaces.isEmpty {
                Color.clear
            } else {
                UniformGrid(count: c.workspaces.count) { i in
                    WorkspaceTile(ws: c.workspaces[i], number: i + 1)
                }
            }
            if !c.fullscreen.isEmpty {
                FullscreenStrip(windows: c.fullscreen)
                    .frame(height: 110)
            }
        }
        .padding(6)
    }
}

struct FullscreenStrip: View {
    @EnvironmentObject var c: Controller
    let windows: [Win]

    var body: some View {
        HStack(spacing: 6) {
            Text("FULLSCREEN").font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(-90)).fixedSize().frame(width: 14)
            ForEach(windows) { w in
                Thumb(window: w, captures: Captures.shared)
                    .overlay(alignment: .bottomLeading) { appTag(w.title) }
                    .contentShape(Rectangle())
                    .onTapGesture { c.jumpFullscreen(w) }
                    .help("Jump to fullscreen \(w.app) (native space)")
            }
            Spacer(minLength: 0)
        }
        .padding(4)
        .background(Color(white: 0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - One desktop tile

struct WorkspaceTile: View {
    @EnvironmentObject var c: Controller
    let ws: Workspace
    let number: Int
    @State private var draft = ""
    @FocusState private var editFocus: Bool

    var body: some View {
        VStack(spacing: 0) {
            banner
            if ws.windows.isEmpty {
                ZStack {
                    Color(white: 0.1)
                    Text("empty").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                UniformGrid(count: ws.windows.count) { i in
                    WindowThumb(window: ws.windows[i])
                }
                .padding(3)
            }
        }
        .background(Color(white: 0.12))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(ws.isActive ? Color.accentColor : Color(white: 0.3),
                        lineWidth: ws.isActive ? 2.5 : 1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onDrop(of: [.plainText], isTargeted: nil) { _ in
            if let w = c.dragWindow {
                c.moveWindow(w, to: ws.id)
                c.dragWindow = nil
            } else if let d = c.draggedID {
                c.reorder(dragged: d, before: ws.id)
                c.draggedID = nil
            }
            return true
        }
    }

    private var banner: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal").foregroundStyle(.secondary)
                .onDrag {
                    c.draggedID = ws.id
                    return NSItemProvider(object: ws.id.uuidString as NSString)
                }
            Text("\(number).").bold().foregroundStyle(Color.accentColor)
            if c.editingID == ws.id {
                TextField("", text: $draft, onCommit: {
                    c.rename(ws.id, draft)
                    c.editingID = nil
                })
                .textFieldStyle(.plain)
                .focused($editFocus)
                .onAppear { editFocus = true }
                .onChange(of: editFocus) { _, f in
                    if !f, c.editingID == ws.id {  // commit on leaving the field
                        c.rename(ws.id, draft)
                        c.editingID = nil
                    }
                }
            } else {
                Text(ws.name).lineLimit(1)
                    .onTapGesture(count: 2) { c.activate(ws.id) }
            }
            Spacer()
            btn("wand.and.stars", "Seed this desktop") { c.seed(ws.id) }
            btn("pencil", "Rename") {
                draft = ws.name
                c.editingID = ws.id
            }
            btn("trash", "Close desktop (closes all its windows)") { c.closeWorkspace(ws.id) }
        }
        .buttonStyle(.plain)
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(ws.isActive ? Color.accentColor.opacity(0.25) : Color(white: 0.18))
    }

    private func btn(_ icon: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon) }.help(help)
    }
}

// MARK: - Window thumbnails

/// Bare live image (used by strip + switcher).
struct Thumb: View {
    let window: Win
    @ObservedObject var captures: Captures

    var body: some View {
        if let img = captures.images[window.id] {
            Image(decorative: img, scale: 1).resizable().aspectRatio(contentMode: .fit)
        } else {
            Color(white: 0.2)
        }
    }
}

func appTag(_ name: String) -> some View {
    Text(name).font(.system(size: 9)).lineLimit(1).truncationMode(.tail)
        .padding(.horizontal, 4).background(.black.opacity(0.6)).foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
}

/// Interactive thumbnail inside a desktop tile.
struct WindowThumb: View {
    @EnvironmentObject var c: Controller
    let window: Win
    @State private var hover = false

    var body: some View {
        Thumb(window: window, captures: Captures.shared)
            .overlay(alignment: .topTrailing) {
                if hover {
                    HStack(spacing: 5) {
                        Button { c.closeWindow(window) } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.white, .gray)
                        }.help("Close window")
                        Button { c.killApp(window) } label: {
                            Image(systemName: "power.circle.fill")
                                .foregroundStyle(.white, .purple)
                        }.help("Quit app")
                    }
                    .buttonStyle(.plain).font(.system(size: 15)).padding(4)
                }
            }
            .onHover { hover = $0 }
            .overlay(alignment: .bottomLeading) { appTag(window.title) }
            .contentShape(Rectangle())
            .onTapGesture { c.focus(window) }
            .onDrag {
                c.dragWindow = window.id
                return NSItemProvider(object: String(window.id) as NSString)
            }
    }
}

// MARK: - cmd+tab switcher

struct SwitcherView: View {
    @EnvironmentObject var c: Controller

    var body: some View {
        Group {
            if let sel = c.switcherIndex, !c.switcherWindows.isEmpty {
                UniformGrid(count: c.switcherWindows.count) { i in
                    SwitcherTile(window: c.switcherWindows[i], index: i, selected: i == sel)
                }
            } else {
                Color.clear
            }
        }
        .padding(10)
    }
}

struct SwitcherTile: View {
    @EnvironmentObject var c: Controller
    let window: Win
    let index: Int
    let selected: Bool
    @State private var hover = false

    var body: some View {
        Thumb(window: window, captures: Captures.shared)
            .overlay(alignment: .topTrailing) {
                if hover {
                    HStack(spacing: 5) {
                        Button { c.switcherCloseWindow(window) } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.white, .gray)
                        }.help("Close window")
                        Button { c.switcherKillApp(window) } label: {
                            Image(systemName: "power.circle.fill")
                                .foregroundStyle(.white, .purple)
                        }.help("Quit app")
                    }
                    .buttonStyle(.plain).font(.system(size: 15)).padding(4)
                }
            }
            .onHover { hover = $0 }
            .overlay(alignment: .bottomLeading) { appTag(window.title) }
            .padding(3)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(selected ? Color.accentColor : .clear, lineWidth: 3))
            .contentShape(Rectangle())
            .onTapGesture {
                c.switcherIndex = index
                c.switcherCommit()
            }
    }
}

// MARK: - Settings

/// One desktop in the settings Control Panel: rename inline, switch, close,
/// and drag window rows between desktops.
struct DesktopRow: View {
    @ObservedObject var c: Controller
    let ws: Workspace
    @State private var name = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle().fill(ws.isActive ? Color.accentColor : Color(white: 0.4))
                    .frame(width: 8, height: 8)
                TextField("", text: $name)
                    .textFieldStyle(.roundedBorder).frame(width: 170)
                    .focused($nameFocused)
                    .onSubmit {
                        c.rename(ws.id, name)
                        nameFocused = false  // enter = done editing
                    }
                    .onChange(of: nameFocused) { _, f in
                        if !f { c.rename(ws.id, name) }  // commit on leaving the field
                    }
                    .onChange(of: ws.name) { _, n in
                        if !nameFocused { name = n }  // reflect renames from elsewhere
                    }
                Button { c.activate(ws.id) } label: {
                    Image(systemName: "arrow.right.circle")
                }.buttonStyle(.plain).help("Switch to this desktop")
                Button { c.closeWorkspace(ws.id) } label: {
                    Image(systemName: "trash").foregroundStyle(.red)
                }.buttonStyle(.plain)
                    .disabled(c.workspaces.count == 1)
                    .help("Close desktop (closes its windows)")
                Spacer()
            }
            ForEach(ws.windows) { w in
                Text("⠿ \(w.app) — \(w.title)")
                    .font(.system(.caption, design: .monospaced)).lineLimit(1)
                    .padding(.leading, 18)
                    .onDrag {
                        c.dragWindow = w.id
                        return NSItemProvider(object: String(w.id) as NSString)
                    }
            }
            if ws.windows.isEmpty {
                Text("(empty)").font(.caption).foregroundStyle(.secondary).padding(.leading, 18)
            }
        }
        .contentShape(Rectangle())
        .onDrop(of: [.plainText], isTargeted: nil) { _ in
            if let d = c.dragWindow {
                c.moveWindow(d, to: ws.id)
                c.dragWindow = nil
            }
            return true
        }
        .onAppear { name = ws.name }
    }
}

struct SettingsView: View {
    @ObservedObject var c: Controller
    @AppStorage("appPriority") var appPriority = ""
    @AppStorage("excludeApps") var excludeApps = ""
    @AppStorage("activeDim") var activeDim = 720.0
    @State private var seeds = Seeds.all
    @State private var newCmd = ""
    @State private var perDesktop: [UUID: [SeedCmd]] = [:]
    @State private var axOK = AXIsProcessTrusted()
    @State private var srOK = CGPreflightScreenCaptureAccess()
    private let permTick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section("Permissions") {
                permRow("Accessibility — switching, parking, hotkeys", ok: axOK)
                permRow("Screen Recording — thumbnails", ok: srOK)
                HStack {
                    Button("Request Missing") {
                        if !axOK {
                            AXIsProcessTrustedWithOptions(
                                ["AXTrustedCheckOptionPrompt": true] as CFDictionary)
                            NSWorkspace.shared.open(URL(string:
                                "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                        }
                        if !srOK {
                            CGRequestScreenCaptureAccess()
                            NSWorkspace.shared.open(URL(string:
                                "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                        }
                    }
                    .disabled(axOK && srOK)
                    Button("Relaunch App (apply grants)") {
                        let p = Process()
                        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
                        p.arguments = ["-c", "sleep 0.6; open '\(Bundle.main.bundlePath)'"]
                        try? p.run()
                        NSApp.terminate(nil)
                    }
                }
                if !(axOK && srOK) {
                    Text("Grant in System Settings, then Relaunch — permissions bind at launch.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .onReceive(permTick) { _ in
                axOK = AXIsProcessTrusted()
                srOK = CGPreflightScreenCaptureAccess()
            }
            Section("Control Panel") {
                ForEach(c.workspaces) { ws in
                    DesktopRow(c: c, ws: ws)
                }
                Button("Add Desktop") { c.newWorkspace() }
            }
            Section("Seeding — set seed (checked ones run)") {
                ForEach($seeds) { $s in
                    HStack {
                        Toggle("", isOn: $s.on).labelsHidden()
                        Text(s.cmd).font(.system(.body, design: .monospaced)).lineLimit(1)
                        Spacer()
                        Button {
                            seeds.removeAll { $0.id == s.id }
                        } label: {
                            Image(systemName: "minus.circle").foregroundStyle(.red)
                        }.buttonStyle(.plain)
                    }
                }
                HStack {
                    TextField("new bash command", text: $newCmd)
                        .font(.system(.body, design: .monospaced)).onSubmit(addCmd)
                    Button("Add", action: addCmd)
                }
                Button("Seed Current Desktop") { c.seedCurrentDesktop() }
            }
            Section("Seeding — pick desktops, then Seed") {
                ForEach(c.workspaces) { ws in
                    Toggle(ws.name, isOn: dtBinding(ws.id))
                    if let list = perDesktop[ws.id] {
                        ForEach(list) { cmd in
                            Toggle(cmd.cmd, isOn: cmdBinding(ws.id, cmd.id))
                                .font(.system(.caption, design: .monospaced))
                                .padding(.leading, 24)
                        }
                    }
                }
                Button("Seed") {
                    let jobs = c.workspaces.compactMap { ws -> (UUID, [String])? in
                        guard let l = perDesktop[ws.id] else { return nil }
                        return (ws.id, l.filter(\.on).map(\.cmd))
                    }
                    perDesktop = [:]
                    c.closeSettings()
                    c.seedMany(jobs)
                }.disabled(perDesktop.isEmpty)
            }
            Section("Excluded apps (one per line; hidden from grid and ⌘⇥)") {
                TextEditor(text: $excludeApps)
                    .font(.system(.body, design: .monospaced)).frame(height: 60)
            }
            Section("App priority (one per line; earlier = placed left/top)") {
                TextEditor(text: $appPriority)
                    .font(.system(.body, design: .monospaced)).frame(height: 60)
            }
            Section {
                Slider(value: $activeDim, in: 320...1280, step: 80) {
                    Text("Thumbnail size: \(Int(activeDim))px")
                }
                Text("""
                    ⌘⌥ hold: overlay · ⌘⌥1-9: desktop N · ⌘⌥⇥: next desktop · ⌘⌥=: new desktop
                    ⌘⇥: window switcher (hold ⌘, use ⇥/arrows, release to pick, esc cancels)
                    """)
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .contentShape(Rectangle())
        .onTapGesture { NSApp.keyWindow?.makeFirstResponder(nil) }  // click-away unfocuses
        .onChange(of: seeds) { _, v in Seeds.all = v }
    }

    private func permRow(_ label: String, ok: Bool) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? .green : .red)
            Text(label)
        }
    }

    private func addCmd() {
        let cmd = newCmd.trimmingCharacters(in: .whitespaces)
        guard !cmd.isEmpty else { return }
        seeds.append(SeedCmd(cmd: cmd, on: true))
        newCmd = ""
    }

    private func dtBinding(_ id: UUID) -> Binding<Bool> {
        Binding(get: { perDesktop[id] != nil }, set: { perDesktop[id] = $0 ? seeds : nil })
    }

    private func cmdBinding(_ id: UUID, _ cmdID: UUID) -> Binding<Bool> {
        Binding(
            get: { perDesktop[id]?.first { $0.id == cmdID }?.on ?? false },
            set: { on in
                guard var l = perDesktop[id],
                    let i = l.firstIndex(where: { $0.id == cmdID }) else { return }
                l[i].on = on
                perDesktop[id] = l
            })
    }
}
