"""wtalk on-screen UI: a red dot + a tiny status-dot badge + a click-to-type
hints pill, plus the menu-bar item.

Driven from the main (AppKit) thread by the daemon's NSTimer via render(phase).
A 3-state read so you always know where you are:

  listening     bright red dot (breathing) + an editable "hints" pill under it
  transcribing  spinner only            — still waiting on the mic / Parakeet
  cleaning      spinner + GREEN dot     — transcribed; now cleaning + pasting
  done          GREEN dot only          — text pasted, finished
  done_raw      AMBER dot               — raw transcript pasted (models were slow)
  error         RED dot                 — paste blocked (grant Accessibility)
So: spinner present = still working; green dot appears the instant transcription
finishes; spinner gone + green dot = done.

Hints pill: click it to type spelling/term hints the cleanup should apply. ⌘C/⌘V/
⌘X/⌘A work inside it (we route the key equivalents to the field editor ourselves,
since an accessory app has no Edit menu to supply them). If you never click it,
focus is never taken and your cursor stays put.
"""
import subprocess

import objc
from AppKit import (
    NSAnimationContext,
    NSApplication,
    NSAppearance,
    NSAttributedString,
    NSBackingStoreBuffered,
    NSColor,
    NSEventModifierFlagCommand,
    NSFloatingWindowLevel,
    NSFont,
    NSFontAttributeName,
    NSImage,
    NSImageView,
    NSLineBreakByClipping,
    NSMenu,
    NSMenuItem,
    NSPanel,
    NSProgressIndicator,
    NSScreen,
    NSStatusBar,
    NSTextAlignmentCenter,
    NSTextField,
    NSVariableStatusItemLength,
    NSView,
    NSVisualEffectView,
    NSWindowStyleMaskBorderless,
    NSWindowStyleMaskNonactivatingPanel,
    NSWorkspace,
)
from Foundation import NSMakeRect, NSObject

import config

# ---- geometry ----
_DIAM = 30
_DOT_Y = 90
_BADGE = 11             # the tiny status dot
_BADGE_GAP = 7          # gap between the badge and the dot (so they don't overlap)
_FADE = 0.28
_PILL_H = 30
_PILL_MIN = 110
_PILL_MAX = 360
_PILL_PAD = 30
_PILL_GAP = 12
_VB_W = 92              # the "Verbatim" button, to the right of the dot
_VB_H = 26
_VB_GAP = 12           # gap between the dot and the Verbatim button
_MASK = NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel

_dot = None
_layer = None
_spinner = None
_badge = None
_badge_layer = None
_pill = None
_field = None
_delegate = None
_verbatim = None
_cur = None

# hint state (plain Python; read off-thread at stop)
_hint_text = ""
_took_focus = False
_prev_app = None
_on_submit = None
_on_verbatim = None

_DOT_RGBA = {
    "listening":    (1.00, 0.23, 0.19, 0.95),
    "transcribing": (0.60, 0.10, 0.10, 0.97),
    "cleaning":     (0.60, 0.10, 0.10, 0.97),
    "done":         (0.85, 0.20, 0.18, 0.96),
    "done_raw":     (0.85, 0.20, 0.18, 0.96),
    "error":        (1.00, 0.55, 0.00, 0.95),
}

# the tiny status-dot badge color per phase (None = no badge)
_GREEN = (0.20, 0.80, 0.36)
_AMBER = (1.00, 0.65, 0.00)
_RED = (0.95, 0.27, 0.21)
_BADGE_RGB = {"cleaning": _GREEN, "done": _GREEN, "done_raw": _AMBER, "error": _RED}


# ===================== the red dot + status-dot badge =====================
def _build_dot():
    rect = NSMakeRect(0, 0, _DIAM, _DIAM)
    panel = NSPanel.alloc().initWithContentRect_styleMask_backing_defer_(
        rect, _MASK, NSBackingStoreBuffered, False)
    panel.setLevel_(NSFloatingWindowLevel)
    panel.setOpaque_(False)
    panel.setBackgroundColor_(NSColor.clearColor())
    panel.setIgnoresMouseEvents_(True)
    panel.setHasShadow_(True)
    panel.setAlphaValue_(0.0)

    view = NSView.alloc().initWithFrame_(rect)
    view.setWantsLayer_(True)
    layer = view.layer()
    layer.setCornerRadius_(_DIAM / 2.0)
    layer.setMasksToBounds_(True)
    panel.setContentView_(view)

    try:
        from Quartz import CAGradientLayer
        sheen = CAGradientLayer.layer()
        sheen.setFrame_(rect)
        sheen.setColors_([NSColor.whiteColor().colorWithAlphaComponent_(0.40).CGColor(),
                          NSColor.clearColor().CGColor()])
        sheen.setStartPoint_((0.5, 1.0)); sheen.setEndPoint_((0.5, 0.45))
        layer.addSublayer_(sheen)
    except Exception:
        pass

    spin = NSProgressIndicator.alloc().initWithFrame_(NSMakeRect(5, 5, 20, 20))
    spin.setStyle_(1)
    spin.setIndeterminate_(True)
    spin.setDisplayedWhenStopped_(False)
    try:
        spin.setAppearance_(NSAppearance.appearanceNamed_("NSAppearanceNameDarkAqua"))
    except Exception:
        pass
    view.addSubview_(spin)
    return panel, layer, spin


def _build_badge():
    rect = NSMakeRect(0, 0, _BADGE, _BADGE)
    panel = NSPanel.alloc().initWithContentRect_styleMask_backing_defer_(
        rect, _MASK, NSBackingStoreBuffered, False)
    panel.setLevel_(NSFloatingWindowLevel)
    panel.setOpaque_(False)
    panel.setBackgroundColor_(NSColor.clearColor())
    panel.setIgnoresMouseEvents_(True)
    panel.setHasShadow_(True)
    panel.setAlphaValue_(0.0)
    view = NSView.alloc().initWithFrame_(rect)
    view.setWantsLayer_(True)
    layer = view.layer()
    layer.setCornerRadius_(_BADGE / 2.0)       # a small filled circle
    layer.setMasksToBounds_(True)
    panel.setContentView_(view)
    return panel, layer


def _set_badge_color(rgb):
    r, g, b = rgb
    _badge_layer.setBackgroundColor_(
        NSColor.colorWithSRGBRed_green_blue_alpha_(r, g, b, 1.0).CGColor())


def _breathe(on):
    try:
        from Quartz import CABasicAnimation
        if on:
            a = CABasicAnimation.animationWithKeyPath_("opacity")
            a.setFromValue_(0.7); a.setToValue_(1.0)
            a.setDuration_(1.0); a.setAutoreverses_(True); a.setRepeatCount_(1e9)
            _layer.addAnimation_forKey_(a, "breathe")
        else:
            _layer.removeAnimationForKey_("breathe")
    except Exception:
        pass


def _set_dot_color(phase):
    r, g, b, a = _DOT_RGBA[phase]
    _layer.setBackgroundColor_(
        NSColor.colorWithSRGBRed_green_blue_alpha_(r, g, b, a).CGColor())


# ===================== the hints pill =====================
class _HintPanel(NSPanel):
    def canBecomeKeyWindow(self):
        return True

    def performKeyEquivalent_(self, event):
        # An accessory app has no Edit menu, so ⌘C/⌘V/⌘X/⌘A never reach the field
        # editor on their own. Route them to the first responder ourselves.
        if event.modifierFlags() & NSEventModifierFlagCommand:
            k = (event.charactersIgnoringModifiers() or "").lower()
            sel = {"c": "copy:", "v": "paste:", "x": "cut:",
                   "a": "selectAll:", "z": "undo:"}.get(k)
            if sel and NSApplication.sharedApplication().sendAction_to_from_(sel, None, self):
                return True
        return objc.super(_HintPanel, self).performKeyEquivalent_(event)


class _HintDelegate(NSObject):
    def controlTextDidChange_(self, _):
        global _hint_text
        s = _field.stringValue()
        if len(s) > config.HINTS_MAX_CHARS:
            s = s[:config.HINTS_MAX_CHARS]
            _field.setStringValue_(s)
            _field.currentEditor().setSelectedRange_((len(s), 0))
        _hint_text = s
        _resize_pill()

    def controlTextDidBeginEditing_(self, _):
        global _took_focus, _prev_app
        if not _took_focus:
            _prev_app = NSWorkspace.sharedWorkspace().frontmostApplication()
            _took_focus = True

    def submit_(self, _):                             # Enter -> stop + send
        if _on_submit is not None:
            _on_submit()


def _build_pill():
    global _field, _delegate
    rect = NSMakeRect(0, 0, _PILL_MIN, _PILL_H)
    panel = _HintPanel.alloc().initWithContentRect_styleMask_backing_defer_(
        rect, _MASK, NSBackingStoreBuffered, False)
    panel.setLevel_(NSFloatingWindowLevel)
    panel.setOpaque_(False)
    panel.setBackgroundColor_(NSColor.clearColor())
    panel.setHasShadow_(True)
    panel.setAlphaValue_(0.0)
    panel.setBecomesKeyOnlyIfNeeded_(True)

    bg = NSVisualEffectView.alloc().initWithFrame_(rect)
    bg.setMaterial_(13)                               # HUD window
    bg.setBlendingMode_(0)
    bg.setState_(1)
    bg.setWantsLayer_(True)
    bg.layer().setCornerRadius_(_PILL_H / 2.0)
    bg.layer().setMasksToBounds_(True)
    panel.setContentView_(bg)

    field = NSTextField.alloc().initWithFrame_(NSMakeRect(12, 4, _PILL_MIN - 24, 22))
    field.setBezeled_(False); field.setBordered_(False)
    field.setDrawsBackground_(False); field.setEditable_(True); field.setSelectable_(True)
    field.setFont_(NSFont.systemFontOfSize_(13))
    field.setTextColor_(NSColor.labelColor())
    field.setAlignment_(NSTextAlignmentCenter)
    field.setPlaceholderString_("hints")
    field.setFocusRingType_(1)
    field.setUsesSingleLineMode_(True)
    field.setLineBreakMode_(NSLineBreakByClipping)
    cell = field.cell()
    cell.setUsesSingleLineMode_(True); cell.setWraps_(False); cell.setScrollable_(True)
    cell.setAlignment_(NSTextAlignmentCenter)
    _delegate = _HintDelegate.alloc().init()
    field.setDelegate_(_delegate)
    field.setTarget_(_delegate); field.setAction_("submit:")
    bg.addSubview_(field)
    _field = field
    return panel


def _text_width(s):
    if not s:
        return 0.0
    a = NSAttributedString.alloc().initWithString_attributes_(
        s, {NSFontAttributeName: _field.font()})
    return float(a.size().width)


def _resize_pill():
    w = min(max(_PILL_MIN, _text_width(_field.stringValue() or "hints") + _PILL_PAD), _PILL_MAX)
    scr = NSScreen.mainScreen().frame()
    x = (scr.size.width - w) / 2
    _pill.setFrame_display_(NSMakeRect(x, _DOT_Y - _PILL_GAP - _PILL_H, w, _PILL_H), True)
    _pill.contentView().setFrame_(NSMakeRect(0, 0, w, _PILL_H))
    _field.setFrame_(NSMakeRect(12, 4, w - 24, 22))


def _reset_pill():
    global _hint_text, _took_focus, _prev_app
    _hint_text = ""; _took_focus = False; _prev_app = None
    _field.setEditable_(True)
    _field.setStringValue_("")
    _resize_pill()


def _finalize_pill():
    _field.abortEditing()
    _field.setEditable_(False)
    _pill.makeFirstResponder_(None)
    if _took_focus and _prev_app is not None:
        try:
            _prev_app.activateWithOptions_(0)
        except Exception:
            pass


def hint_text():
    """Current hint string (plain str — safe to read off-thread)."""
    return (_hint_text or "").strip()


def set_submit_handler(fn):
    global _on_submit
    _on_submit = fn


# ===================== the Verbatim button =====================
class _VerbatimView(NSView):
    """The clickable 'Verbatim' pill. A plain view (NOT an NSButton) so it can take a
    click in a non-activating panel WITHOUT ever becoming first responder or activating
    wtalk — clicking it must never steal focus from, or alt-tab away from, whatever
    you're dictating into. acceptsFirstMouse makes the very first click count even
    though wtalk is a background accessory app."""

    def acceptsFirstMouse_(self, event):
        return True

    def mouseDown_(self, event):
        try:
            self.window().setAlphaValue_(0.55)      # quick press feedback
        except Exception:
            pass
        if _on_verbatim is not None:
            _on_verbatim()


def _build_verbatim():
    rect = NSMakeRect(0, 0, _VB_W, _VB_H)
    panel = NSPanel.alloc().initWithContentRect_styleMask_backing_defer_(
        rect, _MASK, NSBackingStoreBuffered, False)
    panel.setLevel_(NSFloatingWindowLevel)
    panel.setOpaque_(False)
    panel.setBackgroundColor_(NSColor.clearColor())
    panel.setHasShadow_(True)
    panel.setAlphaValue_(0.0)

    bg = NSVisualEffectView.alloc().initWithFrame_(rect)
    bg.setMaterial_(13)                               # HUD window — matches the hints pill
    bg.setBlendingMode_(0)
    bg.setState_(1)
    bg.setWantsLayer_(True)
    bg.layer().setCornerRadius_(_VB_H / 2.0)
    bg.layer().setMasksToBounds_(True)
    panel.setContentView_(bg)

    label = NSTextField.alloc().initWithFrame_(NSMakeRect(0, 4, _VB_W, 18))
    label.setBezeled_(False); label.setBordered_(False); label.setDrawsBackground_(False)
    label.setEditable_(False); label.setSelectable_(False)
    label.setFont_(NSFont.systemFontOfSize_(12))
    label.setTextColor_(NSColor.labelColor())
    label.setAlignment_(NSTextAlignmentCenter)
    label.setStringValue_("Verbatim")
    bg.addSubview_(label)

    # a transparent overlay on TOP catches the click (the label shows through it),
    # so neither the label nor the visual-effect view can swallow the mouseDown.
    overlay = _VerbatimView.alloc().initWithFrame_(rect)
    bg.addSubview_(overlay)
    return panel


def set_verbatim_handler(fn):
    global _on_verbatim
    _on_verbatim = fn


# ===================== geometry + fade =====================
def _position():
    scr = NSScreen.mainScreen().frame()
    x = (scr.size.width - _DIAM) / 2
    _dot.setFrameOrigin_((x, _DOT_Y))
    # badge sits up-and-left of the dot with a clear gap (no overlap)
    _badge.setFrameOrigin_((x - _BADGE - _BADGE_GAP, _DOT_Y + _DIAM - _BADGE + 2))
    if _verbatim is not None:
        # the Verbatim button sits to the right of the dot, vertically centered on it
        _verbatim.setFrameOrigin_((x + _DIAM + _VB_GAP, _DOT_Y + (_DIAM - _VB_H) / 2.0))


def _fade(panel, target, out=False):
    NSAnimationContext.beginGrouping()
    NSAnimationContext.currentContext().setDuration_(_FADE)
    if out:
        NSAnimationContext.currentContext().setCompletionHandler_(
            lambda: panel.orderOut_(None) if panel.alphaValue() <= 0.02 else None)
    panel.animator().setAlphaValue_(target)
    NSAnimationContext.endGrouping()


def render(phase):
    """Idempotent: bring the UI to `phase`. Main thread only."""
    global _dot, _layer, _spinner, _badge, _badge_layer, _pill, _verbatim, _cur
    if phase == _cur:
        return
    _cur = phase
    if _dot is None:
        _dot, _layer, _spinner = _build_dot()
        _badge, _badge_layer = _build_badge()
        _verbatim = _build_verbatim()
        if config.HINTS_ENABLED:
            _pill = _build_pill()

    if phase == "idle":
        _spinner.stopAnimation_(None); _breathe(False)
        if _pill is not None:
            _finalize_pill(); _fade(_pill, 0.0, out=True)
        _fade(_verbatim, 0.0, out=True)
        _fade(_badge, 0.0, out=True)
        _fade(_dot, 0.0, out=True)
        return

    _position()
    _set_dot_color(phase)
    if phase == "listening":
        _spinner.stopAnimation_(None); _breathe(True)
        _verbatim.orderFrontRegardless(); _fade(_verbatim, 1.0)
        if _pill is not None:
            _reset_pill(); _resize_pill()
            _pill.orderFrontRegardless(); _fade(_pill, 1.0)
    else:
        _fade(_verbatim, 0.0, out=True)        # Verbatim is a listening-only control
        if _pill is not None:
            _finalize_pill(); _fade(_pill, 0.0, out=True)
        # spinner = still working (transcribing OR cleaning); off once pasted/done
        if phase in ("transcribing", "cleaning"):
            _breathe(False); _spinner.startAnimation_(None)
        else:
            _breathe(False); _spinner.stopAnimation_(None)

    # the tiny status dot: green once transcription is done (cleaning + done),
    # amber for raw paste, red for an error. spinner+dot = cleaning; dot alone = done.
    rgb = _BADGE_RGB.get(phase)
    if rgb is not None:
        _set_badge_color(rgb)
        _badge.orderFrontRegardless(); _fade(_badge, 1.0)
    else:
        _fade(_badge, 0.0)              # no orderOut: avoids racing the next show
    _dot.orderFrontRegardless(); _fade(_dot, 1.0)


def ensure_app():
    app = NSApplication.sharedApplication()
    app.setActivationPolicy_(2)             # accessory: no Dock icon
    return app


# ===================== menu bar =====================
_item = None
_target = None
_toggle_mi = None
_status_mi = None


class _Target(NSObject):
    def initWithDaemon_(self, daemon):
        self = objc.super(_Target, self).init()
        if self is None:
            return None
        self._daemon = daemon
        return self

    def toggle_(self, _):
        self._daemon.control.put("toggle")

    def cancel_(self, _):
        self._daemon.control.put("cancel")

    def openConfig_(self, _):
        subprocess.Popen(["open", "-t", str(config.ROOT / "config.txt")])

    def openUserPrompt_(self, _):
        subprocess.Popen(["open", "-t", str(config.USER_PROMPT_PATH)])

    def openSystemPrompt_(self, _):
        subprocess.Popen(["open", "-t", str(config.SYSTEM_PROMPT_PATH)])

    def openLog_(self, _):
        subprocess.Popen(["open", "-t", str(config.STATE_PATH.parent / "daemon.log")])

    def quit_(self, _):
        self._daemon.quit()


def _mi(title, action, target):
    item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(title, action, "")
    if action:
        item.setTarget_(target)
    return item


def build_menu(daemon):
    global _item, _target, _toggle_mi, _status_mi
    _target = _Target.alloc().initWithDaemon_(daemon)
    _item = NSStatusBar.systemStatusBar().statusItemWithLength_(NSVariableStatusItemLength)
    img = NSImage.imageWithSystemSymbolName_accessibilityDescription_("mic.fill", "wtalk")
    if img is not None:
        img.setTemplate_(True)
        _item.button().setImage_(img)
    else:
        _item.button().setTitle_("🎙")

    menu = NSMenu.alloc().init()
    _toggle_mi = _mi("Start Dictation", "toggle:", _target)
    _status_mi = _mi("Ready", "", None)
    _status_mi.setEnabled_(False)
    for it in (_toggle_mi,
               _mi("Cancel", "cancel:", _target),
               NSMenuItem.separatorItem(),
               _status_mi,
               NSMenuItem.separatorItem(),
               _mi("Edit config.txt…", "openConfig:", _target),
               _mi("Edit corrections (user.txt)…", "openUserPrompt:", _target),
               _mi("Edit system prompt…", "openSystemPrompt:", _target),
               _mi("Open log…", "openLog:", _target),
               NSMenuItem.separatorItem(),
               _mi("Quit wtalk", "quit:", _target)):
        menu.addItem_(it)
    _item.setMenu_(menu)


def menu_update(listening, busy, queue_depth):
    if _toggle_mi is not None:
        _toggle_mi.setTitle_("Stop Dictation" if listening else "Start Dictation")
    if _status_mi is not None:
        if listening:
            s = "● Listening"
        elif busy or queue_depth:
            s = f"Cleaning {queue_depth}" if queue_depth else "Cleaning…"
        else:
            s = "Ready"
        _status_mi.setTitle_(s)
    if _item is not None:
        _item.button().setContentTintColor_(
            NSColor.systemRedColor() if listening else None)
