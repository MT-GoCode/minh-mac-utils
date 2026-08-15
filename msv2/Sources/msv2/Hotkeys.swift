import AppKit

// One CGEvent tap. Two gestures, both harmless — neither ever moves a window:
//   hold ⌘⌥       → overlay of all desktops in spaced views; release hides.
//   ⌘⇥            → in-group switcher. Hold ⌘, ⇥/⇧⇥/arrows to pick, release ⌘ commits,
//                   esc cancels. (Replaces native ⌘⇥, scoped to the current group.)
//
// Discipline (MSV's root bug, avoided): the callback CLASSIFIES + CONSUMES only; every
// action dispatches out — never AX inside the tap. The switcher commits ONLY on the ⌘
// key's own release (keycode 54/55 in flagsChanged); other cmd-less events mid-hold
// (e.g. Karabiner remaps) must not be read as a release. KeyUp debts are counters with a
// TTL so a lost keyUp can't poison later keystrokes.
@MainActor
final class Hotkeys {
    static let shared = Hotkeys()
    private var tap: CFMachPort?
    private var owedKeyUps: [Int64: (count: Int, at: Date)] = [:]

    var alive: Bool { tap != nil }

    /// Idempotent: safe to retry after the user grants Accessibility (tap creation fails
    /// silently without it, and there's no notification when it's granted).
    func start() {
        guard tap == nil else { return }
        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, _ in Hotkeys.callback(type: type, event: event) },
            userInfo: nil)
        guard let tap else {
            NSLog("msv2: event tap failed — grant Accessibility and relaunch")
            return
        }
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func consume(_ code: Int64) {
        owedKeyUps[code] = ((owedKeyUps[code]?.count ?? 0) + 1, Date())
    }

    private func settleKeyUp(_ code: Int64) -> Bool {
        guard var debt = owedKeyUps[code] else { return false }
        if Date().timeIntervalSince(debt.at) > 2 { owedKeyUps.removeValue(forKey: code); return false }
        debt.count -= 1
        if debt.count <= 0 { owedKeyUps.removeValue(forKey: code) } else { owedKeyUps[code] = debt }
        return true
    }

    private nonisolated static func callback(
        type: CGEventType, event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        MainActor.assumeIsolated { Hotkeys.shared.handle(type: type, event: event) }
    }

    private func pass(_ e: CGEvent) -> Unmanaged<CGEvent> { Unmanaged.passUnretained(e) }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass(event)
        }
        let s = Switcher.shared
        let f = event.flags
        let cmd = f.contains(.maskCommand)
        let code = event.getIntegerValueField(.keyboardEventKeycode)

        let opt = f.contains(.maskAlternate)
        let ctrl = f.contains(.maskControl)
        let shift = f.contains(.maskShift)

        if type == .flagsChanged {
            if s.isOpen, !cmd, code == 54 || code == 55 { s.commit() }   // ⌘ released → commit
            // hold ⌘⌥ (nothing else) → overlay of all desktops; release/break → hide.
            if cmd, opt, !ctrl, !shift, !s.isOpen {
                Overlay.shared.scheduleHeld()
            } else {
                Overlay.shared.cancelHeld()
            }
            return pass(event)
        }
        if type == .keyUp {
            return settleKeyUp(code) ? nil : pass(event)
        }
        guard type == .keyDown else { return pass(event) }

        // Any real key while ⌘⌥ is held is a chord (⌘⌥I, ⌘⌥esc, …), not an overlay peek.
        if cmd, opt { Overlay.shared.cancelHeld() }

        // ⌘ layer: the switcher.
        if cmd, !opt, !ctrl {
            if code == 48 {                       // tab
                consume(code)
                DispatchQueue.main.async {
                    s.isOpen ? s.step(shift ? -1 : 1) : s.open()
                }
                return nil
            }
            if s.isOpen {
                switch code {
                case 123: consume(code); DispatchQueue.main.async { s.arrow(-1, 0) }; return nil
                case 124: consume(code); DispatchQueue.main.async { s.arrow(1, 0) }; return nil
                case 125: consume(code); DispatchQueue.main.async { s.arrow(0, 1) }; return nil
                case 126: consume(code); DispatchQueue.main.async { s.arrow(0, -1) }; return nil
                case 53: consume(code); DispatchQueue.main.async { s.cancel() }; return nil  // esc
                default: break
                }
            }
        }
        // esc cancels regardless of modifiers, so a dropped ⌘ can't trap the HUD.
        if s.isOpen, code == 53 {
            consume(code)
            DispatchQueue.main.async { s.cancel() }
            return nil
        }
        return pass(event)
    }
}
