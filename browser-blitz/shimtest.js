// shimtest.js — verify the shim's slug logic against a MOCK extension, so the parts that
// don't need Chrome (scoping, lifecycle mirroring, port allocation, CLI) can be proven now.
const net = require('net');
const os = require('os');
const path = require('path');
const WebSocket = require('ws');

const SOCK = path.join(os.homedir(), '.local/state/use-my-chrome/shim.sock');
const KEY = 'mock@test';
let pass = 0, fail = 0;

const ok = (n) => { console.log(`  \x1b[32mPASS\x1b[0m  ${n}`); pass++; };
const no = (n, d) => { console.log(`  \x1b[31mFAIL\x1b[0m  ${n}${d ? '  ' + d : ''}`); fail++; };
const sleep = (ms) => new Promise(r => setTimeout(r, ms));

function cli(req) {
  return new Promise((resolve) => {
    const c = net.createConnection(SOCK);
    let buf = '';
    c.on('connect', () => c.write(JSON.stringify(req) + '\n'));
    c.on('data', d => buf += d);
    c.on('end', () => { try { resolve(JSON.parse(buf)); } catch { resolve({ ok: false, error: buf }); } });
    c.on('error', e => resolve({ ok: false, error: String(e) }));
  });
}

// ---- mock extension -------------------------------------------------------
let nextTab = 1000, nextGroup = 500, nextWin = 900;
const tabs = [];   // {tabId,url,title,groupId,windowId}
let ws;

function pushTabs() {
  ws.send(JSON.stringify({ type: 'tabs', tabs: tabs.map(t => ({ ...t })) }));
}

function startMock() {
  return new Promise((resolve) => {
    ws = new WebSocket('ws://127.0.0.1:9334');
    ws.on('open', () => {
      ws.send(JSON.stringify({ type: 'hello', profile: { email: KEY, profileId: 'mock' } }));
      setTimeout(resolve, 200);
    });
    ws.on('message', (buf) => {
      const m = JSON.parse(buf.toString());
      const res = (result) => ws.send(JSON.stringify({ type: 'res', id: m.id, result }));
      switch (m.type) {
        case 'ping': return ws.send(JSON.stringify({ type: 'pong' }));
        case 'listTabs': return res({ tabs });
        case 'createWindow': {
          const windowId = nextWin++;
          return res({ windowId });
        }
        case 'createGroup': {
          const groupId = nextGroup++;
          const t = { tabId: String(nextTab++), url: m.url || 'about:blank', title: 'mock',
                      groupId, windowId: m.windowId || nextWin++ };
          tabs.push(t); pushTabs();
          return res({ groupId, windowId: t.windowId, tabId: t.tabId });
        }
        case 'createTabInGroup': {
          const g = tabs.find(t => t.groupId === m.groupId);
          const t = { tabId: String(nextTab++), url: m.url || 'about:blank', title: 'mock2',
                      groupId: m.groupId, windowId: g ? g.windowId : nextWin };
          tabs.push(t); pushTabs();
          return res({ tabId: t.tabId });
        }
        case 'adoptTab': {
          const t = tabs.find(x => x.tabId === String(m.tabId));
          if (t) { t.groupId = m.groupId; pushTabs(); }
          return res({});
        }
        case 'closeTab': {
          const i = tabs.findIndex(x => x.tabId === String(m.tabId));
          if (i >= 0) { tabs.splice(i, 1); pushTabs(); }
          return res({});
        }
        case 'endGroup': {
          for (let i = tabs.length - 1; i >= 0; i--) if (tabs[i].groupId === m.groupId) tabs.splice(i, 1);
          pushTabs(); return res({});
        }
        case 'updateGroup': case 'activateTab': return res({});
        case 'cdp': return res({ mocked: m.method });
        default: return res({});
      }
    });
  });
}

// ---- CDP client for assertions --------------------------------------------
function cdpClient(port) {
  return new Promise((resolve) => {
    const c = new WebSocket(`ws://127.0.0.1:${port}/devtools/browser/x`);
    const waiters = new Map(); const events = [];
    let id = 1;
    c.on('message', (buf) => {
      const m = JSON.parse(buf.toString());
      if (m.id && waiters.has(m.id)) { waiters.get(m.id)(m); waiters.delete(m.id); }
      else if (m.method) events.push(m);
    });
    c.on('open', () => resolve({
      send: (method, params = {}, sessionId) => new Promise(r => {
        const i = id++; waiters.set(i, r);
        c.send(JSON.stringify({ id: i, method, params, ...(sessionId ? { sessionId } : {}) }));
      }),
      events, close: () => c.close(),
    }));
  });
}

// ---- tests ----------------------------------------------------------------
(async () => {
  console.log('shim slug-layer tests (mock extension)\n');
  await startMock();

  const p = await cli({ cmd: 'profiles' });
  p.ok && p.result.some(x => x.key === KEY) ? ok('mock profile registers') : no('mock profile registers', JSON.stringify(p));

  await cli({ cmd: 'end', slug: 'mocktest' });
  const s = await cli({ cmd: 'start-session', slug: 'mocktest', profileKey: KEY, newWindow: true });
  if (!s.ok) return no('start-session', s.error), process.exit(1);
  ok(`start-session (port ${s.result.port}, group ${s.result.groupId})`);
  const { port, groupId } = s.result;

  s.result.port >= 9340 && s.result.port <= 9399 ? ok('port in range') : no('port in range');

  await sleep(300);
  const c = await cdpClient(port);

  const ver = await c.send('Browser.getVersion');
  ver.result && /Chrome/.test(ver.result.product) ? ok('Browser.getVersion') : no('Browser.getVersion');

  const t1 = await c.send('Target.getTargets');
  t1.result.targetInfos.length === 1 ? ok('getTargets shows only group tab') : no('getTargets scoping', JSON.stringify(t1.result));

  // A tab OUTSIDE the group must be invisible — this is the safety property.
  tabs.push({ tabId: '7777', url: 'https://bank.example', title: 'bank', groupId: -1, windowId: 999 });
  pushTabs(); await sleep(300);
  const t2 = await c.send('Target.getTargets');
  t2.result.targetInfos.some(x => x.targetId === '7777')
    ? no('ungrouped tab must be invisible') : ok('ungrouped tab invisible (fence holds)');

  // Drag it in -> targetCreated
  await cli({ cmd: 'adopt', slug: 'mocktest', tabId: '7777' });
  await sleep(400);
  c.events.some(e => e.method === 'Target.targetCreated' && e.params.targetInfo.targetId === '7777')
    ? ok('drag in → targetCreated') : no('drag in → targetCreated');

  // Drag it out -> targetDestroyed
  const bank = tabs.find(t => t.tabId === '7777'); bank.groupId = -1; pushTabs();
  await sleep(400);
  c.events.some(e => e.method === 'Target.targetDestroyed' && e.params.targetId === '7777')
    ? ok('drag out → targetDestroyed') : no('drag out → targetDestroyed');

  // attach + passthrough
  const att = await c.send('Target.attachToTarget', { targetId: t1.result.targetInfos[0].targetId, flatten: true });
  att.result && att.result.sessionId ? ok('attachToTarget') : no('attachToTarget');
  const ev = await c.send('Runtime.evaluate', { expression: '1' }, att.result.sessionId);
  ev.result && ev.result.mocked === 'Runtime.evaluate' ? ok('session cmd forwarded to extension') : no('passthrough', JSON.stringify(ev));

  // createTarget lands in the group
  const ct = await c.send('Target.createTarget', { url: 'https://x.test' });
  await sleep(300);
  const t3 = await c.send('Target.getTargets');
  t3.result.targetInfos.some(x => x.targetId === String(ct.result.targetId))
    ? ok('createTarget joins group') : no('createTarget joins group');

  const l = await cli({ cmd: 'list' });
  l.ok && l.result[0] && l.result[0].slug === 'mocktest' ? ok('list') : no('list');

  const dup = await cli({ cmd: 'start-session', slug: 'mocktest', profileKey: KEY });
  !dup.ok && /already exists/.test(dup.error) ? ok('duplicate slug rejected') : no('duplicate slug rejected');

  const bad = await cli({ cmd: 'adopt', slug: 'nope', tabId: '1' });
  !bad.ok && /no live slug/.test(bad.error) ? ok('unknown slug errors clearly') : no('unknown slug errors');

  const e = await cli({ cmd: 'end', slug: 'mocktest' });
  e.ok ? ok('end') : no('end', e.error);
  const l2 = await cli({ cmd: 'list' });
  l2.result.length === 0 ? ok('slug removed after end') : no('slug removed after end');

  c.close(); ws.close();
  console.log(`\nPASS=${pass} FAIL=${fail}`);
  process.exit(fail ? 1 : 0);
})();
