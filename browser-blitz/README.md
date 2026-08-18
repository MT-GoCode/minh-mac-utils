# browser-blitz / browser-blitz

Drive your **real, logged-in Chrome** with `agent-browser` (or any CDP client), with each
agent fenced into its own tab group.

```bash
./install.sh                                    # idempotent; safe to re-run
browser-blitz status                            # which profiles are bridged
browser-blitz start-session --slug work         # prints e.g. "--cdp 9340"
agent-browser --cdp 9340 open https://example.com
agent-browser --cdp 9340 snapshot -i
browser-blitz bring-to-front --slug work        # show yourself what it's doing
browser-blitz end work                          # closes the group
```

## Why it exists

- Chrome 136+ ignores `--remote-debugging-port` on the default user-data-dir, so no CDP tool
  can reach a profile that holds real logins.
- The M144 `chrome://inspect` toggle exposes no `/json` discovery endpoints (all 404) and
  re-prompts on **every** connection — unusable unattended.
- Copying a profile to a custom user-data-dir loses all logins (cookies copy but don't
  decrypt; a different key is used).
- `chrome.debugger` in an extension is the only no-prompt route in. Permission is granted
  once, at install.

So: an extension holds `chrome.debugger`, and a local shim impersonates a Chrome debug
endpoint on top of it. **`agent-browser` is unmodified** — it believes it's talking to Chrome.

```
agent-browser --cdp 9341 ─┐
browser-blitz CLI ────────┤
                          ▼
                    shim (LaunchAgent)
                     ├─ 9341 slug "work"     → tab group
                     └─ 9342 slug "research" → tab group
                          │ ws 9334
                    extension (per profile) → chrome.debugger → tabs
```


## Lifecycle

**Nothing runs when nothing is running.** With no active session, extension service workers
sleep, no keepalive pings are sent, and profiles report `cold`.

Starting a session on a cold profile:

1. Profile exists in `Local State`? else fail.
2. Bridge installed in it (read from `Secure Preferences`)? else fail with the load path.
3. Already connected and labelled? use it.
4. Otherwise **nudge it**: capture the frontmost app, then
   `open -n -a "Google Chrome" --args --profile-directory=<dir> about:blank`.
   NOTE: `--profile-directory` takes the DIRECTORY name (`Profile 5`), not the display name
   (`RemoteAgent`). A display name silently creates a brand-new empty profile.
5. Wait for either a new connection, or an existing one to gain a window. That connection IS
   this profile, so it is told its `profileDir` and the extension persists it. This is the only
   moment the mapping is certain: Chrome never tells an extension which profile it lives in.
6. Restore focus to whatever app was frontmost.
7. Window placement: the one just launched (never stranded), or `--in-last-window`, or a new
   one via `chrome.windows.create({focused:false})`.

**Reconnect direction is forced.** The extension dials out; an MV3 extension cannot listen on
a port, so the shim can never dial in. On failure it retries with backoff 2s, 4s, 8s, then
holds at 10s. The worker itself dies after ~30s without pings, so a down shim costs roughly
four attempts per wake, and a 1-minute alarm - the only wake source that survives worker
death - restarts the cycle.

**Keepalive is scoped to profiles with an active slug.** Pinging idle profiles would pin their
service workers alive forever for nothing.

## Gotchas found the hard way

- `chrome.tabGroups.move(id, {index:-1})` without `windowId` moves the group to a DIFFERENT
  window. Every group teleported until it was pinned explicitly.
- A freshly created tab reports `url: ""` before settling to `about:blank`; filtering on empty
  url made a just-opened window look empty.
- Tab ids cross the wire as strings; `chrome.tabs.group` and `chrome.debugger` require numbers.
- Each profile has its OWN extension copy. Reloading in one profile's `chrome://extensions`
  does nothing for another. A cold profile picks up new code automatically when warmed.
- `Network.clearBrowserCookies` is profile-wide and signs you out of everything. Refused
  unless the session was started with `--allow-destructive`.

## The fence

A slug **is** a tab group, with its own CDP port. `Target.getTargets` only advertises tabs in
that group, so anything outside it cannot be attached to, read, or navigated. Structural, not
a policy check.

| You do | Agent sees |
|---|---|
| Drag a tab **into** the group | `targetCreated` — this *is* how you hand it a page |
| Drag a tab **out** | `targetDestroyed` |
| Delete/ungroup the group | slug ends — your kill switch |
| Move group to another window | nothing; transparent |

## Setup (one manual step)

The extension must be loaded once per profile, by hand:

1. `chrome://extensions` → enable **Developer mode**
2. **Load unpacked** → `extension/`

`browser-blitz status` then reports each profile as `installed, live` / `installed, cold`
(open a window in it) / `not installed`.

## Verified

| Suite | Result |
|---|---|
| `verify.js <port>` — every command, each asserted by resulting page state vs real Chrome | **74/74** |
| `parity.sh` / `parity2.sh` / `parity3.sh` — grouped sweeps vs real Chrome | **91/91** |
| `shimtest.js` — slug layer (mock extension) | **16/16** |
| `isolation.js` — multi-slug isolation (mock) | **10/10** |

Every `verify.js` check runs a command then reads back an observable effect (a click asserts the
handler fired with `isTrusted === true`, `fill` asserts the value, `scroll` asserts `scrollY`
moved), so a command that silently no-ops fails the test.

Latency, measured end to end (through `chrome.debugger` into real Chrome):

```
Runtime.evaluate    0.47ms p50 / 0.63ms p95
shim's own overhead 0.13ms
(AppleScript, the alternative it replaced: ~111ms)
```

`batch` and `network route` both pass — one invocation for N operations, and request blocking.

## Known limits

- `chrome://`, the Web Store, and other extensions' pages can never be attached to.
- One debugger client per tab: opening DevTools on a tab an agent is driving breaks one of them.
- `agent-browser --session` isolation doesn't apply — every slug is the same real browser.
  Parallel *tabs* work; parallel *browsers* don't.
- Chrome shows its own "extension is debugging this browser" banner. Doubles as marking.
- `errors` captures the right count but renders empty detail (agent-browser rendering; the
  exception data crosses the bridge intact).
- **Downloads are not intercepted.** `agent-browser download` saves to Chrome's normal
  Downloads folder under Chrome's own filename, so it will not appear at the path the client
  asked for. To capture a file, read its URL (`get attr @ref href`) and fetch it directly
  (e.g. `curl` over SSH); pull the tab's cookies first if the download is auth-gated.
- **Input needs the tab to be the ACTIVE tab of its window — then it is genuinely trusted.**
  Chrome discards `Input.*` aimed at a non-active tab (returns `{}`, no effect). The window does
  NOT need OS focus — verified with Chrome fully backgrounded behind another app. So the shim
  activates the target tab before any `Input.*` (only input; reads/navigation stay quiet in the
  background), and the resulting events are real: `isTrusted === true`. Activating a tab within
  an already-backgrounded window does not raise Chrome, so this never steals your focus. The
  only visible effect is that the agent's active tab within its own group changes.

## Files

```
cdpshim.js     the daemon: per-slug CDP endpoints, group lifecycle, cold-profile warming
browser-blitz  thin CLI: status, start-session, list, adopt, bring-to-front, end,
               orphans, cleanup, ping
extension/     MV3 extension: chrome.debugger relay + tab/group management
install.sh     idempotent installer; --uninstall to remove
verify.js      per-command sweep, each asserted by page state (real Chrome)
parity*.sh     grouped parity sweeps (real Chrome)
shimtest.js    slug-layer tests (mock extension, no Chrome needed)
isolation.js   multi-slug isolation tests
bench.js       shim-only latency
latency.js     real end-to-end latency
```

## Uninstall

```bash
./install.sh --uninstall          # service, CLI, state
# then: chrome://extensions → remove "browser-blitz bridge"
```
