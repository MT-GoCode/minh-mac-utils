// isolation.js — multi-slug safety: concurrent agents must not see each other's tabs,
// nor anything ungrouped. Uses a mock extension so it runs without Chrome.
const net = require('net'); const os = require('os'); const path = require('path');
const WebSocket = require('ws');
const SOCK = path.join(os.homedir(), '.local/state/use-my-chrome/shim.sock');
const KEY = 'iso@test';
let pass = 0, fail = 0;
const ok = n => { console.log(`  \x1b[32mPASS\x1b[0m  ${n}`); pass++; };
const no = (n, d) => { console.log(`  \x1b[31mFAIL\x1b[0m  ${n}${d ? '  ' + d : ''}`); fail++; };
const sleep = ms => new Promise(r => setTimeout(r, ms));

const cli = req => new Promise(res => {
  const c = net.createConnection(SOCK); let b = '';
  c.on('connect', () => c.write(JSON.stringify(req) + '\n'));
  c.on('data', d => b += d); c.on('end', () => { try { res(JSON.parse(b)); } catch { res({ ok:false, error:b }); } });
  c.on('error', e => res({ ok:false, error:String(e) }));
});

let nextTab = 3000, nextGroup = 800, nextWin = 400, ws;
const tabs = [];
const push = () => ws.send(JSON.stringify({ type:'tabs', tabs: tabs.map(t => ({...t})) }));

function mock() {
  return new Promise(resolve => {
    ws = new WebSocket('ws://127.0.0.1:9334');
    ws.on('open', () => { ws.send(JSON.stringify({ type:'hello', profile:{ email:KEY, profileId:'iso' }})); setTimeout(resolve, 200); });
    ws.on('message', buf => {
      const m = JSON.parse(buf.toString());
      const res = r => ws.send(JSON.stringify({ type:'res', id:m.id, result:r }));
      switch (m.type) {
        case 'ping': return ws.send(JSON.stringify({ type:'pong' }));
        case 'listTabs': return res({ tabs });
        case 'createWindow': return res({ windowId: nextWin++ });
        case 'createGroup': {
          const g = nextGroup++;
          const t = { tabId:String(nextTab++), url:'about:blank', title:'t', groupId:g, windowId:m.windowId||nextWin++ };
          tabs.push(t); push(); return res({ groupId:g, windowId:t.windowId, tabId:t.tabId });
        }
        case 'createTabInGroup': {
          const g = tabs.find(t => t.groupId === m.groupId);
          const t = { tabId:String(nextTab++), url:m.url||'about:blank', title:'t2', groupId:m.groupId, windowId:g?g.windowId:1 };
          tabs.push(t); push(); return res({ tabId:t.tabId });
        }
        case 'endGroup': {
          for (let i=tabs.length-1;i>=0;i--) if (tabs[i].groupId===m.groupId) tabs.splice(i,1);
          push(); return res({});
        }
        default: return res({});
      }
    });
  });
}

function cdp(port) {
  return new Promise(resolve => {
    const c = new WebSocket(`ws://127.0.0.1:${port}/devtools/browser/x`);
    const w = new Map(); let id = 1;
    c.on('message', b => { const m = JSON.parse(b.toString()); if (m.id && w.has(m.id)) { w.get(m.id)(m); w.delete(m.id); } });
    c.on('open', () => resolve({
      send: (method, params={}) => new Promise(r => { const i=id++; w.set(i,r); c.send(JSON.stringify({id:i,method,params})); }),
      close: () => c.close(),
    }));
  });
}

(async () => {
  console.log('multi-slug isolation (mock extension)\n');
  await mock();
  for (const s of ['isoA','isoB']) await cli({ cmd:'end', slug:s });

  const a = await cli({ cmd:'start-session', slug:'isoA', profileKey:KEY, newWindow:true });
  const b = await cli({ cmd:'start-session', slug:'isoB', profileKey:KEY, newWindow:true });
  if (!a.ok || !b.ok) return no('start two slugs', a.error||b.error), process.exit(1);
  ok(`two slugs (ports ${a.result.port}, ${b.result.port})`);
  a.result.port !== b.result.port ? ok('distinct ports') : no('distinct ports');
  a.result.groupId !== b.result.groupId ? ok('distinct groups') : no('distinct groups');

  await sleep(300);
  const ca = await cdp(a.result.port), cb = await cdp(b.result.port);

  // Give A a second tab; B must not see it.
  await ca.send('Target.createTarget', { url: 'https://a.test' });
  await sleep(300);

  const ta = (await ca.send('Target.getTargets')).result.targetInfos;
  const tb = (await cb.send('Target.getTargets')).result.targetInfos;
  ta.length === 2 ? ok('A sees its own 2 tabs') : no('A tab count', String(ta.length));
  tb.length === 1 ? ok('B sees only its own 1 tab') : no('B tab count', String(tb.length));

  const aIds = new Set(ta.map(t => t.targetId));
  tb.some(t => aIds.has(t.targetId))
    ? no('CROSS-SLUG LEAK: B can see A\'s tab') : ok('no cross-slug leak');

  // An ungrouped "personal" tab must be invisible to both.
  tabs.push({ tabId:'9999', url:'https://bank.test', title:'bank', groupId:-1, windowId:1 });
  push(); await sleep(300);
  const ta2 = (await ca.send('Target.getTargets')).result.targetInfos;
  const tb2 = (await cb.send('Target.getTargets')).result.targetInfos;
  (!ta2.some(t=>t.targetId==='9999') && !tb2.some(t=>t.targetId==='9999'))
    ? ok('ungrouped tab invisible to both') : no('ungrouped tab leaked');

  // Ending A must not disturb B.
  const pa = a.result.port;
  await cli({ cmd:'end', slug:'isoA' });
  await sleep(300);
  const l = await cli({ cmd:'list' });
  l.result.length === 1 && l.result[0].slug === 'isoB' ? ok('ending A leaves B intact') : no('ending A disturbed B');

  const tb3 = (await cb.send('Target.getTargets')).result.targetInfos;
  tb3.length === 1 ? ok('B still functional after A ended') : no('B broken after A ended');

  // Port must be reusable once released.
  const c2 = await cli({ cmd:'start-session', slug:'isoA', profileKey:KEY, newWindow:true });
  c2.ok ? ok(`port reallocated (${c2.result.port})`) : no('port reuse', c2.error);

  for (const s of ['isoA','isoB']) await cli({ cmd:'end', slug:s });
  ca.close(); cb.close(); ws.close();
  console.log(`\nPASS=${pass} FAIL=${fail}`);
  process.exit(fail ? 1 : 0);
})();
