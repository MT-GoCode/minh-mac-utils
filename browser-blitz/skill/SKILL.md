---
name: browser-blitz
description: Drive the user's REAL logged-in Chrome (Default profile) to do a web task — log in, fill a form, click through a flow, search, extract data — using browser-blitz (session manager) + agent-browser (the driver) over SSH to the Mac. Use whenever a task needs a real browser with the user's existing logins, or the user says "in my browser", "on my Chrome", "use my session".
---

# browser-blitz

Drives the user's **real, logged-in Chrome** on the Mac (`ssh mac-personal`). You get a CDP
port fenced to its own tab group; `agent-browser --cdp <PORT>` is the driver. The user's other
tabs are invisible to you — you can only see and touch tabs in your group.

Everything runs over SSH. The Mac shell is **zsh (no word-splitting)** — never store the command
in a shell variable like `AB=`; write the full command each time, or pipe a script with
`ssh mac-personal bash -s <<'EOF' … EOF`.

## 1. Session lifecycle (browser-blitz)

```bash
# START — creates a tab group in the profile, prints the port to drive
ssh mac-personal 'browser-blitz start-session --slug research --profile Default'
#   → stdout: --cdp 9340        (capture this port)
#   --profile Default is the user's real logged-in profile (the default; omit to get it).
#   A NEW window opens (never steals focus). Add --in-last-window to reuse the current window.
#   If the profile is closed, it is launched automatically — this can take a few seconds.

# DRIVE — every browser action is agent-browser --cdp <PORT>
ssh mac-personal 'agent-browser --cdp 9340 open https://example.com'

# SHOW THE USER what you did (raises that window, switches to your last-touched tab)
ssh mac-personal 'browser-blitz bring-to-front --slug research'

# END when done — closes the group's tabs
ssh mac-personal 'browser-blitz end research'         # --keep detaches instead of closing
```

Supporting commands:
```bash
browser-blitz status     # which profiles exist / are installed / live, and their build
browser-blitz list       # your active sessions (slug, profile, port, tabs, last activity)
browser-blitz adopt <slug> <tabId>   # pull an existing tab into your group
```

Rules:
- **One slug per task.** Pick a short name; `end` it when finished.
- **The slug is the fence.** You only ever see tabs in your group. New tabs you open
  (`agent-browser --cdp <PORT> tab new <url>`) auto-join it. The user can hand you a tab by
  dragging it into the group (you'll see it appear); deleting the group ends your session.
- **In `--cdp` mode, do NOT pass** `--profile`, `--session`, `--state`, `--auto-connect`,
  `--extensions`, or `--webgpu` to `agent-browser` — they are rejected or dangerous here.
  `--state`/`--session` restore would inject cookies into the user's live profile. The only
  connection flag you use is `--cdp <PORT>`.
- Don't touch the shim, the extension, or raw ports — `browser-blitz` abstracts all of that.

## 2. agent-browser tools (prefix every one with `--cdp <PORT>`)

**Core loop:** `open` → `snapshot -i` → act on `@eN` refs → **re-snapshot after any page change**
(refs are reassigned each snapshot and go stale on navigation/re-render).

```bash
# navigate
open <url>   read [url]   back   forward   reload   pushstate <url>

# observe (see the Optimizations section — these have huge cost differences)
snapshot            # full a11y tree (verbose)
snapshot -i         # interactive elements only, with @refs (the workhorse)
snapshot -i -s "#main"   # scope to a CSS selector (the real token lever)
snapshot -i -u      # include href urls on links
get text <sel|@ref>   get html <sel>   get attr <sel> <name>   get value <sel>
get title   get url   get count <sel>   get box <sel>   get styles <sel>

# interact  (input is REAL and trusted — the target tab briefly becomes active in its window;
#            this does NOT raise Chrome or steal your OS focus)
click <sel|@ref>   dblclick   hover   focus   fill <sel> <text>   type <sel> <text>
press <key>        # e.g. press Enter, press Control+a, press Backspace
check <sel>   uncheck   select <sel> <val…>   scroll down 500   scrollintoview <sel>
drag <src> <dst>   upload <sel> <file…>   highlight <sel>   # highlight = show the user

# when fill/type does nothing (custom components that intercept key events) — THE common fix.
# This is what makes autocompletes/comboboxes fire; `fill` on a selector often won't.
focus <sel> && keyboard type "text"     # raw keystrokes at the focused element, no selector
keyboard inserttext "text"              # bypasses key events entirely
mouse move 100 200   mouse down left   mouse up left   mouse wheel 400   # raw coords

# dialogs — alert/beforeunload auto-accept; confirm/prompt BLOCK until you answer
dialog status   dialog accept   dialog accept "prompt text"   dialog dismiss

# find WITHOUT a snapshot (no prior observe needed — act blind on known targets)
find role button click --name "Submit"     # roles: button, link, heading, textbox, …
find text "Sign In" click                  # add --exact for exact match
find label "Email" fill "me@x.com"     find placeholder "Search" fill "q"
find testid "submit-btn" click     find first ".card" click     find nth 2 ".card" hover

# wait ON CONDITIONS, not sleeps (default timeout 25s)
wait @e1              # until element appears
wait --text "Done"   wait --url "**/dashboard"   wait --load networkidle   wait --fn "<js>"
wait 2000            # dumb ms wait — last resort only

# cheap state checks — ideal for verifying an action IN THE SAME TURN (a few tokens each)
is visible <sel>   is enabled <sel>   is checked <sel>      # → true / false

# tabs (all stay in your group). Ids are t1,t2,… — `tab 2` is an error, use `tab t2`.
tab                              # list
tab new [url]                    # new tab   |   tab close [t2]   |   tab t2  (switch)
tab new --label docs <url>       # LABEL IT, then `tab docs` — survives renumbering,
                                 # far more robust than t-ids for multi-tab work
# Refs (@eN) belong to the tab that was active when you snapshotted — switch tabs, re-snapshot.
# Don't use `agent-browser close`: it only tears down agent-browser's local daemon (your next
# command silently respawns it) and never closes the user's Chrome. Use `browser-blitz end <slug>`.

# capture — NOTE: the file lands on the MAC. You are not on the Mac. Three steps to SEE it:
#   1. ssh mac-personal 'agent-browser --cdp <PORT> screenshot /tmp/shot.jpg'
#   2. scp -q mac-personal:/tmp/shot.jpg /tmp/shot.jpg
#   3. Read /tmp/shot.jpg          ← only the Read tool actually shows you pixels
# With no path it saves to ~/.agent-browser/tmp/screenshots/ (harder to fetch — always pass one).
screenshot <path.jpg>       # JPEG by default here; ~2.9k vision tokens at retina size,
                            # so `set viewport 800 600` FIRST if you only need the gist
screenshot --annotate <p>   # numbered labels keyed to the last snapshot's @refs
pdf <path>

# extract / debug
eval "<js>"          # run JS in the page, return the result (surgical extraction)
eval --stdin <<'JS'  # multi-line JS without quoting hell
…
JS
console              # captured console.* output      errors   # page errors
network route "**/analytics**" --abort    network requests --filter <pat>    network har start|stop
batch '["get","url"]' '["get","title"]'   # many commands, one process spawn
frame <sel>          # operate inside a same-origin iframe
storage local        # localStorage: `storage local <key>` / `storage local set k v`
cookies              # list cookies (NEVER `cookies clear` — profile-wide, logs the user out)
```

## Worked examples

```bash
# One-turn search-and-extract: navigate, wait on a condition, extract only what's needed.
ssh mac-personal 'agent-browser --cdp 9340 open "https://news.ycombinator.com" && \
  agent-browser --cdp 9340 wait --text "comments" && \
  agent-browser --cdp 9340 eval "JSON.stringify([...document.querySelectorAll(\".titleline>a\")].slice(0,5).map(a=>a.textContent))"'

# Form fill, then VERIFY in the same turn (never spend a turn asking "did it work?").
ssh mac-personal 'agent-browser --cdp 9340 fill "#email" "me@x.com" && \
  agent-browser --cdp 9340 fill "#password" "$PW" && \
  agent-browser --cdp 9340 click "button[type=submit]" && \
  agent-browser --cdp 9340 wait --url "**/dashboard" && \
  agent-browser --cdp 9340 get url'

# Autocomplete/combobox (the pattern that plain `fill` fails on):
#   click the field → keyboard type → snapshot to see the options → click the right one
ssh mac-personal 'agent-browser --cdp 9340 click "@e78" && agent-browser --cdp 9340 keyboard type "Venice"'
ssh mac-personal 'agent-browser --cdp 9340 snapshot -i -s "[role=listbox]"'   # scoped: ~1k tok, not 26k
ssh mac-personal 'agent-browser --cdp 9340 click "@e4"'
```

**What differs through this bridge:**
- **Downloads are NOT intercepted** (verified). `download` won't deliver a file to your path —
  the file saves to Chrome's Downloads folder under its own name. To capture one, read its URL
  (`get attr @ref href`) and fetch it directly (`curl` over SSH; pull cookies first if gated).
- **`react tree/inspect/…` won't work** (verified) — they need a flag set at browser launch,
  which attach mode can't do. `vitals`, `record`, `trace`, `profiler` all work.
- **Same-origin `frame` works** (verified). Cross-origin iframes are expected NOT to be
  reachable (the bridge doesn't auto-attach child targets) — not independently tested.
- Everything else in the list above is verified working against real Chrome (74/74 command
  sweep, each asserted by resulting page state).

## 3. Optimizations (this is where tokens are won or lost)

All numbers measured on a real heavy page (Kayak results). Text tokens ≈ bytes/4.

**A. Climb the observation ladder; stop at the first rung that answers.** Same page, same need:
```
eval targeted extract        25 tok    eval "JSON.stringify([...document.querySelectorAll('.price')].map(e=>e.textContent).slice(0,10))"
get text <scoped selector>   69 tok    get text ".results-list"
snapshot -i -s <container> 1,050 tok    keeps @refs, full fidelity, one region
snapshot -i (whole page)  25,800 tok    ← a heavy page's whole tree; avoid
snapshot (full tree)      52,900 tok
network requests (raw)    82,800 tok    ← never dump; always --filter
```
`eval` when you know exactly what data you want. `get text <sel>` for a region's text.
`snapshot -i -s` when you need refs but only for one part. Whole-page `snapshot -i` is fine on
simple pages (a few hundred tokens) — it's commercial pages where it explodes.

**B. Act blind when you know the target.** `find role button click --name Submit`,
`click "#id"`, `fill @ref` (from an earlier snapshot) — **zero** observation cost. Re-observing
a page you already understand is the most common waste.

**C. One turn, many commands — including the verification read.** CLI calls are ~11ms; your
*turns* are seconds. Chain a whole flow in ONE shell invocation so "did it work?" never costs a
round trip:
```bash
ssh mac-personal 'agent-browser --cdp 9340 fill "#q" "hi" && agent-browser --cdp 9340 click "#go" && agent-browser --cdp 9340 wait --url "**/results" && agent-browser --cdp 9340 get text ".summary"'
```

**D. Wait on conditions, not sleeps** (section 2) — each avoided sleep saves a re-observe.

**E. Screenshots: on-failure and final-proof only.** They're already JPEG here (small files).
But vision cost is **pixel-driven**, so to cut TOKENS shrink the viewport first:
`set viewport 800 600` before `screenshot`. `--full` can be 10+ MB — never.

**F. On any failure (✗), gather the diagnosis in the SAME turn:**
```bash
ssh mac-personal 'agent-browser --cdp 9340 get url; agent-browser --cdp 9340 console | tail -20; agent-browser --cdp 9340 snapshot -i -s "<region>"'
```
All three are TEXT (~1.7k tok total) and actionable — fresh `@eN` refs to click, exact error
strings to read. Diagnose in the failing turn; don't spend a round trip asking "what happened".

**No failure auto-captures anything.** A failed command prints text only
(`✗ Element not found: #x. Verify the selector…`). Deliberately do NOT put a screenshot in
this bundle: an image costs ~2.9k vision tokens (more than the whole text bundle), needs
capture→scp→Read over SSH, and gives you no refs to act on. Screenshot ONLY when the question
is inherently visual — layout looks wrong, or an element is in the DOM but not visible. To just
show the user the result, `browser-blitz bring-to-front --slug <task>` costs zero tokens.

**G. Hazards:**
- **`--json` silently bypasses `--max-output`.** `snapshot -i --max-output 500` = 570 B;
  add `--json` and it's uncapped (194 KB on Kayak). Never pair `--json` with a big observation.
- There is **no built-in output cap** — pass `--max-output N` yourself on anything unbounded.
- **Block junk before heavy navigation:** `network route "**/analytics**" --abort` → faster
  loads and smaller snapshots.

**H. Snapshot flag facts (source-verified):** `-c` (compact) and `-d N` (depth) are
near-no-ops WITH `-i` (every `-i` line already has a `ref=`, and depth counts only interactive
ancestors, which rarely nest). They matter only WITHOUT `-i`. The real lever is `-s <selector>`
scoping.

**If you remember two things:** the ladder (A) and one-turn-with-verification (C). Those are
~90% of the win.
