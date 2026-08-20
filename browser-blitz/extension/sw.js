// browser-blitz-bridge — the half of the job CDP cannot do.
//
// Chrome exposes tab groups, windows and tab membership only to extensions: the CDP protocol
// has 52 domains and no Tabs domain at all. That is the entire reason this file exists. Page
// driving is Playwright's job — it reaches these tabs through the shim's CDP endpoint, and every
// command it sends is forwarded verbatim to chrome.debugger.
//
// Waking up. Chrome kills an idle MV3 service worker after ~30s and a pending setTimeout dies
// with it, silently. Three things revive it:
//   - chrome.tabs.onCreated — the cold-launch handshake depends on this. The shim wakes a
//     profile by opening a window in it; without this listener that launch fires nothing.
//   - chrome.alarms — the backstop, browser-backed so it survives worker death. Armed
//     unconditionally at top level, NOT only in onclose: a killed worker never runs onclose,
//     which is exactly the case it covers. Chrome floors the period at 1 minute.
//   - onInstalled / onStartup.
// The 2s retry chain is only the fast path for a worker still alive. The shim also pings
// profiles holding a live session, which keeps the worker resident so commands land and the
// rename snap-back can hear a rename.
const SHIM_URL = 'ws://127.0.0.1:9334';
const TITLE_PREFIX = '⚙ ';
const SLUG_FROM_TITLE = /^⚙\s*(.+)$/;
const RETRY_MS = 2000;
const ALARM_MINUTES = 1;
const PUSH_DEBOUNCE_MS = 120;
const ATTACH_RETRY_MS = 2000;
const PROTOCOL_VERSION = '1.3';

let ws = null;
let owned = new Map();          // groupId -> slug   (mirror of chrome.storage.session)

// Debugger sessions. Deliberately NOT in storage.session: unlike `owned` this is not a fact we
// chose, it is a property of the live browser, and a worker restart re-derives it on the next push.
const attached = new Set();     // tabId
const failed = new Map();       // tabId -> human reason
let lastSent = null;
let pushTimer = null;

const slugFromTitle = (t) => {
  const m = SLUG_FROM_TITLE.exec(t || '');
  return m ? m[1].trim() : null;
};

// ---------------------------------------------------------------- state, loaded once
//
// Identity is random and persisted forever. Email was tried and dropped: it only bought a
// shortcut to resolving a signed-in profile's directory, and two profiles on one Google account
// share an email.
//
// `owned` lives in storage.session — in memory, survives worker death, cleared when the browser
// closes, which is exactly how long a groupId stays valid.
//
// Read ONCE here and used from memory after. Storage reads are async: two handlers that each
// read-modify-write clobber each other, and a handler running before the read finishes sees
// "nothing owned" and takes the wrong branch — that is how a rename sticks. This promise must
// never reject: every handler awaits it, and a rejection would wedge the worker while the socket
// stayed open, reporting CONNECTED and timing out every command.
const ready = (async () => {
  let identity = null;
  try {
    const s = await chrome.storage.local.get('identity');
    if (typeof s.identity === 'string') identity = s.identity;
  } catch {}
  if (!identity) {
    identity = 'p-' + Math.random().toString(36).slice(2, 10);
    try { await chrome.storage.local.set({ identity }); } catch {}
  }
  try {
    const s = await chrome.storage.session.get('owned');
    if (s.owned && typeof s.owned === 'object') {
      owned = new Map(Object.entries(s.owned).map(([k, v]) => [Number(k), v]));
    }
  } catch {}
  return identity;
})().catch(() => 'p-' + Math.random().toString(36).slice(2, 10));

function saveOwned() {
  const obj = {};
  for (const [k, v] of owned) obj[k] = v;
  chrome.storage.session.set({ owned: obj })
    .catch((e) => console.log('[bb] could not save owned:', e));
}

// ---------------------------------------------------------------- attach
//
// A tab is driveable or it carries a reason it isn't.
//
// chrome.debugger.attach grants the tab's WHOLE frame tree, so Chrome refuses when any frame
// belongs to another extension — and reports it as a chrome-extension:// URL error on a page
// that is plainly https. Password managers inject exactly such a frame into login forms. The
// check runs at ATTACH time only, so attaching while the tab is still blank survives every later
// navigation, including into that login page. That is why we attach on group-join, not lazily.
function attachReason(msg) {
  if (/chrome-extension:\/\/ URL of different extension/.test(msg)) {
    return 'a password manager extension has a frame on this page — navigate away, or disable it in chrome://extensions';
  }
  if (/another debugger|already attached/i.test(msg)) {
    // Deliberately vague about WHO, because we cannot find out. TargetInfo.attached is
    // documented only as "True if debugger is already attached", never whose.
    return 'another debugger client is attached to this tab';
  }
  return msg;   // verbatim: attach errors are free-text, not codes. Codify only what we see.
}

async function tryAttach(tabId) {
  // Clear on the early return too: if a tab reached `failed` before `ready` hydrated, nothing
  // else removes it — sweepAttach only prunes tabs that LEFT the session, and onDetach never
  // fires for an attachment we never made.
  if (attached.has(tabId)) { failed.delete(tabId); return; }
  try {
    await chrome.debugger.attach({ tabId }, PROTOCOL_VERSION);
    attached.add(tabId);
    failed.delete(tabId);
  } catch (e) {
    const msg = String((e && e.message) || e);
    // "Already attached" is ambiguous — DevTools, another tool, or OUR OWN session surviving a
    // worker restart (`attached` is worker memory and starts empty every time). detach settles
    // it without guessing: it only succeeds on a session WE hold.
    if (/already attached/i.test(msg)
        && await chrome.debugger.detach({ tabId }).then(() => true, () => false)) {
      return tryAttach(tabId);
    }
    failed.set(tabId, attachReason(msg));
  }
}

// Relayed unconditionally, tagged with the tab and (for out-of-process iframes) the child
// sessionId. Playwright DEPENDS on this: it enables Page/Runtime/Network itself and drives off
// the resulting events. Dropping them here would hang every navigation it waits on.
chrome.debugger.onEvent.addListener((source, method, params) => {
  send({ type: 'cdpEvent', tabId: source.tabId, sessionId: source.sessionId, method, params });
});

chrome.debugger.onDetach.addListener((source, reason) => {
  const id = source.tabId;
  if (id == null) return;
  attached.delete(id);
  // A human's doing — record it and let the retry loop pick it up when it clears. Chrome has no
  // "debugger became available" signal, and re-attaching immediately would fight whoever did it.
  if (reason === 'canceled_by_user') failed.set(id, 'DevTools is open on this tab');
  else failed.delete(id);
  send({ type: 'cdpDetached', tabId: id, reason });
});

// Covers a refusal that clears itself with no tab event to announce it — closing DevTools is the
// motivating case. No-op whenever `failed` is empty, so it costs nothing normally.
setInterval(async () => {
  if (!failed.size) return;
  for (const id of [...failed.keys()]) {
    if (!(await chrome.tabs.get(id).catch(() => null))) { failed.delete(id); continue; }
    await tryAttach(id);
  }
}, ATTACH_RETRY_MS);

async function sendCdp(tabId, method, params, sessionId) {
  if (!attached.has(tabId)) {
    await tryAttach(tabId);
    // Report the human reason rather than Chrome's raw "not attached", which describes our
    // timing, not the cause.
    if (!attached.has(tabId)) throw new Error(failed.get(tabId) || 'could not attach to this tab');
  }
  return chrome.debugger.sendCommand(sessionId ? { tabId, sessionId } : { tabId }, method, params || {});
}

// Runs on every push, so tab events are the trigger for both halves and no timer is needed.
//
// Detaching matters as much as attaching: a tab that leaves a session (released, dragged out,
// ungrouped) must stop being debugged, or we hold a session on a tab that is no longer ours and
// Chrome keeps showing its debugging banner over it.
async function sweepAttach(sessionTabs) {
  for (const id of [...attached]) {            // prune first: never attach what we are dropping
    if (sessionTabs.has(id)) continue;
    // Forgotten only once the detach is CONFIRMED. Dropping it first and failing the detach
    // leaves us holding a session we no longer believe in, with nothing left to clear the banner.
    if (await chrome.debugger.detach({ tabId: id }).then(() => true, () => false)) attached.delete(id);
  }
  for (const id of [...failed.keys()]) if (!sessionTabs.has(id)) failed.delete(id);
  for (const id of sessionTabs) await tryAttach(id);
}

// ---------------------------------------------------------------- sessions

// Refreshes `owned` and resolves duplicates. Two ⚙ groups with one slug is a state to resolve,
// not to sit in: the newer one is closed. Recovery is `resume`, plus Chrome's reopen-closed-group.
async function tidy() {
  const all = (await sortedGroups()).filter((g) => slugFromTitle(g.title));   // oldest first
  const seen = new Set(); const kept = []; const closed = [];

  for (const g of all) {
    const slug = slugFromTitle(g.title);
    if (seen.has(slug)) {
      const tabs = await chrome.tabs.query({ groupId: g.id });
      closed.push({ slug, tabCount: tabs.length });
      if (tabs.length) await chrome.tabs.remove(tabs.map((t) => t.id));
      owned.delete(g.id);
      continue;
    }
    seen.add(slug); kept.push(g); owned.set(g.id, slug);
  }

  // Forget groups that are gone OR no longer carry a ⚙ title. The second half matters: a group
  // renamed away while the worker was dead still exists, so an existence check alone would keep
  // it in `owned` forever, never re-examined by the rename handler.
  const live = new Set(kept.map((g) => g.id));
  for (const gid of [...owned.keys()]) if (!live.has(gid)) owned.delete(gid);
  saveOwned();
  return { groups: kept, closed };
}

// Serialised. Two callers can be in flight at once — sock.onopen and the debounce timer, both
// woken by the same chrome.tabs.onCreated during a cold start — and both await inside tidy(). If
// the one that started first finishes last it latches `lastSent` to a stale payload.
let pushChain = Promise.resolve();
const pushNow = () => (pushChain = pushChain.then(doPush, doPush));

// The one shape a session has. Takes its groups as an argument rather than calling tidy()
// itself: tidy closes duplicate groups AND THEIR TABS, so a read must never reach it.
async function projectSessions(groups) {
  const ids = new Set(groups.map((g) => g.id));
  const all = (await chrome.tabs.query({})).filter((t) => ids.has(t.groupId));
  return groups.map((g) => ({
    slug: slugFromTitle(g.title),
    // Fixed shape on purpose: raw Chrome tab objects carry fields that flicker while loading
    // (status, favIconUrl, partial title), which would defeat the push's dedup.
    tabs: all.filter((t) => t.groupId === g.id).map((t) => ({
      tabId: t.id, url: t.url || t.pendingUrl || '', title: t.title || '',
      attached: attached.has(t.id), reason: failed.get(t.id) || null,
    })),
  }));
}

async function doPush() {
  await ready;                                   // every command path awaits this; so must the push
  const { groups, closed } = await tidy();
  // Sweep BEFORE projecting: the projection reports each tab's attach state, and sweepAttach is
  // what decides it. Projecting first would publish a snapshot that is one sweep out of date.
  const ids = new Set(groups.length
    ? (await chrome.tabs.query({})).filter((t) => groups.some((g) => g.id === t.groupId)).map((t) => t.id)
    : []);
  await sweepAttach(ids);

  const payload = { type: 'sessions', sessions: await projectSessions(groups) };
  const json = JSON.stringify(payload);
  // Set lastSent only if the send actually went out. Setting it first poisons the dedup: the
  // shim never sees this revision, and nothing re-sends until the payload changes again.
  if (json !== lastSent && send(payload)) lastSent = json;

  // Sent separately: inside the payload this would join the equality check and force a second
  // push just to clear itself.
  for (const c of closed) send({ type: 'closedDuplicate', ...c });
}

function schedulePush() {
  clearTimeout(pushTimer);
  pushTimer = setTimeout(() => pushNow().catch((e) => console.log('[bb] push failed:', e)),
                         PUSH_DEBOUNCE_MS);
}

// ---------------------------------------------------------------- commands
//
// Every chrome.* call lives here. The shim decides what and when; this side answers questions and
// follows instructions. chrome.tabs.query is inherently scoped to THIS profile — each profile
// runs a separate copy of the extension — so there is no cross-profile leakage to guard.
async function handle(m) {
  await ready;
  switch (m.type) {
    case 'ping': return { pong: true };

    // Cold-launch identification: the shim opens a window on a data: URL carrying a token and
    // asks every connected profile whether it has that tab. Only one does.
    case 'findTab': {
      const hit = (await chrome.tabs.query({})).find((t) => (t.url || t.pendingUrl || '').includes(m.token));
      return hit ? { tabId: hit.id, windowId: hit.windowId } : { tabId: null };
    }

    // The only way to discover a tab you might want to grab. Playwright can see only the tabs
    // inside a session's group — that fence is the point — so enumerating the rest is
    // extension-only work, same as tab groups themselves.
    case 'listAllTabs': {
      const groups = await sortedGroups();
      const slugOf = new Map();
      for (const g of groups) { const sl = slugFromTitle(g.title); if (sl) slugOf.set(g.id, sl); }
      const tabs = await chrome.tabs.query({});
      return { tabs: tabs.map((t) => ({
        tabId: t.id, url: t.url || t.pendingUrl || '', title: t.title || '',
        slug: slugOf.get(t.groupId) || null, active: !!t.active,
      })) };
    }

    case 'hasSession': {
      const gid = await groupForSlug(m.slug);
      if (gid == null) return { present: false };
      return { present: true, tabCount: (await chrome.tabs.query({ groupId: gid })).length };
    }

    case 'createSession': {
      // Adopt rather than duplicate. Decided by looking for the ⚙ group, not by consulting
      // `owned`, so it works on a group Chrome restored before the worker hydrated.
      const existing = await groupForSlug(m.slug);
      if (existing != null) {
        owned.set(existing, m.slug); saveOwned();
        const tabs = await chrome.tabs.query({ groupId: existing });
        return { adopted: true, groupId: existing, tabCount: tabs.length,
                 tabId: tabs[0] ? tabs[0].id : null, windowId: tabs[0] ? tabs[0].windowId : null };
      }
      let tabId = m.reuseTabId ?? null, windowId = null;
      if (tabId != null) {
        const t = await chrome.tabs.get(tabId).catch(() => null);
        if (t) windowId = t.windowId; else tabId = null;
      }
      if (tabId == null) {
        const w = await chrome.windows.create({ url: 'about:blank', focused: false });
        tabId = w.tabs[0].id; windowId = w.id;
      }
      // windowId is REQUIRED: without it Chrome may move the group to another window.
      const groupId = await chrome.tabs.group({ tabIds: [tabId], createProperties: { windowId } });
      await chrome.tabGroups.update(groupId, { title: TITLE_PREFIX + m.slug, color: m.colour });
      if (m.reuseTabId != null) await chrome.tabs.update(tabId, { url: 'about:blank' });
      owned.set(groupId, m.slug); saveOwned();
      return { adopted: false, groupId, tabId, windowId, tabCount: 1 };
    }

    case 'closeSession': {
      const gid = await groupForSlug(m.slug);
      if (gid == null) return { closed: false };
      const tabs = await chrome.tabs.query({ groupId: gid });
      if (m.keepTabs) await chrome.tabs.ungroup(tabs.map((t) => t.id));
      else if (tabs.length) await chrome.tabs.remove(tabs.map((t) => t.id));
      owned.delete(gid); saveOwned();
      return { closed: true, tabCount: tabs.length };
    }

    // A tab has exactly one group, so grabbing is a MOVE. Emptying another session's group makes
    // Chrome delete it, so sizes are snapshotted BEFORE anything moves — recomputing per tab
    // double-counts and refuses a legal partial grab.
    case 'grabTab': {
      const gid = await requireGroup(m.slug);
      const dest = (await chrome.tabs.query({ groupId: gid }))[0];
      const all = await chrome.tabs.query({});
      const sizes = new Map();
      for (const t of all) sizes.set(t.groupId, (sizes.get(t.groupId) || 0) + 1);
      const takingFrom = new Map();
      for (const id of new Set(m.tabIds)) {
        const t = all.find((x) => x.id === id);
        if (t && t.groupId !== gid && t.groupId !== -1) {
          takingFrom.set(t.groupId, (takingFrom.get(t.groupId) || 0) + 1);
        }
      }
      const out = [];
      for (const id of new Set(m.tabIds)) {
        const t = all.find((x) => x.id === id);
        if (!t) { out.push({ tabId: id, ok: false, reason: `no tab ${id}` }); continue; }
        const from = owned.get(t.groupId) || null;
        if (!m.duplicate && from && takingFrom.get(t.groupId) >= (sizes.get(t.groupId) || 0)) {
          out.push({ tabId: id, ok: false, reason:
            `that would take every tab of session '${from}' — delete-session it instead, or use --duplicate` });
          continue;
        }
        try {
          let move = id;
          if (m.duplicate) { const d = await chrome.tabs.duplicate(id); move = d.id; }
          // Move BEFORE group: a tab cannot join a group in another window.
          if (dest) await chrome.tabs.move(move, { windowId: dest.windowId, index: -1 });
          await chrome.tabs.group({ tabIds: [move], groupId: gid });
          out.push({ tabId: move, ok: true, from });
        } catch (e) { out.push({ tabId: id, ok: false, reason: String((e && e.message) || e) }); }
      }
      await dropBlanks(gid);
      return { results: out };
    }

    case 'releaseTab': {
      const gid = await requireGroup(m.slug);
      const tabs = await chrome.tabs.query({ groupId: gid });
      const ids = [...new Set(m.tabIds)].filter((id) => tabs.some((t) => t.id === id));
      // Chrome deletes a group when its last tab leaves, so releasing all of them would silently
      // END the session. Counted over UNIQUE tabs: `release 91 91` is one tab, not two.
      if (!m.duplicate && ids.length >= tabs.length) {
        throw new Error(`that is every tab in session '${m.slug}' — use delete-session, which is the verb that says what it does`);
      }
      const out = [];
      for (const id of ids) {
        try {
          if (m.duplicate) { const d = await chrome.tabs.duplicate(id); await chrome.tabs.ungroup(d.id); out.push({ tabId: d.id, ok: true }); }
          else { await chrome.tabs.ungroup(id); out.push({ tabId: id, ok: true }); }
        } catch (e) { out.push({ tabId: id, ok: false, reason: String((e && e.message) || e) }); }
      }
      return { results: out };
    }

    case 'bringToFront': {
      const gid = await requireGroup(m.slug);
      const tabs = await chrome.tabs.query({ groupId: gid });
      if (!tabs.length) throw new Error(`session '${m.slug}' has no tabs`);
      // Looked up live from the group: dragging a group into another window changes its windowId,
      // so a remembered one would raise the wrong window.
      const tab = tabs.find((t) => t.active) || tabs[0];
      await chrome.windows.update(tab.windowId, { focused: true, drawAttention: true });
      await chrome.tabs.update(tab.id, { active: true });
      return { tabId: tab.id, windowId: tab.windowId, url: tab.url || '' };
    }

    // --------------------------------------------------- CDP relay (used by the shim's endpoint)
    case 'cdp': return { result: await sendCdp(m.tabId, m.method, m.params, m.sessionId) };

    case 'createTabInGroup': {
      const gid = await requireGroup(m.slug);
      const dest = (await chrome.tabs.query({ groupId: gid }))[0];
      const t = await chrome.tabs.create({ url: m.url || 'about:blank', active: false,
                                           windowId: dest ? dest.windowId : undefined });
      await chrome.tabs.group({ tabIds: [t.id], groupId: gid });
      // Attach while it is still blank — Chrome checks the frame tree only at attach time, so
      // this survives navigating into a login page a password manager injects into.
      await tryAttach(t.id);
      return { tabId: t.id, windowId: t.windowId };
    }

    case 'closeTab': { await chrome.tabs.remove(m.tabId); return { closed: true }; }
    case 'activateTab': {
      const t = await chrome.tabs.get(m.tabId);
      await chrome.tabs.update(m.tabId, { active: true });
      return { changed: !t.active };
    }

    default: throw new Error(`unknown command '${m.type}'`);
  }
}

// Drops the blank placeholder once a group has real tabs. Called at the END of commands that add
// tabs, never from the push path: a push can fire mid-move, when the placeholder still reads
// about:blank, and the sweep would close the tab about to become the first real one.
async function dropBlanks(groupId, exceptId = null) {
  const tabs = (await chrome.tabs.query({ groupId })).filter((t) => t.id !== exceptId);
  if (tabs.length < 2) return;                      // never empty a group; Chrome deletes it
  const blank = tabs.filter((t) => (t.url || t.pendingUrl || '') === 'about:blank');
  const kill = blank.length === tabs.length ? blank.slice(1) : blank;   // all blank? keep one
  if (kill.length) await chrome.tabs.remove(kill.map((t) => t.id)).catch(() => {});
}

async function requireGroup(slug) {
  const groupId = await groupForSlug(slug);
  if (groupId == null) throw new Error(`no session '${slug}' here`);
  return groupId;
}

async function groupForSlug(slug) {
  const g = (await sortedGroups()).find((x) => slugFromTitle(x.title) === slug);
  return g ? g.id : null;
}

// Sorted by id, matching tidy's "oldest keeps the slug" rule. chrome.tabGroups.query order is not
// guaranteed, so a bare find() can resolve the duplicate tidy is ABOUT TO CLOSE.
async function sortedGroups() {
  return (await chrome.tabGroups.query({})).sort((a, b) => a.id - b.id);
}

// ---------------------------------------------------------------- connection

function connect() {
  // Guards every caller (install, startup, alarm, tab creation, retry chain) against firing a
  // second attempt on top of one already connecting or connected.
  if (ws && (ws.readyState === WebSocket.CONNECTING || ws.readyState === WebSocket.OPEN)) return;

  const sock = new WebSocket(SHIM_URL);
  ws = sock;

  sock.onopen = async () => {
    const identity = await ready;
    send({ type: 'hello', id: identity, build: chrome.runtime.getManifest().version });
    // Cleared AFTER hello. The shim drops any 'sessions' frame arriving before hello (no identity
    // to attribute it to), and a doPush already in flight can complete inside that await —
    // latching lastSent to a payload the shim never applied.
    lastSent = null;
    console.log('[bb] hello as', identity);
    pushNow().catch(() => {});
  };

  sock.onmessage = async (ev) => {
    let m;
    try { m = JSON.parse(ev.data); } catch { return; }
    try {
      const result = await handle(m);
      send({ id: m.id, ok: true, result: result ?? {} });
    } catch (e) {
      send({ id: m.id, ok: false, error: String((e && e.message) || e) });
    }
  };

  // onerror always fires before onclose on a failed connection — retry from onclose only, or a
  // single failure queues two overlapping chains. The identity check stops a superseded socket's
  // close from starting a second chain alongside the live one.
  sock.onclose = () => { if (ws === sock) setTimeout(connect, RETRY_MS); };
}

// Always sends on the CURRENT socket, not the one a handler was installed on: a handler can await
// for hundreds of ms. Never throws — an unguarded send inside an async handler becomes an
// unhandled rejection that also swallows the reply.
function send(o) {
  try {
    if (ws && ws.readyState === WebSocket.OPEN) { ws.send(JSON.stringify(o)); return true; }
  } catch {}
  return false;
}

chrome.runtime.onInstalled.addListener(connect);
chrome.runtime.onStartup.addListener(connect);
chrome.alarms.onAlarm.addListener((a) => {
  if (a.name !== 'reconnect') return;
  if (!ws || ws.readyState === WebSocket.CLOSED || ws.readyState === WebSocket.CLOSING) connect();
});

for (const ev of [chrome.tabs.onCreated, chrome.tabs.onRemoved, chrome.tabs.onUpdated,
                  chrome.tabs.onMoved, chrome.tabs.onAttached, chrome.tabs.onDetached,
                  chrome.tabGroups.onCreated, chrome.tabGroups.onUpdated,
                  chrome.tabGroups.onRemoved, chrome.tabGroups.onMoved]) {
  ev.addListener(schedulePush);
}
// Tab creation is also the cold-launch wake signal, so it must reconnect as well as push.
chrome.tabs.onCreated.addListener(() => connect());

// Rename defence. Chrome has no pre-update hook, so this is revert, not prevention — there is a
// visible snap-back. It only works while the worker is running, which is why the shim pings
// profiles holding a live session.
chrome.tabGroups.onUpdated.addListener(async (g) => {
  await ready;
  const slug = owned.get(g.id);
  if (slug == null) {
    const now = slugFromTitle(g.title);          // it may have just become one of ours
    if (now) { owned.set(g.id, now); saveOwned(); }
    return;
  }
  const want = TITLE_PREFIX + slug;
  // Comparing before writing stops the loop: our own update re-fires this listener, and the
  // second pass sees the title already correct and returns.
  if (g.title === want) return;
  try { await chrome.tabGroups.update(g.id, { title: want }); }
  catch (e) { console.log('[bb] could not restore group title:', e); }
});

chrome.alarms.create('reconnect', { periodInMinutes: ALARM_MINUTES });
connect();
