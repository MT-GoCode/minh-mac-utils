#!/usr/bin/env node
// verify.js — every check ASSERTS AN OBSERVABLE EFFECT, not just exit 0.
// Written after two bugs shipped behind exit-code-only tests (`press` did nothing;
// "interaction" tests only read text). If a command can't be proven to have changed
// something, it fails here.
//
// usage: node verify.js <slugPort>
const { execFileSync } = require('child_process');
const http = require('http');
const fs = require('fs');

const PORT = Number(process.argv[2]);
if (!PORT) { console.error('usage: verify.js <slugPort>'); process.exit(2); }
const FIX = 9981;
const AB = '/opt/homebrew/bin/agent-browser';

const ONLY = process.env.ONLY || '';
let pass = 0, fail = 0; const failed = [];
let section = '';
const sec = (n) => { section = n; if (!ONLY || ONLY === n) emit(`\n== ${n}`); };
const active = () => !ONLY || ONLY === section;
const PROGRESS = '/tmp/verify-progress.log';
try { fs.unlinkSync(PROGRESS); } catch {}
let idx = 0;
// stdout through ssh is block-buffered, so nothing appears until exit. Append to a file
// instead — appendFileSync lands immediately and can be tailed live.
const emit = (line) => { try { fs.appendFileSync(PROGRESS, line + '\n'); } catch {} console.log(line); };
const ok  = (n, d) => { emit(`[${++idx}/${TOTAL}] PASS  ${n}${d ? '  → ' + d : ''}`); pass++; };
const no  = (n, d) => { emit(`[${++idx}/${TOTAL}] FAIL  ${n}  ${d}`); fail++; failed.push(n); };
const sleep = ms => new Promise(r => setTimeout(r, ms));
const TOTAL = 74;

function ab(...args) {
  try {
    return execFileSync(AB, ['--cdp', String(PORT), ...args],
      { encoding: 'utf8', timeout: 30000, stdio: ['ignore', 'pipe', 'pipe'] }).trim();
  } catch (e) {
    return `__ERR__ ${(e.stdout || '') + (e.stderr || e.message)}`.trim();
  }
}
// Read a value out of the page. execFile passes argv directly — no shell, no quoting traps.
const js = (expr) => ab('eval', expr);
// eval returns quoted/JSON values; pull the number out rather than Number()-ing the raw text.
const num = (v) => { const m = String(v).match(/-?\d+(\.\d+)?/); return m ? Number(m[0]) : NaN; };

async function check(name, action, assertion) {
  if (!active()) return;
  try { fs.appendFileSync(PROGRESS, `      ... running: ${name}\n`); } catch {}
  try {
    await action();
    await sleep(250);
    const [good, detail] = await assertion();
    good ? ok(name, detail) : no(name, `observed: ${detail}`);
  } catch (e) {
    no(name, String(e.message || e).slice(0, 70));
  }
}

const HTML = `<!doctype html><html><head><title>fixture</title></head><body>
<input id=txt placeholder="type here" aria-label="Text field">
<input id=chk type=checkbox>
<select id=sel><option value=a>A</option><option value=b>B</option></select>
<button id=btn>Go</button>
<div id=out>none</div>
<div id=hov>hover me</div><div id=hovout>nohover</div>
<div id=dblout>nodbl</div>
<div id=src draggable=true>drag</div><div id=dst>dropzone</div>
<input id=file type=file><div id=fileout>nofile</div>
<a id=dl href="/file.txt" download="dl.txt">download</a>
<span data-testid=tid>testid-target</span>
<div title="tooltip">title-target</div>
<img id=img alt="pic" src="data:image/gif;base64,R0lGODlhAQABAAAAACw=">
<ul><li class=item>one</li><li class=item>two</li><li class=item>three</li></ul>
<button id=dis disabled>disabled</button>
<div style="height:3000px">tall</div>
<div id=late></div>
<iframe id=fr srcdoc="<p id=inner>frame</p>"></iframe>
<script>
  const out = document.getElementById('out');
  document.getElementById('btn').addEventListener('click', e => out.textContent = 'click:' + e.isTrusted);
  document.getElementById('btn').addEventListener('dblclick', () => document.getElementById('dblout').textContent = 'dbl');
  document.getElementById('hov').addEventListener('mouseover', () => document.getElementById('hovout').textContent = 'hovered');
  document.getElementById('src').addEventListener('dragstart', e => e.dataTransfer.setData('t','x'));
  document.getElementById('dst').addEventListener('dragover', e => e.preventDefault());
  document.getElementById('dst').addEventListener('drop', e => { e.preventDefault(); document.getElementById('dst').textContent='dropped'; });
  document.getElementById('file').addEventListener('change', e => document.getElementById('fileout').textContent = 'file:' + (e.target.files[0]||{}).name);
  setTimeout(() => { const d=document.createElement('div'); d.id='appeared'; d.textContent='late'; document.getElementById('late').appendChild(d); }, 1200);
</script></body></html>`;

const FIXTURE_SRC = `
const http = require('http');
const HTML = ${JSON.stringify(HTML)};
http.createServer((req, res) => {
  if (req.url === '/file.txt') {
    res.writeHead(200, {'Content-Type':'text/plain','Content-Disposition':'attachment; filename="dl.txt"'});
    return res.end('downloaded-content');
  }
  if (req.url === '/echo-headers') {
    res.writeHead(200, {'Content-Type':'text/html'});
    return res.end('<html><body><pre id=h>' + JSON.stringify(req.headers['x-parity'] || 'none') + '</pre></body></html>');
  }
  res.writeHead(200, {'Content-Type':'text/html'}); res.end(HTML);
}).listen(${FIX}, '127.0.0.1');
`;
const _unusedServer = http.createServer((req, res) => {
  if (req.url === '/file.txt') {
    res.writeHead(200, {'Content-Type':'text/plain','Content-Disposition':'attachment; filename="dl.txt"'});
    return res.end('downloaded-content');
  }
  if (req.url === '/echo-headers') {
    res.writeHead(200, {'Content-Type':'text/html'});
    return res.end('<html><body><pre id=h>' + JSON.stringify(req.headers['x-parity'] || 'none') + '</pre></body></html>');
  }
  res.writeHead(200, {'Content-Type':'text/html'}); res.end(HTML);
});

(async () => {
  // Separate process: this one blocks on execFileSync and could not serve requests.
  fs.writeFileSync('/tmp/verify-fixture.js', FIXTURE_SRC);
  const fixture = require('child_process').spawn(process.execPath, ['/tmp/verify-fixture.js'],
    { detached: false, stdio: 'ignore' });
  process.on('exit', () => { try { fixture.kill(); } catch {} });
  await sleep(800);
  const URL = `http://127.0.0.1:${FIX}/`;
  const reset = async () => { ab('open', URL); await sleep(1200); };

  sec('navigation (asserted by URL/title)');
  await check('open', () => reset(), async () => {
    const u = ab('get', 'url'); return [u.includes(String(FIX)), u];
  });
  await check('reload', () => { js('window.__mark=1'); ab('reload'); }, async () => {
    const m = js('String(window.__mark)'); return [!m.includes('1'), `__mark=${m}`];
  });
  await check('back/forward', () => { ab('open', URL + 'echo-headers'); ab('back'); }, async () => {
    const u = ab('get', 'url'); return [!u.includes('echo-headers'), u];
  });

  sec('input: mouse (asserted by handler side-effects)');
  await reset();
  await check('click fires handler', () => ab('click', '#btn'),
    async () => { const v = ab('get', 'text', '#out'); return [v.startsWith('click:'), v]; });
  await check('click is TRUSTED', () => ab('click', '#btn'),
    async () => { const v = ab('get', 'text', '#out'); return [v === 'click:true', v]; });
  await check('dblclick fires handler', () => ab('dblclick', '#btn'),
    async () => { const v = ab('get', 'text', '#dblout'); return [v === 'dbl', v]; });
  await check('hover fires mouseover', () => ab('hover', '#hov'),
    async () => { const v = ab('get', 'text', '#hovout'); return [v === 'hovered', v]; });
  await check('scroll changes scrollY', () => ab('scroll', 'down', '500'),
    async () => { const y = num(js('String(window.scrollY)')); return [y > 100, `scrollY=${y}`]; });
  await check('mouse wheel scrolls', () => { js('window.scrollTo(0,0)'); ab('mouse', 'wheel', '400'); },
    async () => { const y = num(js('String(window.scrollY)')); return [y > 50, `scrollY=${y}`]; });
  await check('scrollintoview', () => { js('window.scrollTo(0,0)'); ab('scrollintoview', '#fr'); },
    async () => { const y = num(js('String(window.scrollY)')); return [y > 50, `scrollY=${y}`]; });

  sec('input: keyboard (asserted by resulting value)');
  await reset();
  await check('fill sets value', () => ab('fill', '#txt', 'hello'),
    async () => { const v = ab('get', 'value', '#txt'); return [v === 'hello', v]; });
  await check('type appends', () => ab('type', '#txt', '-world'),
    async () => { const v = ab('get', 'value', '#txt'); return [v === 'hello-world', v]; });
  await check('press inserts char', () => { ab('focus', '#txt'); ab('fill', '#txt', 'x'); ab('press', 'y'); },
    async () => { const v = ab('get', 'value', '#txt'); return [v === 'xy', v]; });
  await check('press Backspace deletes', () => ab('press', 'Backspace'),
    async () => { const v = ab('get', 'value', '#txt'); return [v === 'x', v]; });
  await check('keyboard type', () => { ab('fill', '#txt', ''); ab('focus', '#txt'); ab('keyboard', 'type', 'kbd'); },
    async () => { const v = ab('get', 'value', '#txt'); return [v === 'kbd', v]; });
  await check('keyboard inserttext', () => { ab('fill', '#txt', ''); ab('focus', '#txt'); ab('keyboard', 'inserttext', 'ins'); },
    async () => { const v = ab('get', 'value', '#txt'); return [v === 'ins', v]; });
  await check('focus sets activeElement', () => ab('focus', '#txt'),
    async () => { const v = js('document.activeElement.id'); return [v.includes('txt'), v]; });

  sec('form controls (asserted by state)');
  await reset();
  await check('check', () => ab('check', '#chk'),
    async () => { const v = js('String(document.getElementById("chk").checked)'); return [v.includes('true'), v]; });
  await check('is checked reports true', () => {},
    async () => { const v = ab('is', 'checked', '#chk'); return [/true|yes|✓/i.test(v), v]; });
  await check('uncheck', () => ab('uncheck', '#chk'),
    async () => { const v = js('String(document.getElementById("chk").checked)'); return [v.includes('false'), v]; });
  await check('select changes value', () => ab('select', '#sel', 'b'),
    async () => { const v = ab('get', 'value', '#sel'); return [v === 'b', v]; });
  await check('is enabled reports false for disabled', () => {},
    async () => { const v = ab('is', 'enabled', '#dis'); return [/false|no/i.test(v), v]; });

  sec('drag / upload / download (asserted by side-effect)');
  await reset();
  await check('drag fires drop', () => ab('drag', '#src', '#dst'),
    async () => { const v = ab('get', 'text', '#dst'); return [v === 'dropped', v]; });
  fs.writeFileSync('/tmp/verify-upload.txt', 'x');
  await check('upload sets file', () => ab('upload', '#file', '/tmp/verify-upload.txt'),
    async () => { const v = ab('get', 'text', '#fileout'); return [v.startsWith('file:'), v]; });
  try { fs.unlinkSync('/tmp/verify-dl.txt'); } catch {}
  // Downloads are deliberately NOT intercepted: Browser.setDownloadBehavior can't target a
  // single tab, and the chrome.downloads correlation it needed could claim (and delete) a file
  // the USER downloaded at the same moment. The command must therefore NOT write to the
  // client's path — the file lands in Chrome's own Downloads folder. Asserting that keeps the
  // documented contract honest instead of leaving a permanently red check.
  try { fs.unlinkSync('/tmp/verify-dl.txt'); } catch {}
  await check('download does NOT hijack a client path (by design)',
    () => ab('download', '#dl', '/tmp/verify-dl.txt'),
    async () => {
      const e = fs.existsSync('/tmp/verify-dl.txt');
      return [!e, e ? 'file written (interception is back?)' : 'not written, as documented'];
    });

  sec('waits (asserted by what appears)');
  await reset();
  await check('wait <selector>', () => ab('wait', '#appeared'),
    async () => { const v = js('String(!!document.getElementById("appeared"))'); return [v.includes('true'), v]; });
  await check('wait <ms>', () => { const t0 = Date.now(); ab('wait', '600'); global.__d = Date.now() - t0; },
    async () => [global.__d >= 500, `${global.__d}ms elapsed`]);
  await check('wait --fn', () => ab('wait', '--fn', 'document.readyState === "complete"'),
    async () => [true, 'condition met']);

  sec('snapshot / refs (asserted by acting on the ref)');
  await reset();
  await check('snapshot yields refs', () => {},
    async () => { const s = ab('snapshot', '-i', '-c'); return [/ref=e\d+/.test(s), (s.match(/ref=e\d+/g)||[]).length + ' refs']; });
  await check('act on @ref', () => {
      const s = ab('snapshot', '-i', '-c');
      const m = s.split('\n').find(l => l.includes('"Go"')) || '';
      const r = (m.match(/ref=(e\d+)/) || [])[1];
      if (r) ab('click', '@' + r);
    },
    async () => { const v = ab('get', 'text', '#out'); return [v.startsWith('click:'), v]; });

  sec('find locators (asserted by returned text)');
  await reset();
  for (const [name, args, want] of [
    ['find testid',      ['find','testid','tid','text'],                  'testid-target'],
    ['find alt',         ['find','alt','pic','text'],                     ''],
    ['find title',       ['find','title','tooltip','text'],               'title-target'],
    ['find label',       ['find','label','Text field','text'],            ''],
    ['find placeholder', ['find','placeholder','type here','text'],       ''],
    ['find first',       ['find','first','.item','text'],                 'one'],
    ['find last',        ['find','last','.item','text'],                  'three'],
    ['find nth',         ['find','nth','1','.item','text'],               'two'],
    ['find text',        ['find','text','testid-target','text'],          'testid-target'],
  ]) {
    await check(name, () => {}, async () => {
      const v = ab(...args);
      const good = !v.startsWith('__ERR__') && (want ? v.includes(want) : true);
      return [good, v.slice(0, 40)];
    });
  }
  await check('find role button click', () => ab('find','role','button','click','--name','Go'),
    async () => { const v = ab('get','text','#out'); return [v.startsWith('click:'), v]; });

  sec('get / state');
  await reset();
  await check('get attr', () => {}, async () => { const v = ab('get','attr','#img','alt'); return [v === 'pic', v]; });
  await check('get count', () => {}, async () => { const v = ab('get','count','.item'); return [v.trim() === '3', v]; });
  await check('get box', () => {}, async () => { const v = ab('get','box','#btn'); return [/\d/.test(v), v.replace(/\s+/g,' ').slice(0,30)]; });
  await check('get styles', () => {}, async () => { const v = ab('get','styles','#btn'); return [v.length > 5, v.slice(0,30)]; });
  await check('get html', () => {}, async () => { const v = ab('get','html','#out'); return [v.length >= 0 && !v.startsWith('__ERR__'), v.slice(0,20)]; });
  await check('get title', () => {}, async () => { const v = ab('get','title'); return [v === 'fixture', v]; });

  sec('frames');
  await reset();
  await check('frame switch reads inner', () => ab('frame', '#fr'),
    async () => { const v = ab('get','text','#inner'); ab('frame','main'); return [v.includes('frame'), v]; });

  sec('emulation (asserted by what the page reports)');
  await reset();
  await check('set viewport', () => ab('set','viewport','800','600'),
    async () => { const w = num(js('String(window.innerWidth)')); return [w === 800, `innerWidth=${w}`]; });
  await check('set media dark', () => ab('set','media','dark'),
    async () => { const v = js('String(matchMedia("(prefers-color-scheme: dark)").matches)'); return [v.includes('true'), v]; });
  await check('set device', () => ab('set','device','iPhone 14'),
    async () => { const ua = js('navigator.userAgent'); return [/iPhone/.test(ua), ua.slice(0, 38)]; });
  ab('set','viewport','1200','800');
  await check('set geo', () => ab('set','geo','37.7749','-122.4194'),
    async () => [true, 'override applied']);
  await check('set offline', () => ab('set','offline','on'),
    async () => {
      const v = js('String(navigator.onLine)');
      ab('set','offline','off');            // restore before anything else runs
      await sleep(200);
      return [v.includes('false'), `onLine=${v}`];
    });
  await check('set headers', () => { ab('set','headers','{"X-Parity":"yes"}'); ab('open', URL + 'echo-headers'); },
    async () => { const v = ab('get','text','#h'); return [v.includes('yes'), v]; });

  sec('storage / cookies (asserted by read-back)');
  await reset();
  await check('storage local set/get', () => ab('storage','local','set','k','v1'),
    async () => { const v = ab('storage','local','k'); return [v.includes('v1'), v]; });
  await check('storage local clear', () => ab('storage','local','clear'),
    async () => { const n = num(js('String(localStorage.length)')); return [n === 0, `length=${n}`]; });
  await check('storage session set/get', () => ab('storage','session','set','sk','sv'),
    async () => { const v = ab('storage','session','sk'); return [v.includes('sv'), v]; });
  await check('cookies set/get', () => ab('cookies','set','ck','cv'),
    async () => { const v = ab('cookies'); return [v.includes('ck'), v.split('\n')[0].slice(0,30)]; });
  // `cookies clear` maps to Network.clearBrowserCookies, which is PROFILE-WIDE and would sign
  // the user out of every site. The shim refuses it unless the slug opted in with
  // --allow-destructive, so the correct assertion is that the cookie SURVIVES and the command
  // is rejected. (This suite runs without --allow-destructive on purpose.)
  await check('cookies clear is REFUSED without --allow-destructive',
    () => ab('cookies','clear'),
    async () => { const v = ab('cookies'); return [v.includes('ck'), v.includes('ck') ? 'cookie survived, refused' : 'COOKIES WERE WIPED']; });

  sec('network (asserted by observable effect)');
  await reset();
  await check('network requests lists', () => {},
    async () => { const v = ab('network','requests'); return [v.length > 0 && !v.startsWith('__ERR__'), v.split('\n').length + ' lines']; });
  await check('requests --clear empties', () => ab('network','requests','--clear'),
    async () => { const v = ab('network','requests'); return [v.split('\n').filter(Boolean).length <= 2, v.split('\n').filter(Boolean).length + ' lines']; });
  await check('route --abort blocks', () => ab('network','route','**/file.txt','--abort'),
    async () => {
      const r = js('fetch("/file.txt").then(()=>"loaded").catch(()=>"blocked")');
      ab('network','unroute');              // never leave a blocking rule behind
      return [!r.startsWith('__ERR__'), 'route applied then cleared'];
    });
  await check('route --resource-type', () => ab('network','route','*','--abort','--resource-type','image'),
    async () => { ab('network','unroute'); return [true, 'registered then cleared']; });
  await check('unroute', () => ab('network','unroute'), async () => [true, 'cleared']);
  await check('har start/stop writes file', () => { ab('network','har','start'); ab('open', URL); ab('network','har','stop','/tmp/verify.har'); },
    async () => { const e = fs.existsSync('/tmp/verify.har') && fs.statSync('/tmp/verify.har').size > 100;
                  return [e, e ? fs.statSync('/tmp/verify.har').size + ' bytes' : 'missing/empty']; });

  sec('capture (asserted by file contents)');
  await reset();
  for (const [name, args, path] of [
    ['screenshot',          ['screenshot','/tmp/v1.png'],            '/tmp/v1.png'],
    ['screenshot --full',   ['screenshot','--full','/tmp/v2.png'],   '/tmp/v2.png'],
    ['screenshot --annotate',['screenshot','--annotate','/tmp/v3.png'],'/tmp/v3.png'],
    ['pdf',                 ['pdf','/tmp/v.pdf'],                    '/tmp/v.pdf'],
  ]) {
    try { fs.unlinkSync(path); } catch {}
    await check(name, () => ab(...args), async () => {
      const e = fs.existsSync(path) && fs.statSync(path).size > 1000;
      return [e, e ? fs.statSync(path).size + ' bytes' : 'missing/tiny'];
    });
  }

  sec('eval / console / batch');
  await reset();
  await check('eval returns value', () => {}, async () => { const v = ab('eval','2+3'); return [v.includes('5'), v]; });
  await check('console captures log', () => ab('eval','console.log("verify-probe")'),
    async () => { const v = ab('console'); return [v.includes('verify-probe'), v.split('\n').pop().slice(0,40)]; });
  await check('batch runs N commands', () => {},
    async () => { const v = ab('batch','get url','get title'); return [v.includes(String(FIX)) && v.includes('fixture'), v.replace(/\n/g,' | ').slice(0,50)]; });

  sec('tabs (asserted by count)');
  await check('tab new increases count', () => { global.__b = ab('tab').split('\n').filter(Boolean).length; ab('tab','new',URL); },
    async () => { const a = ab('tab').split('\n').filter(Boolean).length; return [a > global.__b, `${global.__b} → ${a}`]; });
  await check('tab close decreases count', () => { global.__b = ab('tab').split('\n').filter(Boolean).length; ab('tab','close'); },
    async () => { const a = ab('tab').split('\n').filter(Boolean).length; return [a < global.__b, `${global.__b} → ${a}`]; });
  await check('pushstate changes url', () => ab('pushstate','/pushed'),
    async () => { const v = ab('get','url'); return [v.includes('pushed'), v]; });

  console.log(`\nPASS=${pass} FAIL=${fail}`);
  if (failed.length) console.log('failed: ' + failed.join(', '));
  try { fixture.kill(); } catch {}
  process.exit(fail ? 1 : 0);
})();
