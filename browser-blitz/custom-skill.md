---
name: browser-blitz
description: Drive the user's real, logged-in Chrome. `bb` manages sessions (fenced ⚙ tab groups); `playwright-cli` drives the pages inside them.
allowed-tools: Bash(bb:*) Bash(browser-blitz:*) Bash(playwright-cli:*)
---

# Driving the user's real Chrome

Two tools, one job each.

| | |
|---|---|
| **`bb`** | sessions: create, resume, delete, list. A session is a `⚙ <slug>` **tab group** in the user's own Chrome. |
| **`playwright-cli -s=<slug>`** | everything on the page: navigate, click, fill, read. |

`bb` binds `playwright-cli -s=<slug>` to the session automatically the moment the group is live.
There is no attach step for you to run.

```bash
bb new-session work
playwright-cli -s=work run-code "async page => { await page.goto('https://example.com'); return page.title() }"
```

**This is the user's real browser.** Their logins, their cookies, their history. Tabs you open
land inside the `⚙` group and cannot escape it — but everything you do there is real. Don't buy
things, send things or delete things without being asked to.

## Rule 1 — chain. This is the single biggest thing.

`playwright-cli` costs ~370 ms per invocation regardless of what it does. Ten separate commands
is ~3.7 s of process startup; the same ten inside one `run-code` is one startup.

**Measured on this machine: 10 calls as 10 invocations = 710 ms. As one chained call = 65 ms.**

So do not do this:

```bash
playwright-cli -s=work click e14        # ✗ one action per invocation
playwright-cli -s=work fill e15 "SFO"
playwright-cli -s=work click e22
```

Do this:

```bash
playwright-cli -s=work run-code "async page => {
  await page.getByRole('combobox', { name: /Where from/i }).fill('SFO');
  await page.getByRole('option',   { name: /San Francisco/ }).click();
  await page.getByRole('button',   { name: 'Search' }).click();
  await page.waitForURL(/flights\/search/);
  return await page.getByRole('listitem').first().innerText();
}"
```

`run-code` gets the whole Playwright API and returns whatever you return. Loops and conditionals
work, so a repeated sequence is written once instead of predicted N times.

## Rule 2 — ground your locators, then guess

`getByRole('button', { name: 'Search' })` addresses an element you have never seen, and Playwright
resolves it at runtime with auto-waiting. On a page you know (Google, GitHub, Amazon) just write
the code — a wrong guess throws, and that costs one turn.

On an unfamiliar page take **one** snapshot first, read the real names, then write one chained
`run-code`. Don't snapshot between every action.

```bash
playwright-cli -s=work snapshot            # writes a .yml to disk, prints the path
playwright-cli -s=work find "Add to cart"  # grep the snapshot with context — cheaper than reading it
```

## Rule 3 — don't re-read a snapshot to find out nothing changed

Every command prints a snapshot **path**, not the snapshot. Reading it is your choice, and on a
real page it is 5–15k tokens. Reading it to confirm a click worked is the most common waste there
is.

- Return the answer **from inside `run-code`** — `return page.url()`, `return
  await page.getByRole('alert').innerText()`. That is a few tokens instead of thousands.
- Assert in the code and let it throw: `await page.waitForURL(...)`, `expect`-style checks.
- If you must compare page states, diff two saved snapshots — but note a full navigation makes
  the diff **larger** than the page. Diff only for in-page changes.

```bash
playwright-cli --raw snapshot > /tmp/before.yml
playwright-cli -s=work run-code "async page => { … }"
playwright-cli --raw snapshot > /tmp/after.yml
diff /tmp/before.yml /tmp/after.yml
```

## Rule 4 — cheaper pages

`playwright-cli open --mobile` renders the mobile layout: fewer elements, much smaller snapshots.
Use it whenever a mobile page would still answer the question.

## `bb` reference

```bash
bb new-session work [--profile Default]   open a ⚙ group and bind playwright-cli -s=work
bb resume work                            bring a closed session back (adopts it if Chrome restored it)
bb delete-session work [--keep]           close the group; --keep leaves the tabs, ungrouped
bb list                                   slug, profile, status, tab count, CDP url
bb identify [--profile "Profile 1"]       wake and identify a profile, create nothing
bb extension-status                       which Chrome profiles have the bridge installed
bb restart                                restart the shim

bb work bring-to-front                    raise the window so the user can watch
bb work grab-tab 4711 [--duplicate]       pull a tab the user already has open into the session
bb work release-tab 4711 [--duplicate]    hand a tab back out
```

`bb list` statuses: **LIVE** (group is open) · **CLOSED** (profile visible, group gone — `resume`
it) · **UNKNOWN** (that Chrome profile isn't running) · **UNTRACKED** (a `⚙` group with no record).

## Things that will bite you

- **The user can see and touch everything.** They may drag a tab in or out mid-run; the group is
  the source of truth, so just re-read it.
- **CAPTCHAs and 2FA**: stop and ask. The user is right there and can tap it — that is the point
  of driving their real browser rather than a headless one.
- **Downloads don't fire events** through the extension bridge (`Browser.setDownloadBehavior` is a
  no-op on `chrome.debugger`). The file still saves to Chrome's Downloads folder; read the URL and
  fetch it directly if you need the bytes.
- **A page a password manager injects into may refuse to attach.** `bb list` shows it; navigating
  away and back usually clears it.
- **Don't run `playwright-cli close`** on a bb session — use `bb delete-session`. `close` kills the
  browser connection, not the group.
- **Closing the last page** ends the session (Chrome deletes a group when its last tab leaves).
  `bb list` will show it `CLOSED`; `bb resume <slug>` brings it back.
- **Cross-origin iframes work** — `page.frame_locator(...)` reaches into them. So do new tabs:
  `page.context().newPage()` opens inside the session's group, never outside it.
