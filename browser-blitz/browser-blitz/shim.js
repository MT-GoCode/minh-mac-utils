// browser-blitz shim.
//
// Three servers:
//   :9334  loopback WebSocket the extension dials into
//   :9342  a CDP browser endpoint per slug, at /<slug> — this is what Playwright attaches to
//   unix   the CLI socket
//
// Owns all state and every decision. The extension answers questions about tabs and groups and
// relays CDP; Playwright does all the driving.
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

fs.mkdirSync(STATE_DIR, { recursive: true });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ---------------------------------------------------------------- logging
//
// Summarised, and rotated. Full CDP payloads are enormous once Playwright is attached (it
// enables Page, Runtime and Network and every event flows through here), and an unrotated log
// reached 352 MB in two days.
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
  // Origin is set by the browser and a web page cannot forge it. Without this check ANY website
  // the user visits can open a socket here, claim an identity, and receive commands. A native
  // local process can still forge it — same trust level as reading the Chrome profile directory.
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

  // Attach/detach Playwright to match reality. A slug is bindable exactly while its group is
  // live; anything else and `playwright-cli -s=<slug>` should not be pointing at a dead endpoint.
  syncPlaywright(dir, new Set(sessions.map((s) => s.slug)));
  // A tab that joined or left an attached slug has to be announced to the connected client.
  for (const s of sessions) reconcileTargets(s.slug, s.tabs).catch(() => {});
}

// ---------------------------------------------------------------- CDP endpoint
//
// One port, slug as PATH. Playwright appends /json/version/ to whatever URL you hand it — with a
// trailing slash, measured — and then connects to whatever absolute webSocketDebuggerUrl the
// response carries. Both facts together mean a port RANGE is unnecessary: the old design's
// allocPort, its 9340-9399 window and its stale-port collision are all gone.
const clients = new Map();    // slug -> Set<{ ws, sessions:Map<sessionId,tabId>, autoAttach:bool }>

const sidFor = (tabId) => 'S-' + tabId;

// Chrome guarantees a page target's id EQUALS its main frame's id, and Playwright depends on it:
// crPage.js keys _sessions by frame id but registers the main session under the TARGET id, then
// _sessionForFrame walks up from the frame and throws "Frame has been detached." when the lookup
// misses. Using tabId as the targetId broke that invariant, so every page was born detached.
// So: learn each tab's real main-frame id and use THAT as its target id.
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

// BB_TRACE=1 logs the CDP conversation. It is how the stray-about:blank bug was found: the
// trace showed Target.createTarget arriving 8ms after setAutoAttach, before our announce.
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
      toClient(c, { method: 'Target.detachedFromTarget', params: { sessionId: sid, targetId: String(tabId) } });
      toClient(c, { method: 'Target.targetDestroyed', params: { targetId: String(tabId) } });
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
      // Chrome auto-attaches OOPIFs and announces them here. Register the child so a command
      // addressed to it resolves back to this tab; without this Playwright gets a session id it
      // can address and the shim answers "no session for <method>".
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
    // No targetId means Playwright is asking about the BROWSER target, not a page. Answering
    // with a page made it register that page AS the browser, after which the real page never got
    // a frame model — page.url() came back '' and every goto failed "Frame has been detached".
    'Target.getTargetInfo': (p) => {
      if (!p || !p.targetId) {
        return { targetInfo: { targetId: 'browser', type: 'browser', title: '', url: '',
                               attached: true, canAccessOpener: false } };
      }
      const want = tabForFrame(p.targetId) ?? Number(p.targetId);
      const t = tabsOf(slug).find((x) => x.tabId === want);
      if (!t) throw new Error(`no target ${p.targetId}`);
      return { targetInfo: targetInfo(t) };
    },
    'Target.setDiscoverTargets': async () => {
      await learnFrames(slug);
      for (const t of tabsOf(slug)) toClient(c, { method: 'Target.targetCreated', params: { targetInfo: targetInfo(t) } });
      return {};
    },
    // THE handshake step. Playwright sends this with flatten:true and waits for
    // Target.attachedToTarget before it believes any page exists — and gives up after ~8ms,
    // calling Target.createTarget and minting a stray tab. So the announce goes out BEFORE this
    // command's own response, not on a timer: frame ids are resolved first, then the events, then
    // the reply. Anything slower loses the race.
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
      const tabId = tabForFrame(p.targetId) ?? Number(p.targetId);
      const sid = sidFor(tabId);
      c.sessions.set(sid, tabId);
      return { sessionId: sid };
    },
    'Target.detachFromTarget': (p) => { c.sessions.delete(p.sessionId); return {}; },
    'Target.activateTarget': async (p) => {
      const id = liveIdFor(requireRecord(slug).profileDir);
      await callExt(id, { type: 'activateTab', tabId: tabForFrame(p.targetId) ?? Number(p.targetId) });
      return {};
    },
    // New tabs land INSIDE the slug's group. This is the fence: a page Playwright opens cannot
    // escape into the user's ordinary browsing.
    'Target.createTarget': async (p) => {
      const id = liveIdFor(requireRecord(slug).profileDir);
      const r = await callExt(id, { type: 'createTabInGroup', slug, url: p.url });
      if (!r.ok) throw new Error(r.error);
      const tabId = r.result.tabId;
      const fid = await learnFrameId(requireRecord(slug).profileDir, tabId);
      // Announce it NOW, not on the next push. newPage() waits for Target.attachedToTarget right
      // after createTarget returns; a 120ms debounced push is far too late and it fails with
      // "Cannot read properties of undefined (reading '_page')".
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
      const id = liveIdFor(requireRecord(slug).profileDir);
      await callExt(id, { type: 'closeTab', tabId: tabForFrame(p.targetId) ?? Number(p.targetId) });
      return { success: true };
    },
    'Runtime.runIfWaitingForDebugger': () => ({}),
  };
}

const cdpServer = http.createServer((req, res) => {
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

const cdpWss = new WebSocketServer({ server: cdpServer });
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
      // Gate on !sessionId. Matching by method alone swallowed Target.setAutoAttach when
      // Playwright sent it on a PAGE session to pick up out-of-process iframes, so chrome.debugger
      // never auto-attached the child target and every cross-origin frame stayed empty.
      if (!sessionId && handlers[method]) return reply({ result: await handlers[method](params) });

      const tabId = sessionId ? c.sessions.get(sessionId) : null;
      const childSid = sessionId && !sessionId.startsWith('S-') ? sessionId : undefined;
      if (tabId == null) return reply({ error: { code: -32000, message: `no session for ${method}` } });

      const rec = sessionRecord(slug);
      const extId = rec ? liveIdFor(rec.profileDir) : null;
      if (!extId) return reply({ error: { code: -32000, message: `session '${slug}' is not connected` } });

      const r = await callExt(extId, { type: 'cdp', tabId, method, params, sessionId: childSid });
      if (!r.ok) {
        // The tab died but this session still points at it, so every later command would fail
        // the same way forever. Retire it and tell the client, so it re-attaches to a live tab.
        if (/No tab with given id|no page target/i.test(r.error || '')) {
          c.sessions.delete(sessionId);
          toClient(c, { method: 'Target.detachedFromTarget', params: { sessionId, targetId: String(tabId) } });
          toClient(c, { method: 'Target.targetDestroyed', params: { targetId: String(tabId) } });
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
    log('◆ cdp client gone', { slug });
  });
});
cdpServer.on('error', (e) => {
  console.error(`shim: cannot listen on ${CDP_PORT}: ${(e && e.message) || e}`);
  process.exit(1);
});
cdpServer.listen(CDP_PORT, '127.0.0.1');

// ---------------------------------------------------------------- playwright binding
//
// A slug is bindable exactly while its group is live. The shim owns this so the model never has
// to run setup: `bb new-session work` and `playwright-cli -s=work run-code …` is the whole loop.
const bound = new Set();
// A bind that failed is NOT retried on the next push. It used to be, and since every push
// retries every slug that is a hot loop: `playwright-cli attach` opens a page as part of
// connecting, so a failing bind minted a fresh about:blank in the user's group several times a
// second. Cleared when the session goes away, so the next new-session/resume tries again.
const bindFailed = new Map();   // slug -> reason

const cdpUrlFor = (slug) => `http://127.0.0.1:${CDP_PORT}/${encodeURIComponent(slug)}`;

async function pw(args) {
  try { const r = await execFile(PW, args); return { ok: true, out: r.stdout }; }
  catch (e) {
    // stderr, not e.message: execFile's message is the command line, which says nothing.
    const why = (e.stderr || e.stdout || String(e.message || e)).trim().split('\n').slice(0, 3).join(' | ');
    return { ok: false, error: why.slice(0, 300) };
  }
}

async function bind(slug) {
  if (bound.has(slug) || bindFailed.has(slug)) return;
  bound.add(slug);                                   // added first: two pushes can race here
  const r = await pw(['-s=' + slug, 'attach', '--cdp=' + cdpUrlFor(slug)]);
  if (r.ok) { log('◆ bound', { slug }); return; }
  bound.delete(slug);
  bindFailed.set(slug, r.error);
  log('! bind failed', { slug, error: r.error });    // logged ONCE, not every push
}

async function unbind(slug) {
  bindFailed.delete(slug);
  if (!bound.has(slug)) return;
  bound.delete(slug);
  await pw(['-s=' + slug, 'detach']);
  log('◆ unbound', { slug });
}

function syncPlaywright(dir, liveSlugs) {
  // Only slugs WE own. An UNTRACKED ⚙ group — one whose record is gone, or a group the user
  // titled by hand — is not ours to bind, and binding it opened tabs in a group nobody asked
  // us to touch.
  const ours = new Set(state.sessions.filter((s) => s.profileDir === dir).map((s) => s.slug));
  for (const slug of liveSlugs) if (ours.has(slug)) bind(slug).catch(() => {});
  for (const slug of [...bound, ...bindFailed.keys()]) {
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
  await execFile('open', ['-na', 'Google Chrome', '--args', '--new-window',
                          `--profile-directory=${dir}`, LAUNCH_URL(token)]);

  // Poll for a connection that HOLDS THE TOKEN. Nothing else proves which directory a connection
  // belongs to — a profile cannot learn its own directory, and timing alone would happily
  // attribute an unrelated profile that connected at the same moment.
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
    // A CLOSED session — record on disk, profile connected, group gone — passes the checks above
    // and fails in the extension with "no session here". True, but it reads like a bug when
    // `bb list` shows the slug. The shim knows a record exists, so it can say what happened.
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
      return { slug: a.slug, profile: dir, cdp: cdpUrlFor(a.slug), ...r.result };
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
               bound: bound.has(rec.slug) ? 'yes' : (bindFailed.get(rec.slug) ? 'FAILED' : ''), cdp: status === 'LIVE' ? cdpUrlFor(rec.slug) : '' };
    });
    const known = new Set(state.sessions.map((s) => s.slug));
    for (const [dir, m] of mirrors) {
      if (!isConnected(dir)) continue;
      for (const s of m.sessions) {
        if (!known.has(s.slug)) rows.push({ slug: s.slug, profile: dir, status: 'UNTRACKED', tabs: s.tabs.length, bound: '', cdp: '' });
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
// Scoped to profiles that actually hold a live session — pinging an idle one pins its worker
// alive forever for nothing.
setInterval(() => {
  for (const [dir, m] of mirrors) {
    if (!m.sessions.length) continue;
    const id = liveIdFor(dir);
    if (id) { const p = profiles.get(id); try { p.ws.send(JSON.stringify({ type: 'ping', id: seq++ })); } catch {} }
  }
}, PING_MS);

console.log(`shim: extensions on ${EXT_PORT}, CDP on ${CDP_PORT}, cli on ${SOCK}`);
