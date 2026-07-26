import AppKit

// All hotkeys via one CGEvent tap. Zero Karabiner involvement.
//   hold cmd+opt            → overlay shows; release → hides
//   cmd+opt+1..9 / tab / =  → switch desktop N / next / new desktop
//   cmd+tab                 → in-desktop switcher; hold cmd, tab/arrows to pick,
//                             release cmd (or click) commits, esc cancels.
//
// Design notes from hard-won bugs:
// - Commit ONLY on the cmd key's own release event (flagsChanged, keycode
//   54/55), esc, or a click. No polling, no inference from other events:
//   Karabiner remaps (e.g. cmd+arrow → ctrl+A in terminals) emit cmd-less
//   events mid-hold that must not be read as a release.
// - Consume the keyUp of every keyDown we consume; orphaned keyups leak into
//   other apps and remappers and trigger phantom behavior.
@MainActor
final class Hotkeys {
    static let shared = Hotkeys()
    private var tap: CFMachPort?
    private var overlayShownByHold = false
    private var consumedKeys: Set<Int64> = []  // keys whose keyUp we owe a swallow

    func start() {
        let mask =
            (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, _ in Hotkeys.callback(type: type, event: event) },
            userInfo: nil)
        guard let tap else {
            NSLog("msv: event tap creation failed — grant Accessibility and relaunch")
            return
        }
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private nonisolated static func callback(
        type: CGEventType, event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        MainActor.assumeIsolated {
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let t = Hotkeys.shared.tap { CGEvent.tapEnable(tap: t, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            return Hotkeys.shared.handle(type: type, event: event)
                ? nil : Unmanaged.passUnretained(event)
        }
    }

    // MARK: Event handling

    private static let syntheticTag: Int64 = 0x6D7376  // 'msv'

    /// Post a keystroke with exactly the given modifiers (physically-held ones
    /// stripped), tagged so our own tap ignores it.
    private func postKeystroke(_ key: CGKeyCode, _ flags: CGEventFlags = []) {
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: down)
            else { continue }
            e.flags = flags
            e.setIntegerValueField(.eventSourceUserData, value: Self.syntheticTag)
            e.post(tap: .cghidEventTap)
        }
    }

    private var terminalFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.Terminal"
    }

    /// Returns true if the event was consumed.
    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticTag {
            return false  // our own synthetic events pass untouched
        }
        let c = Controller.shared
        let flags = event.flags
        let cmd = flags.contains(.maskCommand)
        let opt = flags.contains(.maskAlternate)
        let ctrl = flags.contains(.maskControl)
        let shift = flags.contains(.maskShift)
        let code = event.getIntegerValueField(.keyboardEventKeycode)

        if type == .flagsChanged {
            if c.switcherActive, !cmd, code == 54 || code == 55 {
                c.switcherCommit()
            }
            if cmd, opt, !c.switcherActive {
                overlayShownByHold = true
                c.showOverlay()
            } else if overlayShownByHold, !(cmd && opt) {
                overlayShownByHold = false
                c.hideOverlay()
            }
            return false
        }

        if type == .keyUp {
            return consumedKeys.remove(code) != nil
        }

        guard type == .keyDown else { return false }

        // ── Terminal.app editing keys, owned here instead of Karabiner ──
        // (Terminal can't express these natively; opt+arrows are stock and
        // pass through untouched.)
        if !c.switcherActive, terminalFrontmost {
            // shift+return → "\" + return (Claude Code line continuation)
            if code == 36, shift, !cmd, !opt, !ctrl {
                consume(code)
                postKeystroke(42)  // backslash
                postKeystroke(36)  // plain return
                return true
            }
        }

        // cmd+opt layer: desktop control
        if cmd, opt, !ctrl {
            switch code {
            case 48:
                consume(code)
                c.handle(Notify.prefixed("switch.next"))
                return true
            case 24:
                consume(code)
                c.newWorkspace()
                return true
            default:
                if let n = Self.digits[code] {
                    consume(code)
                    c.activateIndex(n - 1)
                    return true
                }
                return false
            }
        }

        // cmd layer: window switcher
        if cmd, !opt, !ctrl {
            if code == 48 {
                consume(code)
                if c.switcherActive {
                    c.switcherStep(shift ? -1 : 1)
                } else {
                    c.switcherOpen()
                }
                return true
            }
            if c.switcherActive {
                switch code {
                case 123: consume(code); c.switcherArrow(dx: -1, dy: 0); return true
                case 124: consume(code); c.switcherArrow(dx: 1, dy: 0); return true
                case 125: consume(code); c.switcherArrow(dx: 0, dy: 1); return true
                case 126: consume(code); c.switcherArrow(dx: 0, dy: -1); return true
                case 53:
                    consume(code)
                    c.switcherCancel()
                    return true
                default:
                    return false
                }
            }
        }
        return false
    }

    private func consume(_ code: Int64) { consumedKeys.insert(code) }

    private static let digits: [Int64: Int] = [
        18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9,
    ]
}
