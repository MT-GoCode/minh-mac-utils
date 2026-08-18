// browser-blitz: lets any CDP client (agent-browser, Playwright, ...) drive the REAL logged-in
// Chrome profile, fenced to a tab group per slug.
//
//   agent-browser --cdp <slugPort> ⇄ shim ⇄ extension(per profile) ⇄ chrome.debugger ⇄ tabs
//   browser-blitz CLI              ⇄ unix socket
//
// Why: Chrome 136+ ignores --remote-debugging-port on the default user-data-dir; the M144
// chrome://inspect path exposes no /json discovery and re-prompts per connection; copying a
// profile loses logins. chrome.debugger is the only no-prompt route into a logged-in profile.
const http = require('http');
const fs = require('fs');
const net = require('net');
const path = require('path');
const os = require('os');
const { WebSocketServer } = require('ws');
const { execFileSync } = require('child_process');

const EXT_PORT = 9334;
const PORT_MIN = 9340, PORT_MAX = 9399;
const STATE_DIR = path.join(os.homedir(), '.local/state/browser-blitz');
const SOCK = path.join(STATE_DIR, 'shim.sock');
const REGISTRY = path.join(STATE_DIR, 'slugs.json');
const GROUP_COLORS = ['purple','cyan','green','pink','orange','blue','red','yellow','grey'];

fs.mkdirSync(STATE_DIR, { recursive: true });
const log = (...a) => console.log(new Date().toISOString().slice(11,19), ...a);

// ---------------------------------------------------------------- extensions

let seq = 1;
const pending = new Map();            // reqId -> resolve
const profiles = new Map();           // profileKey -> {ws, email, profileId, tabs:[]}

function callExt(profileKey, msg) {
  return new Promise((resolve) => {
    const p = profiles.get(profileKey);
    if (!p || p.ws.readyState !== 1) return resolve({ error: 'profile not connected' });
    const id = seq++;
    pending.set(id, resolve);
    p.ws.send(JSON.stringify({ ...msg, id }));
    setTimeout(() => {
      if (pending.has(id)) { pending.delete(id); resolve({ error: 'extension timeout' }); }
    }, 20000);
  });
}

// Sockets that connected but never sent `hello` within 5s — an extension that threw during
// startup (e.g. a missing permission). Tracked as a Set so a late identification removes the
// exact socket rather than decrementing a counter that could drift.
const staleSockets = new Set();

const extWss = new WebSocketServer({ port: EXT_PORT });
extWss.on('connection', (ws) => {
  let key = null;
  // A working extension sends `hello` immediately. A socket that connects and stays silent
  // threw during startup — surfaced by `status` so it isn't mistaken for "not connected".
  const staleTimer = setTimeout(() => {
    if (!key) {
      staleSockets.add(ws);
      // Most likely the extension threw before sending `hello` (a missing permission will do
      // it). Check chrome://extensions → Errors before assuming it's an old build.
      log('WARNING: extension connected but never sent hello — check chrome://extensions → Errors');
    }
  }, 5000);
  ws.on('message', (buf) => {
    let m; try { m = JSON.parse(buf.toString()); } catch { return; }

    if (m.type === 'hello') {
      key = m.profile.email || m.profile.profileId;
      staleSockets.delete(ws);          // identified, however late
      clearTimeout(staleTimer);
      profiles.set(key, { ws, email: m.profile.email, profileId: m.profile.profileId,
                          profileDir: m.profile.profileDir || null,
                          build: m.profile.build || 'unknown', tabs: [] });
      log('profile connected:', key, 'dir', m.profile.profileDir || '(unassigned)',
          'build', m.profile.build || 'unknown');
      // Restore any slugs whose groups survived the restart.
      readoptSlugs(key).catch(e => log('re-adopt failed:', e.message));
      return;
    }
    if (m.type === 'pong') return;

    if (m.type === 'res') {
      const r = pending.get(m.id);
      if (r) { pending.delete(m.id); r(m); }
      return;
    }
    if (m.type === 'tabs') {
      const p = profiles.get(key);
      if (p) { p.tabs = m.tabs || []; reconcileAll(key); }
      return;
    }
    if (m.type === 'cdpEvent') {
      for (const s of slugs.values()) {
        if (s.profileKey !== key) continue;
        // Under setDownloadBehavior Chrome names the saved file after this GUID, and that's
        // what the client looks for — not the original filename.
        for (const [sessionId, tabId] of s.sessions) {
          if (String(tabId) !== String(m.tabId)) continue;
          slugBroadcast(s, { method: m.method, params: m.params, sessionId });
        }
      }
    }
  });
  ws.on('close', () => {
    clearTimeout(staleTimer);
    staleSockets.delete(ws);
    if (key) { profiles.delete(key); log('profile gone:', key); }
  });
});

// An idle-but-open WebSocket does NOT keep an MV3 service worker alive (observed: died at
// 54s). Traffic does, so ping well inside that window — but ONLY for profiles running a
// session. Pinging an idle profile pins its service worker alive forever for no reason; let
// it sleep, show as cold, and get nudged when a session actually needs it.
setInterval(() => {
  const busy = new Set([...slugs.values()].map(s => s.profileKey));
  for (const [key, p] of profiles) {
    if (busy.has(key) && p.ws.readyState === 1) p.ws.send(JSON.stringify({ type: 'ping' }));
  }
}, 15000);

// --------------------------------------------------------------------- slugs

const slugs = new Map();  // slug -> {slug, profileKey, groupId, windowId, port, server, wss,
                          //          clients:Set, sessions:Map, known:Set, color, lastInteraction}

const tabsInGroup = (s) => {
  const p = profiles.get(s.profileKey);
  if (!p) return [];
  return p.tabs.filter(t => t.groupId === s.groupId);
};

const targetInfo = (t) => ({
  targetId: t.tabId, type: 'page', title: t.title, url: t.url,
  attached: false, canAccessOpener: false, browserContextId: 'DEFAULT',
});

function slugBroadcast(s, obj) {
  const str = JSON.stringify(obj);
  for (const c of s.clients) if (c.readyState === 1) c.send(str);
}

// Chrome's group membership is the source of truth. Diff it into Target lifecycle events so
// dragging a tab in/out behaves exactly like a target appearing/vanishing in a real browser.
function reconcileAll(profileKey) {
  for (const s of slugs.values()) {
    if (s.profileKey !== profileKey) continue;

    const now = tabsInGroup(s);
    const nowIds = new Set(now.map(t => t.tabId));

    for (const t of now) {
      if (!s.known.has(t.tabId)) {
        s.known.add(t.tabId);
        // Attach before the page can load anything. See sw.js 'attachTab': an attachment made
        // while the tab is blank survives into pages that would refuse a fresh attach.
        callExt(s.profileKey, { type: 'attachTab', tabId: t.tabId })
          .then(r => { if (r.error) log(`eager attach failed for tab ${t.tabId}: ${r.error}`); })
          .catch(() => {});
        slugBroadcast(s, { method: 'Target.targetCreated', params: { targetInfo: targetInfo(t) } });
      }
    }
    for (const id of [...s.known]) {
      if (!nowIds.has(id)) {
        s.known.delete(id);
        for (const [sid, tid] of [...s.sessions]) if (String(tid) === String(id)) s.sessions.delete(sid);
        slugBroadcast(s, { method: 'Target.targetDestroyed', params: { targetId: id } });
      }
    }

    // Group deleted by the user = kill switch for the slug.
    const stillExists = profiles.get(profileKey)?.tabs.some(t => t.groupId === s.groupId);
    if (!stillExists && s.known.size === 0 && s.hadTabs) {
      log(`slug '${s.slug}' ended (group gone)`);
      destroySlug(s.slug);
    }
    if (now.length) s.hadTabs = true;
  }
}

function allocPort() {
  const used = new Set([...slugs.values()].map(s => s.port));
  for (let p = PORT_MIN; p <= PORT_MAX; p++) if (!used.has(p)) return p;
  throw new Error('no free ports in 9340-9399');
}

// ----------------------------------------------------------- cold profiles
//
// An extension only runs while its profile is loaded, so a profile with no windows has no
// connection to talk to. `open -n -a "Google Chrome" --args --profile-directory=<dir>` is the
// only way in — it opens a window in that specific profile, which starts the extension.
// NOTE: --profile-directory takes the DIRECTORY name ("Profile 5"), not the display name
// ("RemoteAgent"). Passing a display name silently creates a new empty profile.
//
// Chrome steals focus on launch, so capture the frontmost app first and hand focus back.
// lsappinfo/open need no Accessibility permission, unlike System Events.

const frontmostApp = () => {
  try {
    const asn = execFileSync('lsappinfo', ['front'], { encoding: 'utf8' }).trim();
    const out = execFileSync('lsappinfo', ['info', '-only', 'name', asn], { encoding: 'utf8' });
    const m = out.match(/"LSDisplayName"="([^"]+)"/);
    return m ? m[1] : null;
  } catch { return null; }
};

// Identify which connection is a given profile directory, launching it if it isn't running.
// Launch it on a UNIQUE sentinel URL, then find the connection whose tabs contain that token.
// This is immune to other profiles connecting/cycling at the same time and needs no fragile
// before/after window diffing — the token is unambiguous.
async function identifyProfile(dir) {
  const already = [...profiles.entries()].find(([, p]) => p.profileDir === dir);
  if (already) return { key: already[0], seedTabId: null };

  const token = 'umc-warm-' + Math.random().toString(36).slice(2, 10);
  const sentinel = `data:text/html,<title>${token}</title>`;
  const prevApp = frontmostApp();
  log(`locating profile '${dir}' via sentinel ${token} (frontmost was ${prevApp || 'unknown'})`);

  execFileSync('open', ['-n', '-a', 'Google Chrome', '--args',
                        `--profile-directory=${dir}`, sentinel]);

  let key = null, seedTabId = null;
  const deadline = Date.now() + 30000;
  while (Date.now() < deadline && !key) {
    await new Promise(r => setTimeout(r, 400));
    for (const [k, p] of profiles) {
      const t = (p.tabs || []).find(t => (t.url || '').includes(token));
      if (t) { key = k; seedTabId = t.tabId; break; }
    }
  }

  // Chrome takes focus on launch either way — hand it back.
  if (prevApp) { try { execFileSync('open', ['-a', prevApp]); } catch {} }

  if (!key) throw new Error(`profile '${dir}' did not connect within 30s of launch`);

  // This is the only moment the mapping is certain, so persist it in the extension.
  await callExt(key, { type: 'setProfileDir', profileDir: dir });
  profiles.get(key).profileDir = dir;
  log(`profile '${dir}' identified as ${key}`);
  return { key, seedTabId };
}

// ------------------------------------------------------- destructive guard
//
// These CDP methods act on the WHOLE profile, not the slug's tabs — the fence does not
// contain them. Network.clearBrowserCookies signs the user out of every site in the real
// profile, which is exactly what this tool exists to protect. Refused unless the slug was
// created with allowDestructive.
const PROFILE_WIDE_DESTRUCTIVE = new Set([
  'Network.clearBrowserCookies',
  'Network.clearBrowserCache',
  'Storage.clearCookies',
  'Storage.clearDataForOrigin',
  'Storage.clearDataForStorageKey',
  'Storage.clearTrustTokens',
  'Browser.resetPermissions',
]);

// ------------------------------------------------- browser-level CDP per slug

function browserLevel(s) {
  return {
    'Target.setDiscoverTargets': () => {
      setTimeout(() => {
        for (const t of tabsInGroup(s)) {
          if (s.known.has(t.tabId)) continue;   // reconcileAll already announced it; no dupes
          s.known.add(t.tabId);
          slugBroadcast(s, { method: 'Target.targetCreated', params: { targetInfo: targetInfo(t) } });
        }
      }, 10);
      return {};
    },
    'Target.getTargets': () => ({ targetInfos: tabsInGroup(s).map(targetInfo) }),
    'Target.getBrowserContexts': () => ({ browserContextIds: ['DEFAULT'] }),
    // Real browser contexts (incognito-style isolation) don't exist here — every slug lives in
    // the user's one real profile. Hand back a synthetic id so clients that ask for one can
    // proceed; `window new` then behaves as `tab new` inside the slug's group, because a tab
    // group cannot span windows.
    'Target.createBrowserContext': () => ({ browserContextId: 'CTX-' + s.slug }),
    'Target.disposeBrowserContext': () => ({}),
    'Target.setAutoAttach': () => ({}),
    'Target.attachToTarget': (p) => {
      const sessionId = 'S-' + p.targetId;
      // Number: chrome.debugger.sendCommand rejects a string tabId outright.
      s.sessions.set(sessionId, Number(p.targetId));
      return { sessionId };
    },
    'Target.detachFromTarget': (p) => { s.sessions.delete(p.sessionId); return {}; },
    'Target.activateTarget': async (p) => {
      await callExt(s.profileKey, { type: 'activateTab', tabId: p.targetId }); return {};
    },
    'Target.createTarget': async (p) => {
      const r = await callExt(s.profileKey, { type: 'createTabInGroup', groupId: s.groupId, url: p.url });
      if (r.error) throw new Error(r.error);
      const res = r.result || {};
      return { targetId: String(res.tabId) };
    },
    'Target.closeTarget': async (p) => {
      await callExt(s.profileKey, { type: 'closeTab', tabId: p.targetId });
      return { success: true };
    },
    'Browser.getVersion': () => ({
      protocolVersion: '1.3', product: 'Chrome/151.0.7922.138', revision: '',
      userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.7922.138 Safari/537.36',
      jsVersion: '15.1',
    }),
    'Runtime.runIfWaitingForDebugger': () => ({}),
    // Browser-domain method; absent on a per-tab debugger session. agent-browser calls it before
    // a download, so ack it. Downloads are NOT intercepted — the file saves to Chrome's normal
    // Downloads folder. To capture one, read its URL and fetch it directly (see README).
    'Browser.setDownloadBehavior': () => ({}),
    // `agent-browser close` asks the browser to quit. That would close the USER'S whole
    // Chrome, not just this slug. Refuse with the right instruction instead.
    'Browser.close': () => {
      throw new Error('refused: this would quit the user\'s entire Chrome. ' +
        'End the session with `browser-blitz end <slug>` instead.');
    },
    'Page.setDownloadBehavior': () => ({}),
  };
}

function startSlugServer(s) {
  const server = http.createServer((req, res) => {
    const json = (o) => { res.writeHead(200, {'Content-Type':'application/json'}); res.end(JSON.stringify(o)); };
    if (req.url === '/json/version') {
      return json({ Browser: 'Chrome/151.0.7922.138', 'Protocol-Version': '1.3',
        'User-Agent': 'shim', 'V8-Version': '15.1', 'WebKit-Version': '537.36',
        webSocketDebuggerUrl: `ws://127.0.0.1:${s.port}/devtools/browser/${s.slug}` });
    }
    if (req.url === '/json' || req.url === '/json/list') {
      return json(tabsInGroup(s).map(t => ({
        id: t.tabId, type: 'page', title: t.title, url: t.url,
        webSocketDebuggerUrl: `ws://127.0.0.1:${s.port}/devtools/page/${t.tabId}` })));
    }
    res.writeHead(404); res.end('{}');
  });

  const wss = new WebSocketServer({ server });
  const handlers = browserLevel(s);

  wss.on('connection', (ws) => {
    s.clients.add(ws);
    ws.on('message', async (buf) => {
      let msg; try { msg = JSON.parse(buf.toString()); } catch { return; }
      const { id, method, params = {}, sessionId } = msg;
      s.lastInteraction = Date.now();
      const send = (payload) => ws.readyState === 1 &&
        ws.send(JSON.stringify({ id, ...payload, ...(sessionId ? { sessionId } : {}) }));
      try {
        if (handlers[method]) return send({ result: await handlers[method](params) });
        const tabId = sessionId ? s.sessions.get(sessionId) : null;
        if (!tabId) return send({ error: { code: -32000, message: `no session for ${method}` } });
        // Any command against a tab counts as touching it — reading a page is interaction too.
        // This is what `bring-to-front` lands on.
        s.lastTabId = tabId;

        if (PROFILE_WIDE_DESTRUCTIVE.has(method) && !s.allowDestructive) {
          return send({ error: { code: -32000, message:
            `${method} is refused: it affects the ENTIRE Chrome profile, not just this slug's ` +
            `tabs (e.g. signing you out of every site). Start the session with ` +
            `--allow-destructive if you really mean it.` } });
        }

        // Chrome discards Input.* aimed at a tab that isn't the active tab of its window,
        // returning {} with no error. Activate every time (idempotent): a cached "already
        // active" flag goes stale the moment activateTarget, bring-to-front, or a manual tab
        // switch changes the active tab, and then input would be silently dropped. The
        // extension reports whether it actually switched, so we only pay the settle delay when
        // a switch happened.
        if (method.startsWith('Input.')) {
          const act = await callExt(s.profileKey, { type: 'activateTab', tabId });
          if (act.error) {
            return send({ error: { code: -32000,
              message: `cannot activate tab ${tabId} for ${method}: ${act.error}` } });
          }
          if (act.result && act.result.changed) await new Promise(r => setTimeout(r, 200));
          const r = await callExt(s.profileKey, { type: 'cdp', tabId, method, params });
          if (r.error) return send({ error: { code: -32000, message: r.error } });
          return send({ result: r.result ?? {} });
        }

        const r = await callExt(s.profileKey, { type: 'cdp', tabId, method, params });
        if (r.error) {
          // The tab died (closed by the user, replaced by the page, or discarded) but this
          // session still points at it, so every later command would fail the same way forever.
          // Retire the dead target now: drop its sessions, forget it, and tell the client it is
          // gone so it re-attaches to a live tab in the group instead of wedging.
          if (/No tab with given id|no page target for tab/i.test(r.error)) {
            s.known.delete(tabId);
            for (const [sid, tid] of [...s.sessions]) if (String(tid) === String(tabId)) s.sessions.delete(sid);
            slugBroadcast(s, { method: 'Target.targetDestroyed', params: { targetId: String(tabId) } });
            log(`retired dead tab ${tabId} for slug '${s.slug}'`);
            return send({ error: { code: -32000, message:
              `tab ${tabId} no longer exists; it has been retired. Re-attach to a current ` +
              `target (Target.getTargets) or open a new tab.` } });
          }
          return send({ error: { code: -32000, message: r.error } });
        }
        send({ result: r.result ?? {} });
      } catch (e) {
        send({ error: { code: -32000, message: String(e && e.message || e) } });
      }
    });
    ws.on('close', () => s.clients.delete(ws));
  });

  server.listen(s.port, '127.0.0.1');
  s.server = server; s.wss = wss;
}

function destroySlug(slug) {
  const s = slugs.get(slug);
  if (!s) return;
  try { s.wss.close(); s.server.close(); } catch {}
  slugs.delete(slug);
  saveRegistry();
}

const saveRegistry = () => fs.writeFileSync(REGISTRY, JSON.stringify(
  [...slugs.values()].map(s => ({ slug: s.slug, profileKey: s.profileKey, groupId: s.groupId,
    windowId: s.windowId, port: s.port, color: s.color,
    allowDestructive: s.allowDestructive })), null, 2));

// Re-adopt slugs after a restart. Without this the registry is write-only: the shim forgets
// its slugs on every restart while Chrome keeps the groups, orphaning them permanently
// (they can no longer be `end`ed, because nothing knows they exist).
async function readoptSlugs(profileKey) {
  let saved = [];
  try { saved = JSON.parse(fs.readFileSync(REGISTRY, 'utf8')); } catch { return; }
  if (!Array.isArray(saved) || !saved.length) return;

  const r = await callExt(profileKey, { type: 'listGroups' });
  const liveGroups = new Set(((r.result && r.result.groups) || []).map(g => g.groupId));

  for (const e of saved) {
    if (e.profileKey !== profileKey) continue;
    if (slugs.has(e.slug)) continue;
    // Only re-adopt if its group still exists; otherwise the slug is genuinely gone.
    if (!liveGroups.has(e.groupId)) { log(`dropped '${e.slug}' (group gone)`); continue; }
    const used = new Set([...slugs.values()].map(s => s.port));
    const s = { ...e, port: used.has(e.port) ? allocPort() : e.port,
      clients: new Set(), sessions: new Map(), known: new Set(),
      lastInteraction: Date.now(), hadTabs: false };
    slugs.set(e.slug, s);
    startSlugServer(s);
    log(`re-adopted '${e.slug}' on ${s.port} (group ${s.groupId})`);
  }
  saveRegistry();
}

// Group title carries live state; no page can overwrite it.
setInterval(async () => {
  for (const s of slugs.values()) {
    const age = Math.round((Date.now() - s.lastInteraction) / 1000);
    const txt = age < 60 ? `${age}s` : age < 600 ? `${Math.floor(age/60)}m ${age%60}s` : 'over 10m';
    if (txt === s.lastTitle) continue;
    s.lastTitle = txt;
    await callExt(s.profileKey, { type: 'updateGroup', groupId: s.groupId, title: `🤖 ${s.slug} · ${txt}` });
  }
}, 3000);

// ----------------------------------------------------------------- CLI socket

const cli = {
  ping: () => ({ ok: true, profiles: [...profiles.keys()], slugs: [...slugs.keys()], staleClients: staleSockets.size }),

  profiles: () => [...profiles.entries()].map(([k, p]) => ({
    key: k, email: p.email, profileId: p.profileId, profileDir: p.profileDir,
    build: p.build, tabs: p.tabs.length })),

  'start-session': async (a) => {
    if (slugs.has(a.slug)) throw new Error(`slug '${a.slug}' already exists`);

    // Resolve by profile DIRECTORY. If that profile has no connection, it's cold: launch a
    // window in it, which starts its extension, then continue.
    let profileKey = [...profiles.entries()].find(([, p]) => p.profileDir === a.profileDir)?.[0];
    let warmedSeed = null;
    if (!profileKey) {
      const r = await identifyProfile(a.profileDir);
      profileKey = r.key;
      warmedSeed = r.seedTabId;   // the sentinel tab we just launched — use it as the group seed
    }

    const color = GROUP_COLORS[slugs.size % GROUP_COLORS.length];
    let groupId = null, windowId = null;

    let seedTabId = null;
    if (warmedSeed) {
      // The launch opened a window on our sentinel tab. Group THAT tab (found by token, so it's
      // unambiguously ours even if the profile had other tabs) rather than stranding it.
      const seed = (profiles.get(profileKey).tabs || []).find(t => String(t.tabId) === String(warmedSeed));
      if (!seed) throw new Error(`profile '${a.profileDir}' sentinel tab vanished before grouping`);
      seedTabId = Number(seed.tabId);
      windowId = seed.windowId;
    } else if (a.inLastWindow) {
      // Place the group in whatever window was last focused in this profile.
      const w = await callExt(profileKey, { type: 'lastFocusedWindow' });
      if (w.error) throw new Error(w.error);
      windowId = w.result.windowId;
    } else {
      const w = await callExt(profileKey, { type: 'createWindow', url: a.url || 'about:blank' });
      if (w.error) throw new Error(w.error);
      windowId = w.result.windowId;
      // Group the window's OWN tab. Creating a second tab instead leaves this one ungrouped,
      // so ending the slug left an empty window behind every time.
      seedTabId = w.result.tabId || null;
    }
    const g = await callExt(profileKey, { type: 'createGroup',
      windowId, tabId: seedTabId, title: `🤖 ${a.slug} · new`, color, url: a.url || 'about:blank' });
    if (g.error) throw new Error(g.error);
    groupId = g.result.groupId; windowId = g.result.windowId;

    const s = { slug: a.slug, profileKey, groupId, windowId,
      port: allocPort(), clients: new Set(), sessions: new Map(), known: new Set(),
      color, lastInteraction: Date.now(), hadTabs: false,
      allowDestructive: !!a.allowDestructive };
    slugs.set(a.slug, s);
    startSlugServer(s);
    saveRegistry();
    log(`slug '${a.slug}' on ${s.port} (group ${s.groupId}, profile ${profileKey})`);
    return { slug: a.slug, port: s.port, groupId: s.groupId, windowId: s.windowId, color };
  },

  list: () => [...slugs.values()].map(s => ({
    slug: s.slug, profileKey: s.profileKey,
    profileDir: (profiles.get(s.profileKey) || {}).profileDir || null,
    port: s.port, groupId: s.groupId,
    tabs: tabsInGroup(s).length, lastInteractionS: Math.round((Date.now() - s.lastInteraction)/1000) })),

  adopt: async (a) => {
    const s = slugs.get(a.slug);
    if (!s) throw new Error(`no live slug '${a.slug}'`);
    const r = await callExt(s.profileKey, { type: 'adoptTab', groupId: s.groupId, tabId: a.tabId });
    if (r.error) throw new Error(r.error);
    return { adopted: a.tabId };
  },

  // Orphans: the slug registry lives in memory. If a shim restart ever fails to re-adopt a
  // slug (its registry entry lost), Chrome keeps the group but nothing tracks it. Every group
  // this tool made is titled "🤖 …", so find them across ALL connected profiles.
  orphans: async () => {
    if (!profiles.size) throw new Error('no profile connected');
    const live = new Set([...slugs.values()].map(s => s.groupId));
    const orphans = [];
    let tracked = 0;
    for (const key of profiles.keys()) {
      const r = await callExt(key, { type: 'listGroups' });
      if (r.error) continue;
      for (const g of (r.result.groups || [])) {
        if (!g.title.startsWith('🤖')) continue;
        if (live.has(g.groupId)) tracked++;
        else orphans.push({ ...g, profileKey: key });
      }
    }
    return { orphans, tracked };
  },

  cleanup: async () => {
    if (!profiles.size) throw new Error('no profile connected');
    const live = new Set([...slugs.values()].map(s => s.groupId));
    const closed = [];
    for (const key of profiles.keys()) {
      const r = await callExt(key, { type: 'listGroups' });
      if (r.error) continue;
      for (const g of (r.result.groups || [])) {
        if (!g.title.startsWith('🤖') || live.has(g.groupId)) continue;
        await callExt(key, { type: 'endGroup', groupId: g.groupId, close: true });
        closed.push(g.title);
      }
    }
    return { closed: closed.length, groups: closed };
  },

  'bring-to-front': async (a) => {
    const s = slugs.get(a.slug);
    if (!s) throw new Error(`no live slug '${a.slug}'`);
    // Prefer the tab the agent last touched; otherwise the group's first tab.
    const inGroup = tabsInGroup(s);
    const target = (s.lastTabId && inGroup.find(t => String(t.tabId) === String(s.lastTabId)))
      || inGroup[0];
    if (!target) throw new Error(`slug '${a.slug}' has no tabs to focus`);
    // Resolve the window LIVE from the tab: dragging the group into another window changes
    // its windowId, and the cached s.windowId would raise the wrong (or a closed) window.
    const r = await callExt(s.profileKey, { type: 'focusWindow', windowId: target.windowId, tabId: target.tabId });
    if (r.error) throw new Error(r.error);
    return { slug: a.slug, alreadyFocused: r.result.alreadyFocused,
             tabId: target.tabId, url: target.url, title: target.title };
  },

  end: async (a) => {
    const s = slugs.get(a.slug);
    if (!s) throw new Error(`no live slug '${a.slug}'`);
    await callExt(s.profileKey, { type: 'endGroup', groupId: s.groupId, close: !a.keep });
    destroySlug(a.slug);
    return { ended: a.slug };
  },
};

try { fs.unlinkSync(SOCK); } catch {}
net.createServer((conn) => {
  let buf = '';
  conn.on('data', async (d) => {
    buf += d.toString();
    if (!buf.includes('\n')) return;
    let req; try { req = JSON.parse(buf.trim()); } catch { conn.end('{"ok":false,"error":"malformed request"}'); return; }
    try {
      const fn = cli[req.cmd];
      if (!fn) throw new Error(`unknown command '${req.cmd}'`);
      conn.end(JSON.stringify({ ok: true, result: await fn(req) }));
    } catch (e) {
      conn.end(JSON.stringify({ ok: false, error: String(e && e.message || e) }));
    }
  });
}).listen(SOCK, () => log('cli socket', SOCK));

log(`shim up: extensions on ${EXT_PORT}, slug ports ${PORT_MIN}-${PORT_MAX}`);
