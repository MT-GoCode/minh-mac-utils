import Cocoa

/// An editable text field hosted directly inside the menu (top item) so the task can be changed
/// without opening a window. Edits the live task text as you type.
final class TaskFieldView: NSView, NSTextFieldDelegate {
    let field = NSTextField()

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 260, height: 32))
        field.frame = NSRect(x: 14, y: 6, width: 232, height: 22)
        field.placeholderString = "Task…"
        field.bezelStyle = .roundedBezel
        field.isBezeled = true
        field.focusRingType = .none
        field.delegate = self
        field.stringValue = SettingsStore.shared.taskText
        addSubview(field)
    }
    required init?(coder: NSCoder) { fatalError() }

    func sync() { field.stringValue = SettingsStore.shared.taskText }

    func controlTextDidChange(_ obj: Notification) {
        SettingsStore.shared.taskText = field.stringValue
    }

    // Enter closes the menu.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) {
            enclosingMenuItem?.menu?.cancelTracking()
            return true
        }
        return false
    }
}
