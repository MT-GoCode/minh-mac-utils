---
name: browser-blitz
description: Drive the user's real, logged-in Chrome. `bb` manages sessions (fenced ⚙ tab groups); `playwright-cli` drives the pages inside them.
allowed-tools: Bash(bb:*), Bash(browser-blitz:*), Bash(playwright-cli:*)
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

`playwright-cli` costs a few hundred ms per invocation regardless of what it does, so N commands
is N startups. **Measured: 10 calls as 10 invocations = 710 ms; the same 10 chained inside one
call = 65 ms. 11x.**

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

## Rule 3 — return the answer from inside the code, don't re-read the page

`playwright-cli snapshot` prints the whole accessibility tree **inline** — 5-15k tokens on a real
page. Running it to confirm a click worked is the most common waste there is.

- **Return what you need from inside `run-code`**: `return page.url()`, `return await
  page.getByRole('alert').innerText()`. A few tokens instead of thousands.
- **Assert in the code and let it throw**: `await page.waitForURL(...)`, `await
  expect(locator).toBeVisible()`. A failure is an error you can read, not a page you have to.
- **`find` greps the snapshot** with surrounding context, far cheaper than reading it:
  `playwright-cli -s=<slug> find "Add to cart"`
- **`snapshot --filename=x.yml`** writes it to disk instead of printing it, when you want it
  saved rather than read.

If you really must compare two page states, save both and `diff` them — but note a full-page
navigation makes the diff *larger* than the page, so only do this for in-page changes:

```bash
playwright-cli -s=work --raw snapshot > /tmp/before.yml
playwright-cli -s=work run-code "async page => { … }"
playwright-cli -s=work --raw snapshot > /tmp/after.yml
diff /tmp/before.yml /tmp/after.yml
```

## Rule 4 — never run `playwright-cli open`

`open` launches a **new** Playwright browser and detaches the session from the user's Chrome —
losing every login, which is the entire point of this tool. Same for `--browser`, `--profile`,
`--persistent` and `--mobile`, which are all options of `open`.

A bb session is already an open tab in the user's real browser. You navigate it with
`page.goto(...)` inside `run-code`. There is no open step.

## `bb` reference

```bash
bb new-session work [--profile Default]   open a ⚙ group and bind playwright-cli -s=work
bb resume work                            bring a closed session back (adopts it if Chrome restored it)
bb delete-session work [--keep]           close the group; --keep leaves the tabs, ungrouped
bb list                                   slug, profile, status, tab count, CDP url
bb list-tabs [--profile Default]          every tab in the profile + which session owns it
                                          — the ONLY way to find a tabId for grab-tab
bb identify [--profile "Profile 1"]       wake and identify a profile, create nothing
bb extension-status                       which Chrome profiles have the bridge installed
bb restart                                restart the shim

bb work bring-to-front                    raise the window so the user can watch
bb work grab-tab 4711 --duplicate         COPY one of the user's tabs into the session
bb work grab-tab 4711                     MOVE it — it leaves the user's window. Prefer --duplicate.
bb work release-tab 4711                  hand a tab back out (it stays open, just ungrouped)
```

`bb list` statuses: **LIVE** (group is open) · **CLOSED** (profile visible, group gone — `resume`
it) · **UNKNOWN** (that Chrome profile isn't running) · **UNTRACKED** (a `⚙` group with no record).

## Commands you must NOT run

A bb session is a tab group in the user's **real, logged-in Chrome**, already bound. Two whole
categories of `playwright-cli` command assume the opposite — that the browser is yours, disposable,
and yours alone. They are not.

### Never — these break the session binding

| command | what it actually does |
|---|---|
| `open` | Launches a **brand-new** browser (Chrome for Testing) under that session name and detaches from the user's Chrome. No logins, no cookies, no extensions. bb re-binds within ~15s, so you and bb then fight over the name. **There is no open step — a bb session is already an open tab.** |
| `attach` | bb already attached it. Re-attaching to anything else does the same damage as `open`. |
| `close` / `detach` / `browser.close()` | Drops the connection only — it does NOT quit the user's Chrome, and bb re-binds within ~15s. So it achieves nothing except confusing yourself. To end a session: `bb delete-session <slug>`. |
| `close-all` / `kill-all` | Kills **every** session on the machine, including other agents' work in progress. Never. |
| `delete-data` | Deletes the session's user data. |
| `install` / `install-browser` | Already done by bb's installer. |

### Never — these reach past the tab-group fence into the whole profile

The fence contains **tabs**. It does not contain cookies, storage, or window state — those belong
to the user's whole profile, and every site they are signed into.

| command | what it actually does |
|---|---|
| `cookie-clear` | Signs the user out of **everything**. bb refuses it, but do not try. |
| `cookie-set` / `cookie-delete` | Edits real logins for real sites. |
| `state-save` | Writes **every cookie in the profile** to a file on disk. |
| `state-load` | Injects a cookie jar into the user's real profile. |
| `localstorage-clear` / `sessionstorage-clear` | Wipes real site data for the current origin. |
| `network-state-set offline` | Takes the browser offline — including the tabs the user is reading. |
| `route` / `unroute` | Intercepts and mocks requests. Fine on a throwaway browser; on the user's real one it silently changes what they see. |
| `resize` | Resizes the user's actual window. |

`cookie-list`, `cookie-get`, `localstorage-get/list` are **reads** and are fine.

### Careful — these hang or surprise

`pause-at`, `resume`, `step-over` are the debugger — they stop execution and wait. `show` opens a
dashboard the user has to interact with. `dialog-accept`/`dialog-dismiss` answer a real dialog, so
only use them when you know one is open.

### Everything else is safe

`goto` `click` `dblclick` `fill` `type` `press` `hover` `select` `check` `uncheck` `drag` `drop`
`upload` `go-back` `go-forward` `reload` `snapshot` `find` `eval` `run-code` `screenshot` `pdf`
`tab-list` `tab-new` `tab-select` `tab-close` `console` `requests` `request*` `response*`
`generate-locator` `highlight` `tracing-*` `video-*` `mouse*` `key*`

New tabs from `tab-new` and `context.newPage()` land **inside** the session's group — the fence
holds for anything you open.

### Ending a session

Always `bb delete-session <slug>`, never a `playwright-cli` command. Add `--keep` to leave the
tabs open and just ungrouped. And do end it — sessions never expire, and each one you abandon is
a tab group left in the user's browser.

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
- **Clean up when you are done**: `bb delete-session <slug>`. Sessions do not expire, and every
  one you leave behind is a tab group cluttering the user's browser.
- **Don't run `playwright-cli close`** on a bb session — use `bb delete-session`. `close` kills the
  browser connection, not the group.
- **`bb delete-session` closes the tabs.** Use `--keep` to leave them open and just ungrouped.
- **Closing the last page** ends the session (Chrome deletes a group when its last tab leaves).
  `bb list` will show it `CLOSED`; `bb resume <slug>` brings it back.
- **Cross-origin iframes work** — `page.frame_locator(...)` reaches into them. So do new tabs:
  `page.context().newPage()` opens inside the session's group, never outside it.
