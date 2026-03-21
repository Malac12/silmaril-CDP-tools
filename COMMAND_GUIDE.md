# Silmaril CDP Command Guide

This guide covers practical usage patterns for `silmaril.cmd` commands.

## 1. Quick Start

```powershell
silmaril.cmd openbrowser
silmaril.cmd openUrl "D:\silmairl cdp\test-page.html"
```

If URL input is a local file path, `openUrl` will convert it to a `file:///...` URL.

## 2. Read Commands

```powershell
silmaril.cmd get-currentUrl
silmaril.cmd list-urls
silmaril.cmd get-dom
silmaril.cmd get-dom "#main"
silmaril.cmd get-text "#title"
silmaril.cmd query "a[href]" --fields "text,href,attr:data-test" --limit 20
silmaril.cmd get-source
```

- `get-dom` reads live DOM.
- `get-source` reads page source HTML (network/resource source).
- `query` returns structured rows for selector matches.

### Choosing Between `get-text`, `get-dom`, and `query`

Use each command for a different read shape:

- `get-text`: single scalar text read from one selector.
- `get-dom`: raw live HTML snapshot for inspection/debugging.
- `query`: structured multi-row extraction, for example fields like `text,href,attr:data-test` with optional limits.

Practical split:

- Use `get-text` for quick assertions and simple guards.
- Use `get-dom` when diagnosing selector/markup issues.
- Use `query` for pipeline-friendly semantic JSON extraction.

`query` field syntax:

- Built-ins: `text`, `href`, `html`, `outer-html`, `tag`, `value`, `visible`
- Attributes: `attr:name` (for example `attr:data-test`)
- Properties: `prop:name`

## 3. Action Commands

```powershell
silmaril.cmd click "#submit-btn" --yes
silmaril.cmd type "#search-input" "hello world" --yes
silmaril.cmd set-text "#status" "Done" --yes
silmaril.cmd set-html "#box" "<h3>Updated</h3>" --yes
```

- Mutations and actions require `--yes`.
- `type` works for `input`, `textarea`, and `contenteditable`.

## 4. Wait Commands

```powershell
silmaril.cmd wait-for "#result"
silmaril.cmd wait-for-any ".result-list" ".empty-state" ".error-banner"
silmaril.cmd wait-for-gone ".loading-overlay"
silmaril.cmd wait-until-js "document.querySelectorAll('.item').length > 0"
silmaril.cmd wait-for-mutation "#app"
silmaril.cmd wait-for-mutation "#app" --details
silmaril.cmd wait-for-any ".result-list" ".empty-state" --counts --json
```

- `wait-for`: waits for a visible match.
- `wait-for-any`: waits until any provided selector is visibly matched.
- `wait-for-gone`: waits until no visible matches remain.
- `wait-until-js`: waits until a JS condition is truthy.
- `wait-for-mutation`: hook-style wait with `MutationObserver`.
- `wait-for-any --json` returns `matchedSelector` and can optionally include per-selector `counts` with `--counts`.

## 5. Important Advice

- If you run `wait-for-mutation` on `body`, you may get noisy background mutations from frameworks, analytics, or timers.
- Prefer a smaller container selector (for example `#app`, `#main`, `#wait-zone`) for cleaner and more meaningful mutation signals.
- For mutation debugging, use `--details` to print mutation JSON.

## 6. Quoting and Shell Pitfalls

- In Windows shell, `<` and `>` may be interpreted as redirection.
- Selector commands now normalize a few common shell-damaged forms, especially unquoted attribute values such as `[data-test=launch]` or `a[href^=/products/]`.
- That normalization is a safety net, not a license to ignore quoting. For selectors or HTML/JS with spaces or shell metacharacters, keep quoting properly or move the payload into a file.
- For HTML arguments, use PowerShell stop-parsing when needed:

```powershell
silmaril.cmd --% set-html "#box" "<h1>Hi</h1>" --yes
```

## 7. Reliable Flow Pattern

```powershell
silmaril.cmd click "#submit" --yes
silmaril.cmd wait-for ".spinner"
silmaril.cmd wait-for-gone ".spinner"
silmaril.cmd wait-for "#result"
silmaril.cmd get-text "#result .title"
```

Use one clear synchronization signal after each action. Avoid fixed sleeps when possible.

## 8. Long JS Without `>>`

If PowerShell shows `>>`, your pasted JS likely opened an unfinished quote.
Use file mode instead of pasting long code inline:

```powershell
silmaril.cmd eval-js --file "D:\silmairl cdp\script.js" --allow-unsafe-js --yes
```

This avoids multiline quoting issues in terminal input.



## 9. Prefer File-Based JS for Reliability

For this toolkit, putting JS in a file is usually the most reliable approach.

Use this pattern:

```powershell
@'
JSON.stringify(
  Array.from(document.querySelectorAll('a[href]'))
    .map(a => a.getAttribute('href'))
    .filter(h => h && h.startsWith('/'))
    .slice(0, 40)
)
'@ | Set-Content C:\Users\hangx\expr.js -Encoding UTF8

cmd /c C:\Users\hangx\AppData\Roaming\npm\silmaril.cmd eval-js --file "C:\Users\hangx\expr.js" --allow-unsafe-js --yes
```

This avoids quoting/operator issues like && in inline shell strings.



## 10. DOM-First Targeting (Especially for Complex Webpages)

Yes. For this toolkit and sites like Product Hunt: prefer live DOM over raw source for element targeting.

Practical rule:

1. Use DOM first

- exists, get-text, get-dom "selector", eval-js
- This reflects what is actually rendered and interactive.

2. Use source only as fallback

- get-source is good for broad discovery, but often bloated by SSR/hydration data and can mislead selector choice.

3. Selector strategy

- Prefer stable hooks: data-test, data-testid, semantic IDs.
- Avoid fragile utility-class chains unless no better option exists.
- Validate selector before mutation:
  - exists "selector"
  - get-text "selector" or eval-js count checks.

4. For complex JS

- Put JS in a file and run eval-js --file ... --yes to avoid quoting/operator issues.

So the practical rule is:

- Try --file first for complex JS.
- If --file hangs, fallback to inline and keep the payload compact.



## 11. JSON Output Mode

Use `--json` as the final argument to get structured output across commands.

Examples:

```powershell
silmaril.cmd list-urls --json
silmaril.cmd get-dom "#main" --json
silmaril.cmd eval-js "document.title" --allow-unsafe-js --yes --json
silmaril.cmd wait-for-mutation "#app" --details --json
```

Behavior:

- Success returns JSON with `ok: true`, `command`, and command-specific fields.
- Failures return JSON with `ok: false`, `command`, and `error`.
- Keep `--json` at the end of the command.
- `exists --json` still uses exit code `0` when found and `1` when not found, but output is structured JSON in both cases.

Why this helps:

- Avoids fragile text parsing in shell pipelines and automation scripts.
- Makes `list-urls`, `get-dom`, `eval-js`, and wait/action commands easier to consume programmatically.

## 12. File Input Modes for Mutations

For complex payloads, prefer file-based input over long inline strings.

Supported patterns:

```powershell
silmaril.cmd set-text "#status" --text-file "C:\Users\hangx\status.txt" --yes
silmaril.cmd set-html "#box" --html-file "C:\Users\hangx\snippet.html" --yes
silmaril.cmd type "#editor" --text-file "C:\Users\hangx\draft.txt" --yes
```

Aliases:

- `set-text`: `--text-file` (or `--file`)
- `set-html`: `--html-file` (or `--file`)
- `type`: `--text-file` (or `--file`)

Precedence rule (strict):

- Do not mix inline payload and file flags in one command.
- Mixed forms such as `set-text "#x" "inline" --text-file "path" --yes` return a hard error.

File size guard:

- File-mode payloads have a max size of `1048576` bytes (1 MiB).
- Oversized files fail fast with a readable error before CDP execution.
Use `--json` at the end when automating:

```powershell
silmaril.cmd set-text "#status" --text-file "C:\Users\hangx\status.txt" --yes --json
```

## 13. eval-js --file Reliability

`eval-js --file` remains the preferred mode for complex JavaScript.

Safeguard note:

- `eval-js` now requires `--allow-unsafe-js` unless `SILMARIL_ALLOW_UNSAFE_JS=1` is already set for a trusted local session.

JSON metadata notes:

- File-mode command JSON includes `inputMode`, `filePath`, and `bytes`.
- `eval-js --json` also includes `attempt` and `timeoutSec`.
- `eval-js --isolate-scope --json` also includes `isolateScope: true` so callers can tell that the script was wrapped in an isolated async scope.
Current reliability behavior:

- Uses UTF-8 file loading via shared toolkit helper.
- Uses a longer CDP timeout for file mode.
- Retries once automatically on timeout-like CDP failures (not on JavaScript runtime exceptions).
- Supports `--result-json` strict mode.
- Supports `--isolate-scope` to avoid `const` and `let` redeclaration collisions when the same helper file is evaluated repeatedly in a live page session.

Strict mode example:

```powershell
silmaril.cmd eval-js --file "C:\Users\hangx\x.js" --allow-unsafe-js --yes --result-json --json
```

- Fails unless the result is a valid JSON object/array.
- Avoids double-parsing when JS returns JSON text.

Practical rule:

- Try `--file` first for complex JS.
- Add `--isolate-scope` when the script declares top-level helpers and may be rerun on the same page.
- If it still hangs in your page context, fallback to a compact inline expression.

## 14. Local MITM Overrides

To make page changes persist across refresh, use a local MITM proxy that serves local files for matched URLs.

Safeguard note:

- `proxy-override`, `proxy-switch`, and `openurl-proxy` now require `--allow-mitm` unless `SILMARIL_ALLOW_MITM=1` is already set for a trusted local session.
- Proxy listeners stay loopback-only unless `--allow-nonlocal-bind` is explicitly provided.

Toolkit files:

- `tools/mitm/local_overrides.py`
- `tools/mitm/rules.example.json`
- `tools/mitm/README.md`

Quick start:

1. Install `mitmproxy`.
2. Copy `tools/mitm/rules.example.json` to `tools/mitm/rules.json` and edit mappings.
3. Generate and trust the mitmproxy CA certificate so HTTPS interception works.
4. Run:

```powershell
$env:SILMARIL_MITM_RULES = "D:\silmairl cdp\tools\mitm\rules.json"
mitmdump -s "D:\silmairl cdp\tools\mitm\local_overrides.py" --listen-host 127.0.0.1 --listen-port 8080
```

If upstream certificate verification on your machine causes `502 Bad Gateway`, retry with:

```powershell
$env:SILMARIL_MITM_RULES = "D:\silmairl cdp\tools\mitm\rules.json"
mitmdump -s "D:\silmairl cdp\tools\mitm\local_overrides.py" --listen-host 127.0.0.1 --listen-port 8080 --set ssl_insecure=true
```

5. Launch Chrome with:

```powershell
start chrome --proxy-server="http://127.0.0.1:8080"
```

Windows certificate trust example:

```powershell
mitmdump --quit
Import-Certificate -FilePath "$env:USERPROFILE\.mitmproxy\mitmproxy-ca-cert.cer" -CertStoreLocation 'Cert:\CurrentUser\Root'
```

PowerShell note:

- `start "" "C:\...\chrome.exe" ...` is CMD syntax and fails in PowerShell.
- In PowerShell use:

```powershell
Start-Process -FilePath "C:\Program Files\Google\Chrome\Application\chrome.exe" -ArgumentList @(
  "--proxy-server=http://127.0.0.1:8080"
  "--new-window"
  "https://en.wikipedia.org/wiki/Pizza"
)
```

One-command workflow (write rule + start proxy):

```powershell
silmaril.cmd proxy-override --allow-mitm --match "https://www\\.example\\.com/assets/app\\.js$" --file "C:\Users\hangx\overrides\app.js" --yes
```

This command:

- Adds or updates the matching rule in `tools/mitm/rules.json` (or `--rules-file` path).
- Starts `mitmdump` in background by default.
- Uses `tools/mitm/local_overrides.py` automatically.

Useful flags:

- `--attach` to run proxy in foreground.
- `--dry-run` to validate args and generated config without starting proxy.
- `--mitmdump "C:\path\to\mitmdump.exe"` to force a specific binary.
- `--listen-port 8080` to choose a different proxy port when needed.
- `--json` for structured startup output.

Autostart + open URL through proxy:

```powershell
silmaril.cmd openurl-proxy "https://en.wikipedia.org/wiki/Pizza" --allow-mitm
```

Behavior:

- Starts MITM proxy automatically if not already listening.
- Reuses existing proxy if already running on the target port.
- Opens Chrome with `--proxy-server` and a dedicated profile directory.

Switch a rule between original/saved files:

```powershell
silmaril.cmd proxy-switch --match "https://en\.wikipedia\.org/wiki/Pizza(?:\?.*)?$" --original-file "D:\silmairl cdp\tools\mitm\overrides\pizza.raw.html" --saved-file "D:\silmairl cdp\tools\mitm\overrides\pizza.override.html" --use original --allow-mitm --yes
silmaril.cmd proxy-switch --match "https://en\.wikipedia\.org/wiki/Pizza(?:\?.*)?$" --original-file "D:\silmairl cdp\tools\mitm\overrides\pizza.raw.html" --saved-file "D:\silmairl cdp\tools\mitm\overrides\pizza.override.html" --use saved --allow-mitm --yes
```

Notes:

- `--use original` points the matched URL back to your original snapshot file.
- `--use saved` points the matched URL to your edited/saved file.
- Rule update takes effect on next request; no rule file manual edit needed.



## 15. Common Target and Timing Flags

Many commands now support the same targeting/timing flags:

- `--port <n>`: CDP port (default `9222`)
- `--target-id <id>`: choose an exact CDP page target id
- `--url-match <regex>`: choose a page target by URL regex
- `--timeout-ms <n>`: command timeout in milliseconds
- `--poll-ms <n>`: polling interval for wait/open commands

Targeting rule:

- Use either `--target-id` or `--url-match` (not both).
- When neither is provided, Silmaril prefers a pinned target for that CDP port, then the last ephemeral target, then falls back by prior URL if the target id changed after a rerender/navigation.
- An explicit `--url-match` now throws a structured `TARGET_AMBIGUOUS` error if multiple tabs match and no pinned target breaks the tie.
- Use `target-pin --yes` to make a target the default for a port, `target-show --json` to inspect the current pinned and ephemeral state, and `target-clear --yes` to remove stored target state.
- `list-urls --json` now includes `targetStateSource`, `pinnedState`, `ephemeralState`, and per-target flags such as `isPinned`, `isEphemeral`, and `isSelected`.
- Command JSON now includes `resolvedTargetId`, `resolvedUrl`, `resolvedTitle`, `targetSelection`, and `targetStateSource` so follow-up automation can audit which page target actually ran.

Examples:

```powershell
silmaril.cmd get-text "#title" --port 9223 --url-match "example\.com" --timeout-ms 8000 --json
silmaril.cmd wait-for "#result" --target-id "ABCD1234" --timeout-ms 15000 --poll-ms 150 --json
silmaril.cmd target-pin --current --port 9223 --yes --json
silmaril.cmd target-show --port 9223 --json
```

## 16. Declarative Runbook Command

You can execute a flow file with built-in retries and artifact capture:

```powershell
silmaril.cmd run "D:\silmairl cdp\flow.json" --json
```

Minimal flow example:

```json
{
  "name": "demo-flow",
  "settings": {
    "port": 9222,
    "timeoutMs": 10000,
    "pollMs": 200,
    "retries": 1
  },
  "steps": [
    { "action": "openUrl", "url": "https://example.com" },
    { "action": "wait-for", "selector": "h1" },
    { "action": "query", "selector": "a[href]", "fields": "text,href", "limit": 5 }
  ]
}
```

Supported `run` actions:

- `openbrowser`
- `openUrl`
- `wait-for`
- `click`
- `query`

Artifacts include:

- `steps/*.json` per-step execution payloads
- `summary.json`
- `run.log`
- `final-dom.html` snapshot (when available)
