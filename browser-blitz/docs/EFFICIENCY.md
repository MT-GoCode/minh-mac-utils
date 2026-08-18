# Token-efficient operation (measured)

Numbers measured 2026-08-18 on a REAL heavy page (Kayak flight results) through the bridge,
and cross-checked against agent-browser v0.34.0 source (a11y-tree snapshot in Rust). Text
tokens ≈ bytes/4. Image tokens are priced by PIXELS (≈ w×h/750), NOT file bytes — so a huge
PNG is cheap in tokens but slow to ship; shrinking the VIEWPORT cuts tokens, JPEG/quality cuts
transfer bytes.

## What things actually cost

| Observation | Size | ~Tokens |
|---|---|---|
| `eval` targeted extraction (prices only)     | 102 B   | **25** |
| `get text <scoped-selector>`                 | 278 B   | **69** |
| `snapshot -i -s <container>` (scoped, w/refs)| 4.2 KB  | **1,050** |
| `console`                                    | 2.8 KB  | 700 |
| `get text body`                              | 22 KB   | 5,600 |
| `read` (rendered DOM → text)                 | 29 KB   | 7,200 |
| `snapshot -i` (whole page)                   | 103 KB  | **25,800** |
| `snapshot` (full tree)                       | 212 KB  | **52,900** |
| `network requests` (raw dump)                | 331 KB  | **82,800** |

Same information need spans **25 → 82,800 tokens** depending on the primitive. The ladder is
worth 3+ orders of magnitude.

Latency (Rust CLI, bridge 0.5ms/call): 1 call = 11ms, 4 calls = 33ms, `batch` of 4 = 13ms.
CLI spawn is NOT the bottleneck. **Agent turns are** (~seconds each). Optimize fewest turns
first, fewest tokens second, wall-clock last.

## Screenshots — measured JPEG/quality recipe

Vision cost is pixel-driven, so viewport size sets the token cost; JPEG+quality sets the
transfer bytes (matters over SSH). agent-browser exposes format/quality ONLY via env vars —
the file extension does NOT switch format (a `.jpg` name still wrote PNG).

| Recipe | File size |
|---|---|
| PNG, 1440 viewport (default)                              | 482 KB |
| JPEG q80 (`AGENT_BROWSER_SCREENSHOT_FORMAT=jpeg`)         | 282 KB |
| JPEG q40 (`+ AGENT_BROWSER_SCREENSHOT_QUALITY=40`)        | 173 KB |
| **JPEG q40 + `set viewport 800 600`**                    | **27 KB** |
| `screenshot --full` (whole scroll height)                | 13.8 MB — never |

Failure/verification screenshot recipe (94% smaller than default):
```bash
agent-browser --cdp $P set viewport 800 600
AGENT_BROWSER_SCREENSHOT_FORMAT=jpeg AGENT_BROWSER_SCREENSHOT_QUALITY=40 \
  agent-browser --cdp $P screenshot /tmp/fail.jpg
```
There is NO downscaling flag (`scale:1.0` is hardcoded) — shrink the viewport, don't expect a
`--scale`. `--annotate` and even a plain `snapshot` WRITE TO THE LIVE PAGE DOM (annotate injects
a red-box overlay div; snapshot tags cursor-interactive elements with `[data-__ab-ci]`). Cosmetic
and reverted, but it's the user's real browser — expect a brief visual flash on `--annotate`.

## Hazards (verified)

- **`--json` silently bypasses `--max-output`.** `snapshot -i --max-output 500` = 570 B
  (capped); add `--json` = 194 KB, uncapped. NEVER pair `--json` with a big observation on a
  heavy page. (Text-mode `--max-output` works — use it.)
- **No built-in output cap** (`AGENT_BROWSER_MAX_OUTPUT` default unlimited). Always pass
  `--max-output` yourself on anything unbounded.
- **`batch` is a client-side loop, not a transaction.** It saves process-spawn only (no daemon
  round-trip savings, no atomicity). Default is CONTINUE-on-error; `--bail` stops but in
  non-`--json` mode calls `exit(1)` and you lose the accumulated results. Exit code is 1 if any
  step failed even without `--bail`.
- **`--state` on an attached real profile INJECTS cookies into the live session** (external CDP
  is exempt from the clean-relaunch guard). Treat `--state`/`--session` restore as dangerous here.

## The doctrine

1. **Act blind when you know the target.** `find role button click --name Submit`, `click "#id"`,
   `fill @ref` — zero observation cost. Don't re-observe a page you already understand.
2. **Climb the ladder, stop at the first rung that answers:** `eval` targeted → `get text
   <scope>` → `snapshot -i -s <container>` → `read` → `snapshot -i`. Whole-page `snapshot -i` on
   a commercial page is a 26k-token bill — SCOPE it with `-s`.
3. **One turn, many commands.** Chain with `&&` (or `batch` for spawn savings) so a whole flow —
   INCLUDING its verification read — is ONE agent turn. "Did it work?" should never cost a turn.
4. **Never dump unbounded streams.** `network requests --filter <pat>` (raw = 82k tok);
   `--max-output N` seatbelt; `read --filter <section>` for docs.
5. **Screenshots: on-failure and final-proof only**, with the JPEG q40 + 800×600 recipe above.
   Refs+text carry action fidelity; pixels are for layout/visual checks.
6. **On any ✗, eager-gather the failure bundle in the SAME turn:**
   `get url && console | tail -20 && snapshot -i -s <region>`, and only then a small JPEG.
7. **Wait on conditions, not sleeps:** `wait --text/--url/--load/--fn`.
8. **Block junk before heavy nav:** `network route "**/analytics**" --abort` — faster loads,
   smaller snapshots.

## Snapshot flag facts (source-verified)

- `-i` (interactive-only) is the render filter; nearly every line already carries a `ref=`.
- `-c` (compact) is a GENUINE no-op under `-i` (it keeps every line that has a `ref=`, which is
  all of them). Meaningful only WITHOUT `-i`.
- `-d N` (depth) has NEGLIGIBLE effect under `-i`: depth counts rendered interactive ancestors,
  which rarely nest, so it only prunes interactive elements nested inside other interactive
  elements (measured: dropped 4 buttons / 0.2% on Kayak). Meaningful only WITHOUT `-i`.
- `-s <selector>` (scope) is the real lever — full-fidelity refs for just the region, ~1k tok
  vs ~26k for the whole page.
