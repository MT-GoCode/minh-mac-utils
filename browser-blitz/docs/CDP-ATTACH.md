# agent-browser in --cdp attach mode (what the shim must emulate)

Source-verified against agent-browser v0.34.0. This is the CDP surface a `--cdp <port>` client
actually exercises when it thinks our shim is Chrome. Everything here is either already handled
or a deliberately-accepted limit.

## Connect handshake (browser.rs discover_and_attach_targets)

1. `Target.setDiscoverTargets {discover:true}`  — browser-level → shim acks, then emits
   `Target.targetCreated` for the slug's group tabs.
2. `Target.getTargets`  — browser-level → shim returns ONLY the slug's group tabs (the fence).
3. `Target.attachToTarget {flatten:true}` per page → shim mints a sessionId.
4. Per session: `Page.enable`, `Runtime.enable`, `Network.enable` → relayed to chrome.debugger.
5. `Target.setAutoAttach {autoAttach:true, waitForDebuggerOnStart:true, flatten:true}` (session)
   → **shim ACKs, does NOT forward.** Forwarding it to chrome.debugger would pause child targets
   that never receive `runIfWaitingForDebugger`, hanging them. Acking is correct.
6. `Runtime.runIfWaitingForDebugger` (fire-and-forget) → shim acks.

## Browser-level methods — handled vs not-reached

Handled: `Target.setDiscoverTargets/getTargets/attachToTarget/detachFromTarget/activateTarget/
createTarget/closeTarget/setAutoAttach/getBrowserContexts/createBrowserContext/
disposeBrowserContext`, `Browser.getVersion`, `Runtime.runIfWaitingForDebugger`,
`Browser.setDownloadBehavior` + `Page.setDownloadBehavior` (acked; see Downloads).

NOT reached in attach mode (verified empirically — `get box`, `set viewport`, `window new` all
resolve via session-level calls, no "no session for Browser.*" ever fired):
`Browser.getWindowForTarget`, `Browser.grantPermissions`, `Browser.setContentsSize`,
`Browser.setWindowBounds`. These are launch-mode paths. No handlers added — adding unused ones
would be dead code.

`setDownloadBehavior` is issued in THREE shapes (browser-level, session-level `allowAndName`,
per-context). The shim acks all three and does NOT intercept — the file saves to Chrome's normal
Downloads folder. See README "Downloads" for why interception was removed.

## Rejected outright when `--cdp` is set (client-side, before reaching us)

`--extensions`, `--profile`, `--provider`, `--auto-connect`, `--webgpu`, `--allowed-domains`.
Users must not pass these with `--cdp`.

## Silent behavior differences (no error, just different)

- The client hardcodes `headless:true` on every CDP connection and never idle-shuts-down an
  attached browser unless `AGENT_BROWSER_IDLE_TIMEOUT_MS` is set. Harmless for us.
- **`--state` / `--session` restore INJECTS cookies/storage into the live logged-in profile**
  (external CDP is exempt from the clean-relaunch guard). Dangerous on a real profile — don't.
- A launch-hash change or dropped connection triggers a "relaunch" (close + reconnect). We keep
  the slug/port stable, so this only manifests as the client reconnecting to the same endpoint.

## Known limit: cross-origin iframes

Because the shim ACKs `setAutoAttach` instead of forwarding it, child targets (cross-origin
iframes) are never auto-attached, so commands cannot reach inside them. Same-origin iframes
(via `frame`) work. This is the price of not risking the child-target hang; accepted.

## Why NOT the "direct-page" provider route

agent-browser has a `direct_page` provider-plugin mode (connect_cdp_direct) that skips ALL
`Target.*`/`Browser.*` and sends only `Page/Runtime/Network.enable` with session=None — it would
delete the shim's entire browser-level emulation surface. We deliberately do NOT use it: it is
one-page-per-connection, which is incompatible with the slug model (a slug is a tab GROUP with
multiple tabs). The Target.* emulation is what buys multi-tab fencing. Worth revisiting only if
a single-tab-per-slug model ever becomes acceptable.
