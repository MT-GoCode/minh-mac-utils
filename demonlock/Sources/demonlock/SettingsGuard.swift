import Foundation
import AppKit
import ApplicationServices

/// Folded-in settingslock: slam System Settings shut the instant it renders a GUARDED pane — the
/// FileVault recovery-key pane (so you can't read your own key) and Device Management / Profiles (so
/// you can't remove the NextDNS DoH or an MDM profile that enforces discipline). The System Settings
/// WINDOW TITLE becomes exactly the pane name ("FileVault", "Profiles", …) whether you drilled in or
/// jumped from search, so a cheap title check every 100ms catches it long before "Show"/Remove can be
/// clicked. Runs inside demonlock's agent (GUI session, needs an Accessibility TCC grant); demonlock's
/// enforcer already respawns the agent, so no separate guard daemon is needed.
enum SettingsGuard {
    /// Set once we've logged "INERT"; cleared when the grant comes back, so each loss is reported once.
    private static var loggedNoAX = false

    static let settingsBundle = "com.apple.systempreferences"

    /// Enforce once (called on the agent's fast timer): if armed + enabled and System Settings is
    /// frontmost showing a guarded pane, SIGKILL it. Cheap no-op when Settings isn't up front.
    /// Tracks whether we've already reported a missing Accessibility grant (the tick runs every 100ms).
    static func enforce(_ settings: Settings) {
        guard settings.guardSettingsPanes, ArmStore.isArmed() else { return }
        // Without Accessibility we can't read window titles, so we can't detect a guarded pane at all —
        // the guard is INERT and fails OPEN. Say so once per transition instead of returning in silence.
        guard AXIsProcessTrusted() else {
            if !loggedNoAX {
                loggedNoAX = true
                logStderr("settings-guard: INERT — Accessibility not granted, guarded panes are UNPROTECTED "
                          + "while armed. Fix with `demonlock perm-ask`.")
            }
            return
        }
        loggedNoAX = false
        guard let pid = settingsFrontmostPID() else { return }
        if let hit = guardedTitle(pid: pid, triggers: settings.guardedSettingsTitles) {
            logStderr("settings-guard: guarded pane \"\(hit)\" detected — killing System Settings (pid \(pid))")
            kill(pid, SIGKILL)
        }
    }

    /// True-ish: the matched trigger if any System Settings window title contains a guarded string.
    /// Titles only (one attribute, no tree walk) — precise, since the title is the pane name exactly.
    static func guardedTitle(pid: pid_t, triggers: [String]) -> String? {
        let app = AXUIElementCreateApplication(pid)
        guard let windows = axCopy(app, kAXWindowsAttribute as String) as? [AXUIElement] else { return nil }
        for w in windows {
            guard let t = axCopy(w, kAXTitleAttribute as String) as? String else { continue }
            for trig in triggers where t.localizedCaseInsensitiveContains(trig) { return trig }
        }
        return nil
    }

    static func settingsFrontmostPID() -> pid_t? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier == settingsBundle else { return nil }
        return app.processIdentifier
    }

    private static func axCopy(_ el: AXUIElement, _ attr: String) -> AnyObject? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success ? (v as AnyObject) : nil
    }

    /// `demonlock settings-guard dump` — print every AX string on the current Settings pane, so the
    /// exact window title for a pane can be confirmed on this macOS version and added to the triggers.
    static func dump() {
        guard AXIsProcessTrusted() else {
            print("Not Accessibility-trusted yet — grant Demonlock in System Settings ▸ Privacy & Security"
                + " ▸ Accessibility, then retry."); return
        }
        var pid = settingsFrontmostPID()
        if pid == nil {
            print("Open System Settings to the pane you want, focusing it within 3s…")
            for _ in 0..<30 { usleep(100_000); if let p = settingsFrontmostPID() { pid = p; break } }
        }
        guard let pid else { print("System Settings is not frontmost — aborting."); return }
        let app = AXUIElementCreateApplication(pid)
        if let windows = axCopy(app, kAXWindowsAttribute as String) as? [AXUIElement] {
            print("=== window titles (these are the trigger strings) ===")
            for w in windows { if let t = axCopy(w, kAXTitleAttribute as String) as? String { print("  \(t)") } }
        }
    }

    static func status() {
        let s = Settings.load()
        print("settings-guard : \(s.guardSettingsPanes ? "ENABLED" : "disabled") (active while armed)")
        print("  triggers     : \(s.guardedSettingsTitles.joined(separator: ", "))")
        print("  accessibility: \(AXIsProcessTrusted() ? "granted" : "NOT granted — run `demonlock perm-ask`")")
    }
}
