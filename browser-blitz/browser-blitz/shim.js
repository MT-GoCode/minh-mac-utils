// browser-blitz shim — the daemon behind `bb`. Owns all state and every decision; the extension
// answers questions about tabs and groups and relays CDP, Playwright does the driving.
//
// Three servers:
//   :9334  loopback WebSocket the extension dials into, one connection per Chrome profile
//   :9342  a CDP browser endpoint per slug, at /<slug> — this is what Playwright attaches to
//   unix   the CLI socket
//
// State: `state.sessions` (on disk) is which slugs exist and in which profile; `mirrors` is the
// last tab list each profile pushed, and is the only thing `list` and the CDP endpoint read, so
// they cannot disagree; `clients` is who is speaking CDP now; `frameIds` maps tab -> main frame.
//
// Two invariants Playwright depends on, each enforced (and explained) further down: a page
// target's id IS its main frame id, never the tabId; and the Target.attachedToTarget announce
// goes out BEFORE the setAutoAttach reply, never after.
const fs = require('fs');
const net = require('net');
const os = require('os');
const path = require('path');
const http = require('http');
const util = require('util');
const execFile = util.promisify(require('child_process').execFile);

// ---------------------------------------------------------------- constants

const EXT_ID = 'daennoocgfgdhaeceemdhabpndjdjchj';   // pinned by the 'key' in extension/manifest.json
const EXT_ORIGIN = `chrome-extension://${EXT_ID}`;
const EXT_PORT = 9334;
const CDP_PORT = 9342;
const CHROME_DIR = path.join(os.homedir(), 'Library/Application Support/Google/Chrome');
const STATE_DIR = path.join(os.homedir(), '.local/state/browser-blitz');
const SOCK = path.join(STATE_DIR, 'shim.sock');
const STATE_FILE = path.join(STATE_DIR, 'state.json');
const MAPPINGS_FILE = path.join(STATE_DIR, 'profile-mappings.json');
const LOG_FILE = path.join(STATE_DIR, 'shim.log');
const LOG_MAX_BYTES = 8 * 1024 * 1024;      // an unrotated log reached 352 MB
const DEFAULT_PROFILE = 'Default';
const GROUP_COLORS = ['grey', 'blue', 'red', 'yellow', 'green', 'pink', 'purple', 'cyan', 'orange'];
const SLUG_RE = /^[a-zA-Z0-9._-]{1,64}$/;
// No spaces, pure ASCII: Chrome percent-encodes parts of a data: URL, and a token with nothing
// encodable in it can be matched as a plain substring regardless.
const LAUNCH_URL = (token) => `data:text/html,<title>browser-blitz</title><h2>bb:${token}</h2>`;

const PING_MS = 15000;            // inside the ~30s MV3 worker kill window
const LAUNCH_TIMEOUT_MS = 15000;
const PROBE_TIMEOUT_MS = 2000;    // must stay well under LAUNCH_TIMEOUT_MS
const STABILIZE_MS = 1000;
// How long Chrome's own session restore may take to rebuild windows. Cold-launch resume polls
// up to this before deciding a group is absent.
const SETTLE_MAX_MS = 10000;
const SETTLE_POLL_MS = 250;
const EXT_CALL_TIMEOUT_MS = 20000;
const PW = 'playwright-cli';

// The tab-group fence holds TABS, not CDP: these commands act on the whole Chrome profile, so a
// session scoped to three tabs could sign the user out of every site they use. Playwright reaches
// them through ordinary API calls (context.clearCookies() is one line), so an agent trips this
// without meaning to. Refused outright, not gated behind a flag: there is no in-fence version of
// "clear every cookie".
const PROFILE_WIDE = new Set([
  'Network.clearBrowserCookies', 'Network.clearBrowserCache',
  'Storage.clearCookies', 'Storage.clearDataForOrigin', 'Storage.clearDataForStorageKey',
  'Storage.clearTrustTokens', 'Storage.setCookies',
  'Browser.resetPermissions', 'Browser.grantPermissions', 'Browser.setPermission',
  'Profiler.enable',
]);

fs.mkdirSync(STATE_DIR, { recursive: true });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ---------------------------------------------------------------- logging
//
// Summarised, and rotated. Playwright enables Page, Runtime and Network on attach, so every event
// in the browser flows through here; logging them whole is what filled a disk (LOG_MAX_BYTES).
function log(dir, msg) {
  let line;
  try { line = JSON.stringify(msg); } catch { line = String(msg); }
  if (line.length > 400) line = line.slice(0, 400) + `…+${line.length - 400}ch`;
  console.log(`${new Date().toISOString()} ${dir} ${line}`);
}
setInterval(() => {
  try {
    if (fs.statSync(LOG_FILE).size > LOG_MAX_BYTES) fs.truncateSync(LOG_FILE, 0);
  } catch {}
}, 60000).unref();

// ---------------------------------------------------------------- disk

function readJson(file, fallback, label) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); }
  catch (e) {
    if (e.code !== 'ENOENT') log('! read', { file: label || file, error: String(e.message || e) });
    return fallback;
  }
}
function writeJson(file, value) {
  const tmp = `${file}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(value, null, 2));
  fs.renameSync(tmp, file);                    // atomic: a crash mid-write can't truncate it
}

let state = readJson(STATE_FILE, null, 'state') || { sessions: [] };
if (!Array.isArray(state.sessions)) state.sessions = [];
const saveState = () => writeJson(STATE_FILE, state);

let mappings = readJson(MAPPINGS_FILE, {}, 'profile mappings');
const saveMappings = () => writeJson(MAPPINGS_FILE, mappings);

// ---------------------------------------------------------------- shared helpers

function installedProfiles() {
  const ls = readJson(path.join(CHROME_DIR, 'Local State'), null, 'Chrome Local State');
  const cache = (ls && ls.profile && ls.profile.info_cache) || {};
  const out = [];
  for (const [dir, info] of Object.entries(cache)) {
    let installed = false;
    try {
      const sp = JSON.parse(fs.readFileSync(path.join(CHROME_DIR, dir, 'Secure Preferences'), 'utf8'));
      installed = !!(sp.extensions && sp.extensions.settings && sp.extensions.settings[EXT_ID]);
    } catch {}
    if (installed) out.push({ dir, name: info.name || dir });
  }
  return out;
}

// Plural on purpose: mappings are never pruned, and clearing an extension's storage mints a new
// identity for the same directory. A singular lookup would return the dead one forever.
const idsForDir = (dir) => Object.entries(mappings).filter(([, d]) => d === dir).map(([id]) => id);
const liveIdFor = (dir) => idsForDir(dir).find((id) => profiles.has(id)) || null;
const isConnected = (dir) => liveIdFor(dir) !== null;

// Deterministic, so a resumed session keeps the colour it had — no mirror read, no colour on the wire.
function colourFor(slug) {
  let h = 0;
  for (const ch of slug) h = (h * 31 + ch.charCodeAt(0)) >>> 0;
  return GROUP_COLORS[h % GROUP_COLORS.length];
}

// Middle-truncate: every URL on a site shares its first 40 characters and the discriminating
// part is the tail, so cutting the end is the one thing you must not do.
function shortUrl(u, max = 72) {
  u = String(u || '').replace(/^https?:\/\//, '');
  if (u.length <= max) return u;
  return u.slice(0, max - 23) + '…' + u.slice(-20);
}

const sessionRecord = (slug) => state.sessions.find((s) => s.slug === slug) || null;

function requireRecord(slug) {
  const rec = sessionRecord(slug);
  if (rec) return rec;
  const known = state.sessions.map((s) => `${s.slug} (${s.profileDir})`).join(', ');
  throw new Error(`no session '${slug}'${known ? ` — known: ${known}` : ''}`);
}

// A live tab list for a slug, from the last push. Never a live query: the mirror is what `list`
// and the CDP endpoint both read, so they can never disagree about what a session contains.
function tabsOf(slug) {
  const rec = sessionRecord(slug);
  if (!rec) return [];
  const m = mirrors.get(rec.profileDir);
  const s = m && m.sessions.find((x) => x.slug === slug);
  return s ? s.tabs : [];
}

// The record's saved URLs are only ever overwritten by a live group with real tabs, so teardown,
// a disconnect and a half-finished resume all leave them intact.
const placeholderUrl = (u) => !u || u === 'about:blank' || u.startsWith('chrome://newtab');
const meaningful = (tabs) => tabs.length > 0 && !tabs.every((t) => placeholderUrl(t.url));

// ---------------------------------------------------------------- extension socket

const profiles = new Map();   // identity id -> { ws }
const mirrors = new Map();    // profileDir  -> { sessions, at }   NEVER deleted on disconnect

// Seeded per boot: a restarted shim reusing ids from 1 could match a stale in-flight reply from
// before the restart and report a command as done when it never ran.
let seq = Math.floor(Math.random() * 1e6) + 1;
const pending = new Map();    // reqId -> { identityId, ws, resolve }

function callExt(identityId, msg, timeoutMs = EXT_CALL_TIMEOUT_MS) {
  return new Promise((resolve) => {
    const p = profiles.get(identityId);
    if (!p || p.ws.readyState !== 1) return resolve({ ok: false, error: 'not connected' });
    const id = seq++;
    const timer = setTimeout(() => {
      if (pending.has(id)) { pending.delete(id); resolve({ ok: false, error: 'extension timeout' }); }
    }, timeoutMs);
    // ws, not just identityId: the close handler sweeps by SOCKET, so a superseded connection
    // can't fail calls belonging to its replacement.
    pending.set(id, { identityId, ws: p.ws, resolve: (r) => { clearTimeout(timer); resolve(r); } });
    try { p.ws.send(JSON.stringify({ ...msg, id })); }
    catch (e) {
      clearTimeout(timer); pending.delete(id);
      resolve({ ok: false, error: `send failed: ${(e && e.message) || e}` });
    }
  });
}

const { WebSocketServer } = require('ws');

const wss = new WebSocketServer({
  // host is REQUIRED: without it Node binds every interface, so anything on the LAN or Tailnet
  // could drive the user's real Chrome.
  port: EXT_PORT,
  host: '127.0.0.1',
  // The Origin check is what stops any web page driving the user's Chrome: without it any site
  // the user visits could open a socket here, claim an identity and receive commands. A browser
  // cannot forge Origin; a native local process can, but it can read the profile directory too.
  verifyClient: (info, cb) => {
    const origin = info.origin || (info.req && info.req.headers.origin);
    if (origin === EXT_ORIGIN) return cb(true);
    cb(false, 403, 'forbidden origin');
  },
});
wss.on('error', (e) => {
  console.error(`shim: cannot listen on ${EXT_PORT}: ${(e && e.message) || e}`);
  process.exit(1);
});

wss.on('connection', (ws) => {
  let identityId = null;
  ws.on('message', (buf) => {
    let m; try { m = JSON.parse(buf.toString()); } catch { return; }

    if (m.type === 'hello') {
      if (typeof m.id !== 'string' || !m.id) return;
      identityId = m.id;
      profiles.set(identityId, { ws, build: m.build || '?' });
      log('◆ hello', { id: identityId, build: m.build });
      return;
    }
    if (!identityId) return;                   // nothing before hello: no identity to attribute it to

    if (m.type === 'sessions') return onSessions(identityId, m.sessions || []);
    if (m.type === 'closedDuplicate') return log('◆ closedDuplicate', m);
    if (m.type === 'cdpEvent') return onCdpEvent(identityId, m);
    if (m.type === 'cdpDetached') return onCdpDetached(identityId, m);

    if (m.id != null && pending.has(m.id)) {
      const p = pending.get(m.id);
      if (p.identityId !== identityId) return;  // a reply must come from the profile we called
      pending.delete(m.id);
      p.resolve(m);
    }
  });
  ws.on('close', () => {
    // Sweep by socket, not identity: a reconnect racing an old close must not fail the live
    // replacement's in-flight calls.
    for (const [id, p] of [...pending]) {
      if (p.ws === ws) { pending.delete(id); p.resolve({ ok: false, error: 'extension disconnected' }); }
    }
    if (identityId && profiles.get(identityId) && profiles.get(identityId).ws === ws) {
      profiles.delete(identityId);
      log('◆ bye', { id: identityId });
    }
  });
});

// ---------------------------------------------------------------- push handling

function onSessions(identityId, sessions) {
  const dir = mappings[identityId];
  log('◆ sessions', { id: identityId, n: sessions.length, tabs: sessions.reduce((a, s) => a + s.tabs.length, 0) });
  if (!dir) return;                            // unidentified profile: mirror only
  mirrors.set(dir, { sessions, at: Date.now() });

  let dirty = false;
  for (const s of sessions) {
    const rec = state.sessions.find((x) => x.slug === s.slug && x.profileDir === dir);
    if (!rec) continue;
    const saved = s.tabs.map((t) => ({ url: t.url, title: t.title }));
    if (meaningful(saved) && JSON.stringify(saved) !== JSON.stringify(rec.tabs)) {
      rec.tabs = saved; dirty = true;
    }
  }
  if (dirty) saveState();

  // Attach/detach Playwright to match reality: a slug is bindable exactly while its group is
  // live, and never wants `playwright-cli -s=<slug>` pointed at a dead endpoint.
  syncPlaywright(dir, new Set(sessions.map((s) => s.slug)));
  // A tab that joined or left an attached slug has to be announced to the connected client.
  for (const s of sessions) reconcileTargets(s.slug, s.tabs).catch(() => {});
}

// ---------------------------------------------------------------- CDP endpoint
//
// One port, slug as PATH — deliberately not a port range. Playwright appends /json/version/ to
// whatever URL it is handed (trailing slash included) and then connects to the absolute
// webSocketDebuggerUrl in the reply, so one port serves every session with nothing to allocate,
// leak or collide.
const clients = new Map();    // slug -> Set<{ ws, sessions:Map<sessionId,tabId>, autoAttach:bool }>

const sidFor = (tabId) => 'S-' + tabId;

// INVARIANT: a page target's id must EQUAL its main frame id. Playwright's crPage.js keys
// _sessions by frame id but registers the main session under the TARGET id, so if the two differ
// _sessionForFrame misses and every action fails "Frame has been detached." Hence: learn each
// tab's real main-frame id and use THAT as its target id. The tabId is never a target id.
const frameIds = new Map();     // tabId -> main frame id
const tabForFrame = (fid) => [...frameIds].find(([, f]) => f === fid)?.[0] ?? null;

async function learnFrameId(dir, tabId) {
  if (frameIds.has(tabId)) return frameIds.get(tabId);
  const eid = liveIdFor(dir);
  if (!eid) return null;
  const r = await callExt(eid, { type: 'cdp', tabId, method: 'Page.getFrameTree', params: {} });
  const fid = r.ok && r.result && r.result.result && r.result.result.frameTree
    && r.result.result.frameTree.frame && r.result.result.frameTree.frame.id;
  if (fid) frameIds.set(tabId, fid);
  return fid || null;
}

// Resolve the main frame id for every tab of a slug before announcing any of them.
async function learnFrames(slug) {
  const rec = sessionRecord(slug);
  if (!rec) return;
  await Promise.all(tabsOf(slug).map((t) => learnFrameId(rec.profileDir, t.tabId)));
}

const targetIdOf = (t) => String(frameIds.get(t.tabId) || t.tabId);
const targetInfo = (t) => ({
  targetId: targetIdOf(t), type: 'page', title: t.title || '', url: t.url || '',
  attached: true, canAccessOpener: false, browserContextId: 'CTX',
});

function clientsOf(slug) { return clients.get(slug) || new Set(); }

// BB_TRACE=1 logs the CDP conversation. Ordering bugs here are measured in single-digit
// milliseconds, so the trace is the only way to see one.
function toClient(c, payload) {
  if (process.env.BB_TRACE && payload.method) log('→ evt', { m: payload.method, sid: payload.sessionId });
  try { if (c.ws.readyState === 1) c.ws.send(JSON.stringify(payload)); } catch {}
}

// Announce tabs that joined or left a slug to every client attached to it. Playwright learns
// about new pages ONLY through Target.attachedToTarget, so a tab opened by a click is invisible
// to it until this fires.
async function reconcileTargets(slug, tabs) {
  const cs = clientsOf(slug);
  if (!cs.size) return;
  await learnFrames(slug);          // same invariant as the handshake: targetId IS the frame id
  const live = new Set(tabs.map((t) => t.tabId));
  for (const c of cs) {
    if (!c.autoAttach) continue;
    for (const t of tabs) {
      if (c.sessions.has(sidFor(t.tabId))) continue;
      c.sessions.set(sidFor(t.tabId), t.tabId);
      toClient(c, { method: 'Target.attachedToTarget',
        params: { sessionId: sidFor(t.tabId), targetInfo: targetInfo(t), waitingForDebugger: false } });
    }
    for (const [sid, tabId] of [...c.sessions]) {
      if (live.has(tabId)) continue;
      c.sessions.delete(sid);
      // Teardown carries the FRAME id too. Announced under the tabId, Playwright matches nothing,
      // keeps the page in its list and can still drive a released tab — a hole in the fence.
      const gone = String(frameIds.get(tabId) || tabId);
      toClient(c, { method: 'Target.detachedFromTarget', params: { sessionId: sid, targetId: gone } });
      toClient(c, { method: 'Target.targetDestroyed', params: { targetId: gone } });
    }
    // Pruned only after every client has been told, and only for tabs no client still holds.
    for (const tabId of [...frameIds.keys()]) {
      if (live.has(tabId)) continue;
      if ([...clients.values()].some((set) => [...set].some((cl) => [...cl.sessions.values()].includes(tabId)))) continue;
      frameIds.delete(tabId);
    }
  }
}

// Events flow the other way: extension -> shim -> whichever client holds a session for that tab.
function onCdpEvent(identityId, m) {
  const dir = mappings[identityId];
  if (!dir) return;
  for (const [slug, cs] of clients) {
    const rec = sessionRecord(slug);
    if (!rec || rec.profileDir !== dir) continue;
    for (const c of cs) {
      const sid = sidFor(m.tabId);
      if (!c.sessions.has(sid)) continue;
      // Chrome auto-attaches OOPIFs and announces them here. Register the child session or a
      // command addressed to it comes back "no session for <method>".
      if (m.method === 'Target.attachedToTarget' && m.params && m.params.sessionId) {
        c.sessions.set(m.params.sessionId, m.tabId);
      }
      if (m.method === 'Target.detachedFromTarget' && m.params && m.params.sessionId) {
        c.sessions.delete(m.params.sessionId);
      }
      toClient(c, { method: m.method, params: m.params || {}, sessionId: m.sessionId || sid });
    }
  }
}

function onCdpDetached(identityId, m) {
  log('◆ cdpDetached', m);
}

// Browser-level CDP. Everything here is answered locally: these are questions about which
// targets exist, which is bookkeeping the shim already owns from the extension's pushes.
function browserLevel(slug, c) {
  // A client-supplied targetId must resolve to a tab THIS slug owns. tabForFrame misses on
  // anything that is not a known frame id and Number() then takes any integer, so without this
  // check attachToTarget hands out a working session on another slug's tab, or on 'S-NaN'.
  const tabOf = (p) => {
    const id = tabForFrame(p && p.targetId) ?? Number(p && p.targetId);
    if (!Number.isInteger(id) || !tabsOf(slug).some((t) => t.tabId === id)) {
      throw new Error(`no target ${p && p.targetId} in session '${slug}'`);
    }
    return id;
  };
  // Fail loudly when the profile is not connected. callExt RESOLVES {ok:false} rather than
  // throwing, so calling anyway reports success for work that never ran and Playwright waits
  // forever on an event that will not come.
  const ext = () => {
    const id = liveIdFor(requireRecord(slug).profileDir);
    if (!id) throw new Error(`session '${slug}' is not connected`);
    return id;
  };
  return {
    'Browser.getVersion': () => ({
      protocolVersion: '1.3', product: 'Chrome/151.0.7922.138', revision: '',
      userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.7922.138 Safari/537.36',
      jsVersion: '15.1',
    }),
    // Refused: this would quit the user's whole Chrome, not just this slug.
    'Browser.close': () => { throw new Error("refused: that would quit the user's entire Chrome. Use `bb delete-session <slug>`."); },
    // Acked, not implemented. chrome.debugger has no tab-level download control, so download
    // events never fire — the same limitation Playwright's own extension mode documents.
    'Browser.setDownloadBehavior': () => ({}),
    // Playwright asks for this when it believes the target has a UI window. It never does over
    // connect_over_cdp, but answering beats "no session for Browser.getWindowForTarget".
    'Browser.getWindowForTarget': () => ({ windowId: 1, bounds: {} }),
    'Target.getBrowserContexts': () => ({ browserContextIds: [] }),
    'Target.createBrowserContext': () => ({ browserContextId: 'CTX' }),
    'Target.disposeBrowserContext': () => ({}),
    'Target.getTargets': () => ({ targetInfos: tabsOf(slug).map(targetInfo) }),
    // No targetId means Playwright is asking about the BROWSER target, not a page. Answer with a
    // page and it registers that page as the browser; the real page then never gets a frame model
    // and every goto fails "Frame has been detached".
    'Target.getTargetInfo': (p) => {
      if (!p || !p.targetId) {
        return { targetInfo: { targetId: 'browser', type: 'browser', title: '', url: '',
                               attached: true, canAccessOpener: false } };
      }
      const t = tabsOf(slug).find((x) => x.tabId === tabOf(p));
      return { targetInfo: targetInfo(t) };
    },
    'Target.setDiscoverTargets': async () => {
      await learnFrames(slug);
      for (const t of tabsOf(slug)) toClient(c, { method: 'Target.targetCreated', params: { targetInfo: targetInfo(t) } });
      return {};
    },
    // THE handshake step, and the second invariant. Playwright waits for Target.attachedToTarget
    // before it believes any page exists — for about 8ms, then it gives up and mints a stray tab
    // with Target.createTarget. So the announce goes out BEFORE this command's own reply: frames
    // resolved, then the events, then the return. A timer, or any extra round trip, loses.
    'Target.setAutoAttach': async (p) => {
      if (!p || !p.autoAttach) { c.autoAttach = false; return {}; }
      c.autoAttach = true;
      await learnFrames(slug);
      for (const t of tabsOf(slug)) {
        if (c.sessions.has(sidFor(t.tabId))) continue;
        c.sessions.set(sidFor(t.tabId), t.tabId);
        toClient(c, { method: 'Target.attachedToTarget',
          // waitingForDebugger false even though Playwright asks for true: chrome.debugger gives
          // us no way to pause a target, and it sends runIfWaitingForDebugger next regardless.
          params: { sessionId: sidFor(t.tabId), targetInfo: targetInfo(t), waitingForDebugger: false } });
      }
      return {};
    },
    'Target.attachToTarget': (p) => {
      const tabId = tabOf(p);
      const sid = sidFor(tabId);
      c.sessions.set(sid, tabId);
      return { sessionId: sid };
    },
    'Target.detachFromTarget': (p) => { c.sessions.delete(p.sessionId); return {}; },
    'Target.activateTarget': async (p) => {
      const r = await callExt(ext(), { type: 'activateTab', slug, tabId: tabOf(p) });
      if (!r.ok) throw new Error(r.error);
      return {};
    },
    // New tabs land INSIDE the slug's group. This is the fence: a page Playwright opens cannot
    // escape into the user's ordinary browsing.
    'Target.createTarget': async (p) => {
      const r = await callExt(ext(), { type: 'createTabInGroup', slug, url: p.url });
      if (!r.ok) throw new Error(r.error);
      const tabId = r.result.tabId;
      const fid = await learnFrameId(requireRecord(slug).profileDir, tabId);
      // Announce NOW, not on the next push: newPage() waits for Target.attachedToTarget the
      // moment createTarget returns, and the extension's push is 120ms of debounce away.
      if (c.autoAttach && !c.sessions.has(sidFor(tabId))) {
        c.sessions.set(sidFor(tabId), tabId);
        toClient(c, { method: 'Target.attachedToTarget', params: {
          sessionId: sidFor(tabId),
          targetInfo: { targetId: String(fid || tabId), type: 'page', title: '', url: p.url || '',
                        attached: true, canAccessOpener: false, browserContextId: 'CTX' },
          waitingForDebugger: false } });
      }
      return { targetId: String(fid || tabId) };
    },
    'Target.closeTarget': async (p) => {
      const r = await callExt(ext(), { type: 'closeTab', slug, tabId: tabOf(p) });
      if (!r.ok) throw new Error(r.error);
      return { success: true };
    },
    'Runtime.runIfWaitingForDebugger': () => ({}),
  };
}

const cdpServer = http.createServer((req, res) => {
  // Same rule as the socket below: a browser always sends Origin, a native client never does.
  // Without it a page could read /json/list and learn every URL open in a session.
  if (req.headers.origin) { res.writeHead(403); return res.end('{}'); }
  const url = (req.url || '').replace(/\/+$/, '');       // Playwright asks for /json/version/
  const m = /^\/([^/]+)\/json(\/version|\/list)?$/.exec(url);
  const json = (o) => { res.writeHead(200, { 'Content-Type': 'application/json' }); res.end(JSON.stringify(o)); };
  if (!m) { res.writeHead(404); return res.end('{}'); }
  const slug = decodeURIComponent(m[1]);
  if (m[2] === '/version' || !m[2]) {
    return json({
      Browser: 'Chrome/151.0.7922.138', 'Protocol-Version': '1.3', 'User-Agent': 'browser-blitz',
      'V8-Version': '15.1', 'WebKit-Version': '537.36',
      webSocketDebuggerUrl: `ws://127.0.0.1:${CDP_PORT}/${encodeURIComponent(slug)}/browser`,
    });
  }
  return json(tabsOf(slug).map((t) => ({
    id: String(t.tabId), type: 'page', title: t.title || '', url: t.url || '',
    webSocketDebuggerUrl: `ws://127.0.0.1:${CDP_PORT}/${encodeURIComponent(slug)}/page/${t.tabId}`,
  })));
});

// WebSocket handshakes are NOT subject to CORS. This check is the only thing stopping any page
// the user visits from opening this socket, guessing a slug (they are short words like 'work')
// and speaking full CDP against their real logged-in Chrome. A native client sends no Origin; a
// browser always does and can neither forge nor omit it. So: no Origin, or no connection.
const cdpWss = new WebSocketServer({
  server: cdpServer,
  verifyClient: (info, cb) => {
    const origin = info.origin || (info.req && info.req.headers.origin);
    if (!origin) return cb(true);
    cb(false, 403, 'forbidden origin');
  },
});
cdpWss.on('connection', (ws, req) => {
  const m = /^\/([^/]+)\/browser$/.exec(req.url || '');
  if (!m) return ws.close();
  const slug = decodeURIComponent(m[1]);
  const c = { ws, sessions: new Map(), autoAttach: false };
  if (!clients.has(slug)) clients.set(slug, new Set());
  clients.get(slug).add(c);
  const handlers = browserLevel(slug, c);
  learnFrames(slug).catch(() => {});          // warm the cache before the handshake asks
  log('◆ cdp client', { slug });

  ws.on('message', async (buf) => {
    let msg; try { msg = JSON.parse(buf.toString()); } catch { return; }
    const { id, method, params = {}, sessionId } = msg;
    if (process.env.BB_TRACE) log('← cdp', { m: method, sid: sessionId, n: tabsOf(slug).length });
    const reply = (payload) => toClient(c, { id, ...payload, ...(sessionId ? { sessionId } : {}) });
    try {
      // Gate on !sessionId: these handlers are browser-level only. Playwright ALSO sends
      // Target.setAutoAttach on a page session to pick up out-of-process iframes, and answering
      // that here instead of forwarding it leaves every cross-origin frame empty.
      if (!sessionId && handlers[method]) return reply({ result: await handlers[method](params) });

      if (PROFILE_WIDE.has(method)) {
        return reply({ error: { code: -32000, message:
          `${method} is refused: it affects the ENTIRE Chrome profile, not just session '${slug}' ` +
          `— it would apply to every site the user is signed into. Do it by hand in Chrome if you ` +
          `really mean it.` } });
      }

      // Browser-level commands we do not implement fall through to the session's first tab
      // rather than "no session for <method>", which broke context.cookies(). chrome.debugger has
      // no browser target, but it does support these per-target.
      const tabId = sessionId ? c.sessions.get(sessionId) : (tabsOf(slug)[0] || {}).tabId ?? null;
      const childSid = sessionId && !sessionId.startsWith('S-') ? sessionId : undefined;
      if (tabId == null) return reply({ error: { code: -32000, message: `no session for ${method}` } });

      const rec = sessionRecord(slug);
      const extId = rec ? liveIdFor(rec.profileDir) : null;
      if (!extId) return reply({ error: { code: -32000, message: `session '${slug}' is not connected` } });

      const r = await callExt(extId, { type: 'cdp', slug, tabId, method, params, sessionId: childSid });
      if (!r.ok) {
        // The tab died but this session still points at it, so every later command would fail
        // the same way forever. Retire it and tell the client, so it re-attaches to a live tab.
        if (/No tab with given id|no page target/i.test(r.error || '')) {
          c.sessions.delete(sessionId);
          // Frame id, not tabId — same invariant as reconcileTargets. Announced under the tabId
          // Playwright never matches the teardown, so the dead tab stays in its page list.
          const gone = String(frameIds.get(tabId) || tabId);
          toClient(c, { method: 'Target.detachedFromTarget', params: { sessionId, targetId: gone } });
          toClient(c, { method: 'Target.targetDestroyed', params: { targetId: gone } });
        }
        return reply({ error: { code: -32000, message: r.error } });
      }
      reply({ result: (r.result && r.result.result) ?? {} });
    } catch (e) {
      reply({ error: { code: -32000, message: String((e && e.message) || e) } });
    }
  });

  ws.on('close', () => {
    const set = clients.get(slug);
    if (set) { set.delete(c); if (!set.size) clients.delete(slug); }
  });
});
cdpServer.on('error', (e) => {
  console.error(`shim: cannot listen on ${CDP_PORT}: ${(e && e.message) || e}`);
  process.exit(1);
});
cdpServer.listen(CDP_PORT, '127.0.0.1');

// ---------------------------------------------------------------- playwright binding
//
// A slug is bindable exactly while its group is live, and the shim binds it so the model never
// runs setup: `bb new-session work` then `playwright-cli -s=work run-code …` is the whole loop.
//
// Retries are BOUNDED — neither unbounded nor zero, and both extremes were worse. `attach` OPENS
// A PAGE as part of connecting, so retrying on every push mints a fresh about:blank in the user's
// group several times a second; never retrying lets one transient failure (playwright-cli
// mid-upgrade, a shim restart landing mid-attach) kill the slug for the shim's lifetime while
// `bb list` still advertises a CDP url. A few spaced attempts cost at most BIND_TRIES stray tabs
// and recover everything transient.
// `attached` is NOT a liveness record: a daemon that dies takes the slug with it (the poisoning
// note in custom-skill.md) and nothing here notices, which is why `bb list` reports the socket.
const attached = new Set();        // slugs bound, or given up on
const bindTries = new Map();       // slug -> attempts so far
const bindLastAt = new Map();      // slug -> when we last tried
const BIND_TRIES = 3;
const BIND_GAP_MS = 20000;

const PW_TIMEOUT_MS = 20000;    // a detach on a dead slug hangs forever otherwise

const cdpUrlFor = (slug) => `http://127.0.0.1:${CDP_PORT}/${encodeURIComponent(slug)}`;

async function pw(args) {
  try { const r = await execFile(PW, args, { timeout: PW_TIMEOUT_MS }); return { ok: true, out: r.stdout }; }
  catch (e) {
    // stderr, not e.message (that is just the command line) and stderr BEFORE stdout: stdout
    // carries playwright-cli's success banner, and logging that as the failure reason reads as
    // an attach that worked and then mysteriously was never retried.
    const err = (e.stderr || '').trim();
    const why = err || `exited ${e.code ?? '?'}${e.stdout ? ` (stdout: ${String(e.stdout).trim().split('\n')[0]})` : ''}`;
    return { ok: false, error: why.split('\n').slice(0, 3).join(' | ').slice(0, 300) };
  }
}

async function bind(slug) {
  if (attached.has(slug)) return;
  const n = bindTries.get(slug) || 0;
  if (n >= BIND_TRIES) return;
  const last = bindLastAt.get(slug) || 0;
  if (n && Date.now() - last < BIND_GAP_MS) return;   // spaced out, so a push storm is one try
  bindTries.set(slug, n + 1);
  bindLastAt.set(slug, Date.now());
  attached.add(slug);                                 // held during the await: pushes race here
  const r = await pw(['-s=' + slug, 'attach', '--cdp=' + cdpUrlFor(slug)]);
  if (r.ok) { log('◆ attached', { slug }); return; }
  attached.delete(slug);
  const giveUp = n + 1 >= BIND_TRIES;
  log(giveUp ? '! attach failed, giving up' : '! attach failed, will retry', { slug, error: r.error });
}

async function unbind(slug) {
  bindTries.delete(slug); bindLastAt.delete(slug);
  if (!attached.delete(slug)) return;
  await pw(['-s=' + slug, 'detach']);
  log('◆ detached', { slug });
}

function syncPlaywright(dir, liveSlugs) {
  // Only slugs WE own. An UNTRACKED ⚙ group (record gone, or one the user titled by hand) is not
  // ours to bind — and binding opens tabs, in a group nobody asked us to touch.
  const ours = new Set(state.sessions.filter((s) => s.profileDir === dir).map((s) => s.slug));
  for (const slug of liveSlugs) if (ours.has(slug)) bind(slug).catch(() => {});
  for (const slug of [...attached]) {
    const rec = sessionRecord(slug);
    if (rec && rec.profileDir !== dir) continue;     // another profile's push says nothing here
    if (!liveSlugs.has(slug)) unbind(slug).catch(() => {});
  }
}

// ---------------------------------------------------------------- profile readiness

async function ensureProfileReady(dir) {
  // One scan, not two: each call re-reads Chrome's Local State plus every profile's multi-MB
  // Secure Preferences.
  const profs = installedProfiles();
  if (!profs.some((p) => p.dir === dir)) {
    throw new Error(`profile '${dir}' doesn't have the browser-blitz extension installed (installed in: ${profs.map((p) => p.dir).join(', ') || 'none'})`);
  }
  const live = liveIdFor(dir);
  if (live) return { id: live, launchTabId: null, coldLaunched: false };

  const token = 'bb' + Math.random().toString(36).slice(2, 10);
  log('◆ launching', { dir, token });
  // -g: do NOT foreground Chrome. Waking a profile is bookkeeping — the MV3 worker dies after
  // ~30s idle and this is how we get it back — so it must never steal focus mid-sentence.
  // Raising a window is `bb <slug> bring-to-front`, and only when someone asked.
  await execFile('open', ['-g', '-na', 'Google Chrome', '--args', '--new-window',
                          `--profile-directory=${dir}`, LAUNCH_URL(token)]);

  // Poll for a connection that HOLDS THE TOKEN. Nothing else proves which directory a connection
  // belongs to: a profile cannot learn its own, and timing alone happily credits an unrelated
  // profile that connected at the same moment.
  const deadline = Date.now() + LAUNCH_TIMEOUT_MS;
  let found = null;
  while (Date.now() < deadline && !found) {
    await sleep(400);
    // Probed concurrently: a profile whose worker is mid-death answers nothing and burns the
    // full PROBE_TIMEOUT_MS. Sequentially a handful would outrun LAUNCH_TIMEOUT_MS on one pass.
    const ids = [...profiles.keys()];
    const replies = await Promise.all(ids.map((id) => callExt(id, { type: 'findTab', token }, PROBE_TIMEOUT_MS)));
    for (let i = 0; i < ids.length; i++) {
      const r = replies[i];
      if (r.ok && r.result && r.result.tabId != null) { found = { id: ids[i], tabId: r.result.tabId }; break; }
    }
  }
  if (!found) {
    throw new Error(`profile '${dir}' did not come up with our launch tab within ${LAUNCH_TIMEOUT_MS / 1000}s — the window may have failed to open, or something closed it`);
  }

  // Deliberate: software that closes windows automatically surfaces here as a clear error, not
  // as a confusing createSession failure two steps later.
  await sleep(STABILIZE_MS);
  if (!profiles.has(found.id)) {
    throw new Error('the window connected briefly then disappeared — something closed it before it stabilized');
  }
  if (mappings[found.id] !== dir) { mappings[found.id] = dir; saveMappings(); }
  return { id: found.id, launchTabId: found.tabId, coldLaunched: true };
}

// Closes the launch tab unless a command consumed it, so a failure after the handshake can't
// strand a token window.
async function withProfile(dir, fn) {
  const p = await ensureProfileReady(dir);
  const used = { consumed: false };
  try { return await fn(p, used); }
  finally {
    if (p.launchTabId != null && !used.consumed) {
      await callExt(p.id, { type: 'closeTab', tabId: p.launchTabId }).catch(() => {});
    }
  }
}

// One command per slug at a time. Two `resume`s racing would each build a group.
const inFlight = new Set();
async function withSlug(slug, fn) {
  if (inFlight.has(slug)) throw new Error(`another command is already running for '${slug}'`);
  inFlight.add(slug);
  try { return await fn(); } finally { inFlight.delete(slug); }
}

// ---------------------------------------------------------------- CLI

async function callSlug(slug, type, extra = {}) {
  const rec = requireRecord(slug);
  const id = liveIdFor(rec.profileDir);
  if (!id) throw new Error(`profile '${rec.profileDir}' is not connected — start a session in it, or run 'bb identify --profile ${rec.profileDir}'`);
  const r = await callExt(id, { type, slug, ...extra });
  if (!r.ok) {
    // A CLOSED session (record on disk, profile connected, group gone) clears the checks above
    // and fails in the extension with "no session here" — true, but it reads like a bug while
    // `bb list` still shows the slug. Only the shim knows a record exists, so it explains.
    if (/^no session '.*' here$/.test(r.error || '')) {
      throw new Error(`session '${slug}' is closed — nothing is open in ${rec.profileDir}; resume it first`);
    }
    throw new Error(r.error);
  }
  return r.result;
}

const cli = {
  'new-session': (a) => withSlug(a.slug, async () => {
    if (!SLUG_RE.test(a.slug || '')) throw new Error(`invalid slug '${a.slug}' — letters, digits, dot, dash, underscore; 1-64 chars`);
    const dup = sessionRecord(a.slug);
    if (dup) throw new Error(`session '${a.slug}' already exists in ${dup.profileDir} — use resume, or delete-session first`);
    const dir = a.profile || DEFAULT_PROFILE;
    return withProfile(dir, async (p, used) => {
      const r = await callExt(p.id, { type: 'createSession', slug: a.slug, colour: colourFor(a.slug), reuseTabId: p.launchTabId });
      if (!r.ok) throw new Error(r.error);
      if (p.launchTabId != null) used.consumed = true;
      state.sessions.push({ slug: a.slug, profileDir: dir, createdAt: new Date().toISOString(), tabs: [] });
      saveState();
      // Not ...r.result: groupId/tabId/windowId/tabCount are debug noise. `adopted` is not — it
      // is the only sign that Chrome handed us a pre-existing ⚙ group full of the user's tabs
      // instead of a fresh one. resume reports it for the same reason.
      return { slug: a.slug, profile: dir, adopted: !!(r.result && r.result.adopted), cdp: cdpUrlFor(a.slug) };
    });
  }),

  resume: (a) => withSlug(a.slug, async () => {
    const rec = requireRecord(a.slug);
    return withProfile(rec.profileDir, async (p, used) => {
      // Chrome's own session restore may still be rebuilding windows. Asking too early creates a
      // second group that tidy then closes — with the tabs we just reopened inside it.
      const deadline = Date.now() + (p.coldLaunched ? SETTLE_MAX_MS : 0);
      let present = false;
      do {
        const h = await callExt(p.id, { type: 'hasSession', slug: a.slug });
        if (h.ok && h.result && h.result.present) { present = true; break; }
        if (Date.now() >= deadline) break;
        await sleep(SETTLE_POLL_MS);
      } while (Date.now() < deadline);

      if (present) {
        return { slug: a.slug, profile: rec.profileDir, adopted: true, cdp: cdpUrlFor(a.slug) };
      }
      const r = await callExt(p.id, { type: 'createSession', slug: a.slug, colour: colourFor(a.slug), reuseTabId: p.launchTabId });
      if (!r.ok) throw new Error(r.error);
      if (p.launchTabId != null) used.consumed = true;
      // Reopening is Playwright's job now — it is attached the moment the group is live.
      return { slug: a.slug, profile: rec.profileDir, adopted: false, saved: rec.tabs.length, cdp: cdpUrlFor(a.slug) };
    });
  }),

  'delete-session': (a) => withSlug(a.slug, async () => {
    const rec = sessionRecord(a.slug);
    const liveIn = [...mirrors.entries()].find(([d, m]) => isConnected(d) && m.sessions.some((s) => s.slug === a.slug));
    if (!rec && !liveIn) return { nothing: true };                 // idempotent
    const dir = rec ? rec.profileDir : liveIn[0];
    await unbind(a.slug);
    const id = liveIdFor(dir);
    if (!id) throw new Error(`profile '${dir}' is not connected — open it and try again`);
    const r = await callExt(id, { type: 'closeSession', slug: a.slug, keepTabs: !!a.keep });
    if (!r.ok) throw new Error(r.error);
    if (rec) { state.sessions = state.sessions.filter((s) => s.slug !== a.slug); saveState(); }
    // Prune the mirror too: the next push is ~120ms of debounce away, and until it lands
    // `bb list` re-adds the slug we just deleted as an UNTRACKED row, which reads as an orphaned
    // group needing attention rather than "closed, one moment".
    const m = mirrors.get(dir);
    if (m) m.sessions = m.sessions.filter((s) => s.slug !== a.slug);
    return { slug: a.slug, profile: dir, ...r.result };
  }),

  list: () => {
    const rows = state.sessions.map((rec) => {
      const m = mirrors.get(rec.profileDir);
      const live = m && m.sessions.find((s) => s.slug === rec.slug);
      const connected = isConnected(rec.profileDir);
      const status = !connected ? 'UNKNOWN' : live ? 'LIVE' : 'CLOSED';
      return { slug: rec.slug, profile: rec.profileDir, status,
               tabs: live ? live.tabs.length : (rec.tabs.length ? `${rec.tabs.length} saved` : ''),
               // A CONNECTED CDP SOCKET, not a remembered intention: reporting that `attach`
               // once exited 0 said "bound" for a daemon that had since died, and the session
               // hung with no warning. A closing socket is the only honest signal there is.
               driver: clientsOf(rec.slug).size ? 'connected' : '',
               cdp: status === 'LIVE' ? cdpUrlFor(rec.slug) : '' };
    });
    const known = new Set(state.sessions.map((s) => s.slug));
    for (const [dir, m] of mirrors) {
      if (!isConnected(dir)) continue;
      for (const s of m.sessions) {
        if (!known.has(s.slug)) rows.push({ slug: s.slug, profile: dir, status: 'UNTRACKED', tabs: s.tabs.length, driver: '', cdp: '' });
      }
    }
    return rows;
  },

  identify: async (a) => {
    const dir = a.profile || DEFAULT_PROFILE;
    return withProfile(dir, async (p) => ({ profile: dir, identity: p.id, coldLaunched: p.coldLaunched }));
  },

  'extension-status': () => {
    const installed = installedProfiles();
    const conn = [...profiles.entries()].map(([id, p]) => ({ identity: id, build: p.build, dir: mappings[id] || '?' }));
    return {
      installed: installed.map((p) => ({ ...p, status: isConnected(p.dir) ? 'CONNECTED' : (idsForDir(p.dir).length ? 'DISCONNECTED' : 'UNKNOWN') })),
      connected: conn,
    };
  },

  'list-tabs': async (a) => {
    const dir = a.profile || DEFAULT_PROFILE;
    const id = liveIdFor(dir);
    if (!id) {
      throw new Error(idsForDir(dir).length
        ? `profile '${dir}' is not connected — its Chrome window may be closed, or its worker asleep; 'bb identify --profile ${dir}' wakes it`
        : `profile '${dir}' has never been identified — run 'bb identify --profile ${dir}'`);
    }
    const r = await callExt(id, { type: 'listAllTabs' });
    if (!r.ok) throw new Error(r.error);
    return r.result.tabs.map((t) => ({
      tab: t.tabId, session: t.slug || '', title: (t.title || '').slice(0, 38), url: shortUrl(t.url),
    }));
  },

  'bring-to-front': (a) => callSlug(a.slug, 'bringToFront'),
  'grab-tab': (a) => callSlug(a.slug, 'grabTab', { tabIds: a.tabIds, duplicate: !!a.duplicate }),
  'release-tab': (a) => callSlug(a.slug, 'releaseTab', { tabIds: a.tabIds, duplicate: !!a.duplicate }),
};

// ---------------------------------------------------------------- CLI socket

function startCliSocket() {
  try { fs.unlinkSync(SOCK); } catch {}
  net.createServer((conn) => {
    let buf = '';
    conn.on('error', () => {});
    conn.on('data', async (d) => {
      buf += d;
      const nl = buf.indexOf('\n');
      if (nl < 0) return;
      const line = buf.slice(0, nl); buf = '';
      let a; try { a = JSON.parse(line); } catch { return conn.end(JSON.stringify({ ok: false, error: 'bad json' }) + '\n'); }
      const fn = cli[a.cmd];
      let out;
      if (!fn) out = { ok: false, error: `unknown command '${a.cmd}'` };
      else {
        try { out = { ok: true, result: await fn(a) }; }
        catch (e) { out = { ok: false, error: String((e && e.message) || e) }; }
      }
      try { conn.end(JSON.stringify(out) + '\n'); } catch {}
    });
  }).listen(SOCK, () => log('◆ cli socket', { path: SOCK }));
}
startCliSocket();

// The extension's worker dies after ~30s idle and a silent socket does not count as activity.
//
// EVERY connected profile, not just the ones holding a session. Scoped to live sessions, an idle
// profile's worker dies, and the next `bb new-session` there has to relaunch Chrome with
// `open -na` just to wake it — a window blip, and a focus steal if the launch foregrounds.
// A worker parked on a WebSocket costs approximately nothing; interrupting someone does.
setInterval(() => {
  for (const [, p] of profiles) {
    try { p.ws.send(JSON.stringify({ type: 'ping', id: seq++ })); } catch {}
  }
}, PING_MS);

console.log(`shim: extensions on ${EXT_PORT}, CDP on ${CDP_PORT}, cli on ${SOCK}`);
