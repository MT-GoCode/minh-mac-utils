import AppKit
import SwiftUI

@MainActor
final class SettingsWindow: ObservableObject {
    static let shared = SettingsWindow()
    private var window: NSWindow?

    /// Live desktop snapshot for the settings UI, refreshed by the engine tick.
    @Published var groups: [GroupView] = []
    var isOpen: Bool { window?.isVisible == true }

    func refresh() {
        guard isOpen else { return }
        groups = Engine.shared.view()
    }

    func show() {
        groups = Engine.shared.view()
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 720),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = "multistreamviewer Settings"
            w.contentView = NSHostingView(
                rootView: SettingsView()
                    .environmentObject(Config.shared)
                    .environmentObject(SettingsWindow.shared))
            w.isReleasedWhenClosed = false
            w.center()
            // Accessory apps can't win activation; go regular while open so text fields
            // take key focus, then revert.
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: w, queue: .main
            ) { _ in
                Task { @MainActor in NSApp.setActivationPolicy(.accessory) }
            }
            window = w
        }
        NSApp.setActivationPolicy(.regular)
        window!.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() { window?.close() }
}

struct SettingsView: View {
    @EnvironmentObject var cfg: Config
    @EnvironmentObject var sw: SettingsWindow

    @State private var newCmd = ""
    /// Seed picker: desktop → the command set chosen for it. Present = that desktop is
    /// checked. Cleared after seeding and whenever the window goes away.
    @State private var picker: [UUID: [SeedCmd]] = [:]
    @State private var axOK = AXIsProcessTrusted()
    @State private var srOK = CGPreflightScreenCaptureAccess()
    private let permTick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section("Permissions") {
                permRow("Accessibility — hotkeys, raising windows", ok: axOK)
                permRow("Screen Recording — thumbnails only", ok: srOK)
                HStack {
                    Button("Request Missing") {
                        if !axOK {
                            AXIsProcessTrustedWithOptions(
                                ["AXTrustedCheckOptionPrompt": true] as CFDictionary)
                            openPane("Privacy_Accessibility")
                        }
                        if !srOK {
                            CGRequestScreenCaptureAccess()
                            openPane("Privacy_ScreenCapture")
                        }
                    }
                    .disabled(axOK && srOK)
                    Button("Relaunch") {
                        let p = Process()
                        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
                        p.arguments = ["-c", "sleep 0.6; open '\(Bundle.main.bundlePath)'"]
                        try? p.run()
                        NSApp.terminate(nil)
                    }
                }
            }
            .onReceive(permTick) { _ in
                axOK = AXIsProcessTrusted()
                srOK = CGPreflightScreenCaptureAccess()
            }

            Section("Control Panel — drag ⠿ to reorder desktops, drag windows between them") {
                ForEach(sw.groups) { g in DesktopRow(g: g) }
                Button("Add Desktop") { Engine.shared.newGroup(); sw.refresh() }
            }

            Section("Seed commands (the set; checked ones are the default seed)") {
                ForEach($cfg.data.seeds) { $s in
                    HStack {
                        Toggle("", isOn: $s.on).labelsHidden()
                        TextField("", text: $s.cmd)
                            .textFieldStyle(.plain)
                            .font(.system(.caption, design: .monospaced))
                        Button {
                            cfg.data.seeds.removeAll { $0.id == s.id }
                        } label: {
                            Image(systemName: "minus.circle").foregroundStyle(.red)
                        }.buttonStyle(.plain)
                    }
                }
                HStack {
                    TextField("new shell command", text: $newCmd)
                        .font(.system(.caption, design: .monospaced))
                        .onSubmit(addCmd)
                    Button("Add", action: addCmd)
                }
                Button("Seed Current Desktop") {
                    Engine.shared.seed(Engine.shared.currentID)
                }
            }

            Section("Seed multiple — check desktops, adjust their commands, then Seed") {
                ForEach(sw.groups) { g in
                    Toggle(g.name, isOn: pickBinding(g.id))
                    if let list = picker[g.id] {
                        ForEach(list) { cmd in
                            Toggle(cmd.cmd, isOn: cmdBinding(g.id, cmd.id))
                                .font(.system(.caption, design: .monospaced))
                                .padding(.leading, 24)
                        }
                    }
                }
                Button("Seed \(picker.count) desktop\(picker.count == 1 ? "" : "s")") {
                    let jobs = sw.groups.compactMap { g -> (UUID, [String])? in
                        guard let l = picker[g.id] else { return nil }
                        return (g.id, l.filter(\.on).map(\.cmd))
                    }
                    picker = [:]                       // selection is single-use
                    SettingsWindow.shared.close()      // …and the sheet gets out of the way
                    Engine.shared.seedMany(jobs)
                }
                .disabled(picker.isEmpty)
            }

            Section("Overview grid") {
                Stepper("Width (columns): \(cfg.gridW)", value: $cfg.data.gridW, in: 2...8)
                Stepper("Height (rows): \(cfg.gridH)", value: $cfg.data.gridH, in: 2...8)
                Slider(value: $cfg.data.thumbPx, in: 200...1200, step: 100) {
                    Text("Thumbnail resolution: \(Int(cfg.data.thumbPx))px")
                }
            }

            Section("Excluded apps (one per line; hidden everywhere)") {
                linesEditor(\.excludeApps)
            }
            Section("App priority (one per line; earlier = placed first)") {
                linesEditor(\.appPriority)
            }
            Section {
                Text("""
                    hold ⌘⌥ — all desktops · click a desktop to switch, a window to raise
                    ⌘⇥ — switcher within the current desktop (hold ⌘, ⇥/arrows, release)
                    """)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 480)
        .contentShape(Rectangle())
        .onTapGesture { NSApp.keyWindow?.makeFirstResponder(nil) }
        .onDisappear { picker = [:] }                  // leaving clears the pick too
    }

    private func openPane(_ id: String) {
        NSWorkspace.shared.open(URL(string:
            "x-apple.systempreferences:com.apple.preference.security?\(id)")!)
    }

    private func permRow(_ label: String, ok: Bool) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? .green : .red)
            Text(label).font(.system(size: 12))
        }
    }

    private func addCmd() {
        let cmd = newCmd.trimmingCharacters(in: .whitespaces)
        guard !cmd.isEmpty else { return }
        cfg.data.seeds.append(SeedCmd(cmd: cmd, on: true))
        newCmd = ""
    }

    private func linesEditor(_ keyPath: WritableKeyPath<ConfigData, [String]>) -> some View {
        TextEditor(text: Binding(
            get: { cfg.data[keyPath: keyPath].joined(separator: "\n") },
            set: { cfg.data[keyPath: keyPath] = $0.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) } }))
            .font(.system(.caption, design: .monospaced))
            .frame(height: 60)
    }

    private func pickBinding(_ id: UUID) -> Binding<Bool> {
        Binding(get: { picker[id] != nil },
                set: { picker[id] = $0 ? cfg.data.seeds : nil })
    }

    private func cmdBinding(_ id: UUID, _ cmdID: UUID) -> Binding<Bool> {
        Binding(
            get: { picker[id]?.first { $0.id == cmdID }?.on ?? false },
            set: { on in
                guard var l = picker[id],
                      let i = l.firstIndex(where: { $0.id == cmdID }) else { return }
                l[i].on = on
                picker[id] = l
            })
    }
}

/// One desktop: rename inline, switch to it, seed it, delete it, and act as a drop
/// target for both window rows (retag) and other desktops (reorder).
private struct DesktopRow: View {
    @EnvironmentObject var sw: SettingsWindow
    let g: GroupView
    @State private var name = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.secondary)
                    .onDrag { NSItemProvider(object: "group:\(g.id.uuidString)" as NSString) }
                    .help("Drag to reorder")
                Circle().fill(g.isCurrent ? Color.accentColor : Color(white: 0.4))
                    .frame(width: 8, height: 8)
                TextField("", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 190)
                    .focused($nameFocused)
                    // Live: every keystroke renames, so the menu bar, overlay and
                    // window title update as you type — no Enter required.
                    .onChange(of: name) { _, v in
                        if v.count > kMaxDesktopName { name = String(v.prefix(kMaxDesktopName)) }
                        Engine.shared.rename(g.id, to: name)
                    }
                    .onChange(of: g.name) { _, n in if !nameFocused { name = n } }
                Spacer(minLength: 8)                     // buttons ride the right edge
                Button { Engine.shared.jump(to: g.id); sw.refresh() } label: {
                    Image(systemName: "arrow.right.circle")
                }.buttonStyle(.plain).help("Switch to this desktop")
                Button { Engine.shared.seed(g.id) } label: {
                    Image(systemName: "wand.and.stars")
                }.buttonStyle(.plain).help("Seed this desktop")
                Button { Engine.shared.deleteGroup(g.id); sw.refresh() } label: {
                    Image(systemName: "trash").foregroundStyle(.red)
                }.buttonStyle(.plain)
                    .disabled(sw.groups.count == 1)
                    .help("Delete desktop (closes its windows)")
            }
            ForEach(g.windows) { w in
                Text("⠿ \(w.app)\(w.title.isEmpty ? "" : " — \(w.title)")")
                    .font(.system(.caption, design: .monospaced)).lineLimit(1)
                    .padding(.leading, 18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onDrag { NSItemProvider(object: "\(w.id)" as NSString) }
            }
            if g.windows.isEmpty {
                Text("(empty)").font(.caption).foregroundStyle(.secondary).padding(.leading, 18)
            }
        }
        // Form's grouped style splits a row into a label column and a right-aligned
        // content column; claiming the full width keeps everything on OUR layout.
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onDrop(of: [.text], isTargeted: nil) { providers in
            guard let p = providers.first else { return false }
            p.loadObject(ofClass: NSString.self) { obj, _ in
                guard let s = obj as? String else { return }
                Task { @MainActor in
                    if s.hasPrefix("group:"), let id = UUID(uuidString: String(s.dropFirst(6))) {
                        Engine.shared.reorder(id, before: g.id)
                    } else if let wid = CGWindowID(s) {
                        Engine.shared.retag(wid, to: g.id)
                    }
                    SettingsWindow.shared.refresh()
                }
            }
            return true
        }
        .onAppear { name = g.name }
    }
}
