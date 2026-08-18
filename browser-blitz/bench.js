// bench.js — isolate the shim's own overhead using a mock extension that replies instantly.
// Whatever this measures is pure shim cost; the real path adds chrome.debugger + Chrome.
const net = require('net'); const os = require('os'); const path = require('path');
const WebSocket = require('ws');
const SOCK = path.join(os.homedir(), '.local/state/use-my-chrome/shim.sock');
const KEY = 'bench@test';

const cli = (req) => new Promise((res) => {
  const c = net.createConnection(SOCK); let b = '';
  c.on('connect', () => c.write(JSON.stringify(req) + '\n'));
  c.on('data', d => b += d); c.on('end', () => res(JSON.parse(b)));
  c.on('error', e => res({ ok: false, error: String(e) }));
});
const sleep = ms => new Promise(r => setTimeout(r, ms));
const pct = (a, p) => a.slice().sort((x, y) => x - y)[Math.floor(a.length * p)];

let nextTab = 2000, nextGroup = 700, ws;
const tabs = [];
function mock() {
  return new Promise((resolve) => {
    ws = new WebSocket('ws://127.0.0.1:9334');
    ws.on('open', () => { ws.send(JSON.stringify({ type:'hello', profile:{ email:KEY, profileId:'b' }})); setTimeout(resolve, 200); });
    ws.on('message', (buf) => {
      const m = JSON.parse(buf.toString());
      const res = (r) => ws.send(JSON.stringify({ type:'res', id:m.id, result:r }));
      if (m.type === 'ping') return ws.send(JSON.stringify({ type:'pong' }));
      if (m.type === 'createWindow') return res({ windowId: 1 });
      if (m.type === 'createGroup') {
        const g = nextGroup++, t = { tabId:String(nextTab++), url:'about:blank', title:'b', groupId:g, windowId:1 };
        tabs.push(t); ws.send(JSON.stringify({ type:'tabs', tabs })); return res({ groupId:g, windowId:1, tabId:t.tabId });
      }
      if (m.type === 'listTabs') return res({ tabs });
      if (m.type === 'cdp') return res({ value: 1 });      // instant reply = zero Chrome cost
      return res({});
    });
  });
}

(async () => {
  await mock();
  await cli({ cmd:'end', slug:'bench' });
  const s = await cli({ cmd:'start-session', slug:'bench', profileKey:KEY, newWindow:true });
  const port = s.result.port;
  await sleep(300);

  const c = new WebSocket(`ws://127.0.0.1:${port}/devtools/browser/x`);
  const waiters = new Map(); let id = 1;
  c.on('message', b => { const m = JSON.parse(b.toString()); if (m.id && waiters.has(m.id)) { waiters.get(m.id)(m); waiters.delete(m.id); } });
  await new Promise(r => c.on('open', r));
  const send = (method, params={}, sessionId) => new Promise(r => {
    const i = id++; waiters.set(i, r); c.send(JSON.stringify({ id:i, method, params, ...(sessionId?{sessionId}:{}) }));
  });

  const t = await send('Target.getTargets');
  const att = await send('Target.attachToTarget', { targetId: t.result.targetInfos[0].targetId, flatten:true });
  const sid = att.result.sessionId;

  const N = 300;
  const browserLat = [], sessionLat = [];
  for (let i = 0; i < N; i++) { const a = process.hrtime.bigint(); await send('Target.getTargets'); browserLat.push(Number(process.hrtime.bigint()-a)/1e6); }
  for (let i = 0; i < N; i++) { const a = process.hrtime.bigint(); await send('Runtime.evaluate', { expression:'1' }, sid); sessionLat.push(Number(process.hrtime.bigint()-a)/1e6); }

  const cliLat = [];
  for (let i = 0; i < 50; i++) { const a = process.hrtime.bigint(); await cli({ cmd:'list' }); cliLat.push(Number(process.hrtime.bigint()-a)/1e6); }

  const row = (n, a) => console.log(`  ${n.padEnd(34)} p50 ${pct(a,.5).toFixed(2)}ms   p95 ${pct(a,.95).toFixed(2)}ms`);
  console.log('shim overhead (mock replies instantly — excludes Chrome):\n');
  row('browser-level (emulated in shim)', browserLat);
  row('session-level (shim→ext→shim)', sessionLat);
  row('CLI unix socket round trip', cliLat);

  await cli({ cmd:'end', slug:'bench' });
  c.close(); ws.close(); process.exit(0);
})();
