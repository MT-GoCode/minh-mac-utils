// latency.js — REAL end-to-end CDP latency: client → shim → extension → chrome.debugger → Chrome.
// Compare against bench.js (shim-only, ~0.1ms) to see what chrome.debugger actually costs.
const WebSocket = require('ws');
const PORT = Number(process.argv[2] || 9340);
const pct = (a, p) => a.slice().sort((x, y) => x - y)[Math.floor(a.length * p)];

(async () => {
  const c = new WebSocket(`ws://127.0.0.1:${PORT}/devtools/browser/x`);
  const waiters = new Map(); let id = 1;
  c.on('message', b => { const m = JSON.parse(b.toString()); if (m.id && waiters.has(m.id)) { waiters.get(m.id)(m); waiters.delete(m.id); } });
  await new Promise(r => c.on('open', r));
  const send = (method, params = {}, sessionId) => new Promise(r => {
    const i = id++; waiters.set(i, r);
    c.send(JSON.stringify({ id: i, method, params, ...(sessionId ? { sessionId } : {}) }));
  });

  const t = await send('Target.getTargets');
  const target = t.result.targetInfos[0];
  if (!target) { console.log('no targets'); process.exit(1); }
  const att = await send('Target.attachToTarget', { targetId: target.targetId, flatten: true });
  const sid = att.result.sessionId;
  await send('Runtime.enable', {}, sid);

  const warm = 20, N = 200;
  for (let i = 0; i < warm; i++) await send('Runtime.evaluate', { expression: '1', returnByValue: true }, sid);

  const evalLat = [], domLat = [], browserLat = [];
  for (let i = 0; i < N; i++) {
    let a = process.hrtime.bigint();
    await send('Runtime.evaluate', { expression: '1+1', returnByValue: true }, sid);
    evalLat.push(Number(process.hrtime.bigint() - a) / 1e6);
  }
  for (let i = 0; i < N; i++) {
    let a = process.hrtime.bigint();
    await send('Runtime.evaluate', { expression: 'document.querySelectorAll("*").length', returnByValue: true }, sid);
    domLat.push(Number(process.hrtime.bigint() - a) / 1e6);
  }
  for (let i = 0; i < N; i++) {
    let a = process.hrtime.bigint();
    await send('Target.getTargets');
    browserLat.push(Number(process.hrtime.bigint() - a) / 1e6);
  }

  const row = (n, a) => console.log(`  ${n.padEnd(38)} p50 ${pct(a,.5).toFixed(2)}ms  p95 ${pct(a,.95).toFixed(2)}ms`);
  console.log('REAL end-to-end (through chrome.debugger into Chrome):\n');
  row('Runtime.evaluate (trivial)', evalLat);
  row('Runtime.evaluate (DOM query)', domLat);
  row('Target.getTargets (shim-only, no Chrome)', browserLat);
  console.log('\n  reference: AppleScript execute-javascript was ~111ms/call');
  c.close(); process.exit(0);
})();
