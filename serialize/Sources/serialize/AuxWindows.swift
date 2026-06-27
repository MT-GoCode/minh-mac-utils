import Cocoa
import SwiftUI

/// Presents the small editor / settings windows. They are normal key-capable NSWindows (unlike
/// the click-through overlay); showing one briefly activates the app so it can take keyboard,
/// then the app drops back to the background when the window closes.
final class AuxWindowController {
    enum Kind { case editor, settings }

    private var editor: NSWindow?
    private var settings: NSWindow?

    func show(_ kind: Kind) {
        let win: NSWindow
        switch kind {
        case .editor:
            if editor == nil { editor = make(title: "Modify Task", size: NSSize(width: 420, height: 150),
                                             root: AnyView(EditorView())) }
            win = editor!
        case .settings:
            if settings == nil { settings = make(title: "Serialize Settings", size: NSSize(width: 360, height: 250),
                                                 root: AnyView(SettingsView())) }
            win = settings!
        }
        NSApp.activate(ignoringOtherApps: true)
        win.center()
        win.makeKeyAndOrderFront(nil)
    }

    private func make(title: String, size: NSSize, root: AnyView) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = title
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: root)
        w.level = .floating
        return w
    }
}

private struct EditorView: View {
    @ObservedObject var settings = SettingsStore.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What am I setting myself to work on?")
                .font(.headline)
            TextField("Task", text: $settings.taskText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
            HStack {
                Spacer()
                Button("Done") {
                    NSApp.keyWindow?.close()
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420, height: 150)
    }
}

private struct SettingsView: View {
    @ObservedObject var settings = SettingsStore.shared

    private func row(_ label: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, unit: String = "") -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(label): \(Int(value.wrappedValue))\(unit)")
            Slider(value: value, in: range, step: 1)
        }
    }

    var body: some View {
        Form {
            Picker("Position", selection: $settings.position) {
                ForEach(OverlayPosition.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu)

            row("Font size", $settings.fontSize, 10...40)

            Toggle("Shifting dark gradient", isOn: $settings.gradient)

            if settings.gradient {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Gradient brightness: \(Int(settings.gradientBrightness * 100))%")
                    Slider(value: $settings.gradientBrightness, in: 0.2...1.6, step: 0.05)
                }
            }

            switch settings.position {
            case .topNotch:
                row("Box width", $settings.notchWidth, 200...900)
                row("Box height", $settings.notchHeight, 40...240)
                row("Notch top offset", $settings.notchOffset, 0...60, unit: " px")
            case .left, .right:
                row("Box width", $settings.sideWidth, 120...500)
                row("Box height", $settings.sideHeight, 150...1000)
            case .topBar, .bottomBar:
                row("Bar thickness", $settings.barThickness, 18...90)
            }

            HStack {
                Spacer()
                Button("Reset to Defaults") { settings.resetToDefaults() }
            }
            .padding(.top, 6)
        }
        .padding(20)
        .frame(width: 360, height: 320)
    }
}
