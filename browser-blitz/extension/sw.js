// browser-blitz-bridge: shim <-> chrome.debugger + tab/group management.
//
// The shim owns browser-level CDP (Target.*/Browser.*); everything session-level is
// forwarded here verbatim, because chrome.debugger.sendCommand takes raw CDP method+params.
// This worker also owns tab groups (the slug fence) and pushes a full tab snapshot on any
// tab/group change so the shim can diff it into Target lifecycle events.
const SHIM_URL = 'ws://127.0.0.1:9334';
const PROTOCOL_VERSION = '1.3';
const BUILD = '0.9.5';

let ws = null;
const RETRY_MIN = 2000, RETRY_MAX = 10000;
let retryDelay = RETRY_MIN;
const attached = new Set();          // tabIds we hold a debugger session on
let profileId = null;
// Which Chrome profile directory this copy lives in ("Default", "Profile 5", ...). An
// extension cannot discover this itself, so the shim assigns it once — right after it warms
// a cold profile, when the newly-appearing connection is unambiguously that profile.
let profileDir = null;

const log = (...a) => console.log('[browser-blitz]', ...a);

// ---------- identity ----------

// If this rejects, `hello` is never sent and the shim shows the profile as unidentified. All
// APIs it touches (identity, storage) are declared in the manifest, so a rejection means a
// genuinely broken install — which should surface loudly, not be swallowed.
async function getProfile() {
  const info = await chrome.identity.getProfileUserInfo();
  const email = info && info.email ? info.email : null;

  const stored = await chrome.storage.local.get(['profileId', 'profileDir']);
  if (stored && stored.profileId) {
    profileId = stored.profileId;
  } else {
    profileId = 'p-' + Math.random().toString(36).slice(2, 10);
    await chrome.storage.local.set({ profileId });
  }
  profileDir = (stored && stored.profileDir) || null;
  return { profileId, email, profileDir, build: BUILD };
}

// ---------- connection ----------

function connect() {
  ws = new WebSocket(SHIM_URL);

  ws.onopen = async () => {
    retryDelay = RETRY_MIN;          // connected: next outage starts from the short delay
    const p = await getProfile();
    reply({ type: 'hello', profile: p });
    log('connected to shim as', p.email || p.profileId);
    pushTabs();
  };

  ws.onclose = () => {
    // Back off instead of hammering every 2s: a shim that is down for an hour would otherwise
    // produce ~1800 failed connections, each one logged to chrome://extensions → Errors.
    // 2s, 4s, 8s, then hold at 10s.
    retryDelay = Math.min(retryDelay * 2, RETRY_MAX);
    setTimeout(connect, retryDelay);
  };
  ws.onerror = () => { try { ws.close(); } catch {} };
  ws.onmessage = (ev) => handle(ev).catch(e => log('handler error', e));
}

function reply(obj) {
  if (ws && ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify(obj));
}

const ok = (id, result) => reply({ type: 'res', id, result: result ?? {} });
const fail = (id, error) => reply({ type: 'res', id, error: String(error && error.message || error) });

async function handle(ev) {
  let m; try { m = JSON.parse(ev.data); } catch { return; }
  const { id, type } = m;

  // Receiving a message is what actually keeps this MV3 worker resident.
  if (type === 'ping') return reply({ type: 'pong' });

  try {
    switch (type) {
      case 'cdp': {
        try {
          const dbg = await ensureAttached(m.tabId);
          const result = await chrome.debugger.sendCommand(dbg, m.method, m.params || {});
          return ok(id, result);
        } catch (e) {
          // Chrome refuses chrome.debugger on a tab whose frame tree contains ANOTHER
          // extension's frame, and reports it as "Cannot access a chrome-extension:// URL of
          // different extension" even though the page itself is ordinary https. Password
          // managers inject an autofill frame into login forms, so this hits login pages only.
          // The raw message sends people hunting a chrome-extension URL that isn't there, so
          // name the real cause and the real remedy.
          const msg = String((e && e.message) || e);
          if (/chrome-extension:\/\/ URL of different extension/.test(msg)) {
            const culprits = (await chrome.debugger.getTargets())
              .filter(t => String(t.url).startsWith('chrome-extension:'))
              .map(t => String(t.url).split('/')[2]);
            const ids = [...new Set(culprits)].join(', ');
            throw new Error(
              `${m.method} refused by Chrome: another extension has injected a frame into this ` +
              `page, so chrome.debugger cannot attach. This is a Chrome restriction, not a bug ` +
              `in this page. It affects LOGIN pages because password managers inject an ` +
              `autofill frame there. Fix: disable the offending extension in chrome://extensions ` +
              `(iCloud Passwords is the usual one). Extensions currently running frames: ${ids}`);
          }
          throw e;
        }
      }

      case 'setProfileDir': {
        profileDir = m.profileDir;
        await chrome.storage.local.set({ profileDir });
        return ok(id, { profileDir });
      }

      // Attach NOW, while the tab is still blank. Chrome refuses chrome.debugger on a tab
      // whose frame tree already holds another extension's frame (password managers inject an
      // autofill frame into login forms), but an attachment made BEFORE that frame appears
      // survives the navigation. Attaching the moment a tab joins a slug's group is therefore
      // what makes login pages driveable at all — attaching lazily on the first command is too
      // late, because by then the login page (and its injected frame) has already loaded.
      case 'attachTab': {
        await ensureAttached(m.tabId);
        return ok(id, { attached: true });
      }

      case 'listTabs':      return ok(id, { tabs: await tabSnapshot() });

      case 'lastFocusedWindow': {
        // (a) semantics: whatever normal window the user last used in this profile.
        const w = await chrome.windows.getLastFocused({ windowTypes: ['normal'] });
        if (!w) throw new Error('no normal window to place the group in');
        return ok(id, { windowId: w.id });
      }

      case 'createWindow': {
        // focused:false is why this never steals focus, unlike launching Chrome from the CLI.
        const w = await chrome.windows.create({ url: m.url || 'about:blank', focused: false });
        return ok(id, { windowId: w.id, tabId: w.tabs && w.tabs[0] && w.tabs[0].id });
      }

      case 'createGroup': {
        let tabId = m.tabId;
        if (!tabId) {
          const t = await chrome.tabs.create({
            url: m.url || 'about:blank', active: false,
            ...(m.windowId ? { windowId: m.windowId } : {}),
          });
          tabId = t.id;
        }
        // Pin the group to the tab's own window. chrome.tabs.group without createProperties
        // can attach to another window's group.
        const seed = await chrome.tabs.get(Number(tabId));
        const groupId = await chrome.tabs.group({
          tabIds: [Number(tabId)],
          createProperties: { windowId: seed.windowId },
        });
        await chrome.tabGroups.update(groupId, { title: m.title || '', color: m.color || 'purple' });
        // Park it at the end of the strip. windowId is REQUIRED here: without it Chrome moves
        // the group to a different window entirely (observed: every group teleported).
        await chrome.tabGroups.move(groupId, { index: -1, windowId: seed.windowId });
        const g = await chrome.tabGroups.get(groupId);
        return ok(id, { groupId, windowId: g.windowId, tabId });
      }

      case 'updateGroup': {
        await chrome.tabGroups.update(m.groupId, {
          ...(m.title !== undefined ? { title: m.title } : {}),
          ...(m.color ? { color: m.color } : {}),
        });
        return ok(id, {});
      }

      case 'createTabInGroup': {
        const g = await chrome.tabGroups.get(m.groupId);
        const t = await chrome.tabs.create({ url: m.url || 'about:blank', active: false, windowId: g.windowId });
        await chrome.tabs.group({ tabIds: [t.id], groupId: m.groupId });
        return ok(id, { tabId: t.id });
      }

      case 'adoptTab': {
        await chrome.tabs.group({ tabIds: [Number(m.tabId)], groupId: m.groupId });
        return ok(id, {});
      }

      case 'focusWindow': {
        const w = await chrome.windows.get(Number(m.windowId));
        const already = w.focused;
        if (!already) await chrome.windows.update(Number(m.windowId), { focused: true, drawAttention: true });
        if (m.tabId) await chrome.tabs.update(Number(m.tabId), { active: true });
        return ok(id, { alreadyFocused: already, windowId: m.windowId, tabId: m.tabId || null });
      }

      case 'closeTab':      await chrome.tabs.remove(Number(m.tabId)); return ok(id, {});
      case 'activateTab': {
        const t = await chrome.tabs.get(Number(m.tabId));
        if (!t.active) await chrome.tabs.update(Number(m.tabId), { active: true });
        return ok(id, { changed: !t.active });
      }

      case 'endGroup': {
        const tabs = await chrome.tabs.query({ groupId: m.groupId });
        if (m.close) await chrome.tabs.remove(tabs.map(t => t.id));
        else if (tabs.length) await chrome.tabs.ungroup(tabs.map(t => t.id));
        return ok(id, {});
      }

      // Every group this tool ever created is titled "🤖 <slug> · <age>". That marker is how
      // orphans (left behind when the shim restarts) can be found and removed later.
      case 'listGroups': {
        const groups = await chrome.tabGroups.query({});
        const out = [];
        for (const g of groups) {
          const tabs = await chrome.tabs.query({ groupId: g.id });
          out.push({ groupId: g.id, title: g.title || '', color: g.color,
                     windowId: g.windowId, tabs: tabs.length });
        }
        return ok(id, { groups: out });
      }

      default: return fail(id, `unknown type ${type}`);
    }
  } catch (e) {
    return fail(id, e);
  }
}

// ---------- debugger ----------

// Attach by {tabId}: the attachment then survives cross-process navigations, which attaching
// to a specific {targetId} does not (a new document = a new target = a silent detach).
//
// NOTE: Chrome refuses this attach outright when the tab's frame tree contains ANOTHER
// extension's frame, reporting "Cannot access a chrome-extension:// URL of different
// extension". Attaching by targetId does NOT work around it (measured), because the refusal is
// about the tab's contents, not the debuggee shape. The 'cdp' handler turns that raw message
// into an actionable one; there is no in-extension fix.
async function ensureAttached(tabId) {
  const n = Number(tabId);
  if (attached.has(n)) return { tabId: n };
  await chrome.debugger.attach({ tabId: n }, PROTOCOL_VERSION);
  attached.add(n);
  return { tabId: n };
}

chrome.debugger.onEvent.addListener((source, method, params) => {
  reply({ type: 'cdpEvent', tabId: String(source.tabId), method, params });
});

chrome.debugger.onDetach.addListener((source) => { attached.delete(source.tabId); });

// ---------- tab/group state ----------

async function tabSnapshot() {
  const tabs = await chrome.tabs.query({});
  return tabs
    // Filter on the REAL url, never a fabricated one. A previous version defaulted an empty
    // url to 'about:blank' BEFORE this filter, so a chrome-extension:// or chrome:// page that
    // momentarily reported url:"" (they do while loading) passed as attachable. The agent then
    // attached to a target chrome.debugger always refuses ("Cannot access a chrome-extension://
    // URL of different extension") and every later command on that tab failed permanently.
    // Unattachable pages can never be advertised, so an unknown url is dropped, not guessed.
    .filter(t => {
      const real = t.url || t.pendingUrl || '';
      if (!real) return false;   // url not settled yet: skip this round, a later push includes it
      return !/^(chrome|devtools|chrome-extension|view-source):/.test(real)
          && !real.startsWith('https://chromewebstore.google.com');
    })
    .map(t => ({ ...t, url: t.url || t.pendingUrl }))
    .map(t => ({
      tabId: String(t.id), url: t.url, title: t.title || '',
      groupId: t.groupId, windowId: t.windowId, attached: attached.has(t.id),
    }));
}

let pushTimer = null;
async function pushTabs() {
  reply({ type: 'tabs', tabs: await tabSnapshot() });
}
function schedulePush() {
  // Coalesce bursts (a page load fires many onUpdated) into one snapshot.
  clearTimeout(pushTimer);
  pushTimer = setTimeout(() => pushTabs().catch(() => {}), 120);
}

for (const ev of [chrome.tabs.onCreated, chrome.tabs.onRemoved, chrome.tabs.onUpdated,
                  chrome.tabs.onMoved, chrome.tabs.onAttached, chrome.tabs.onDetached]) {
  ev.addListener(schedulePush);
}
for (const ev of [chrome.tabGroups.onCreated, chrome.tabGroups.onUpdated,
                  chrome.tabGroups.onRemoved, chrome.tabGroups.onMoved]) {
  ev.addListener(schedulePush);
}
chrome.tabs.onRemoved.addListener((id) => attached.delete(id));

// ---------- watchdog ----------
// An MV3 worker only runs when something wakes it. If the shim restarts while the browser is
// idle, the reconnect timer is already dead and nothing would ever re-dial. An alarm is the
// only wakeup source that survives worker death (min period is 1 minute).
chrome.alarms.create('reconnect', { periodInMinutes: 1 });
chrome.alarms.onAlarm.addListener((a) => {
  if (a.name !== 'reconnect') return;
  if (!ws || ws.readyState === WebSocket.CLOSED || ws.readyState === WebSocket.CLOSING) connect();
});
chrome.runtime.onStartup.addListener(() => connect());
chrome.runtime.onInstalled.addListener(() => connect());

connect();
