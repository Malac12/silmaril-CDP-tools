# Command Patterns

## PowerShell invocation

Use the checked-out toolkit directly:

```powershell
& 'D:\silmaril cdp\silmaril.cmd' openbrowser --json
& 'D:\silmaril cdp\silmaril.cmd' openUrl 'https://example.com' --json
```

If the checkout is not present at that path, resolve `silmaril.cmd` from `PATH` or the local workspace before proceeding.

## Read patterns

- Visible-page snapshot with refs: `snapshot --json`
- Content-focused snapshot with refs: `snapshot --coverage content --json`
- Single assertion: `get-text '#title' --json`
- Single assertion by ref: `get-text 'e12' --json`
- Presence check: `exists '[data-test="submit"]' --json`
- Structured extraction: `query 'a[href]' --fields 'text,href,attr:data-test' --limit 20 --json`
- Debug markup: `get-dom '#main' --json`
- Reuse prior knowledge early: `page-memory lookup --json`

Prefer `query` when later steps need rows or machine-readable fields.

Practical rule:

- On revisited sites and app-like pages, check `page-memory lookup --json` before doing manual selector discovery unless the task is obviously trivial.
- Use `snapshot --json` when you want a compact map of the current visible page and short refs instead of hand-picked selectors.
- `snapshot` defaults to `viewport` coverage.
- On sticky-header or top-nav-heavy pages, either scroll the content you care about into view first or use `snapshot --coverage content`.
- `snapshot --coverage content` stays bounded but prefers richer content roots such as `main` and reaches further below the fold.
- After page-changing navigation or a major content transition, rerun `snapshot` before reusing refs.

## Page Memory patterns

- Save a reusable record: `page-memory save --file 'C:\path\record.json' --yes --json`
- Verify a saved record on the current page: `page-memory verify --id 'memory-id' --json`
- List saved records: `page-memory list --json`

## Action patterns

- Click: `click '#submit' --yes --json`
- Click by ref: `click 'e27' --yes --json`
- Type: `type '#search' 'hello world' --yes --json`
- Type by ref: `type 'e3' 'hello world' --yes --json`
- Replace text: `set-text '#status' 'Done' --yes --json`
- Replace HTML: `set-html '#box' '<h3>Updated</h3>' --yes --json`
- Scroll by ref: `scroll 'e20' --json`
- Scroll a container by ref: `scroll --container 'e33' --y 400 --json`

Validate the selector first with `exists`, `get-text`, or `query`.

Ref-aware commands currently include:

- `click`
- `type`
- `get-text`
- `get-dom`
- `exists`
- `wait-for`
- `wait-for-gone`
- `scroll`

## Wait patterns

- Show element: `wait-for '#result' --json`
- Wait for any outcome: `wait-for-any '.result-list' '.empty-state' --counts --json`
- Spinner disappears: `wait-for-gone '.spinner' --json`
- JS condition: `wait-until-js "document.querySelectorAll('.item').length > 0" --json`
- Mutation watch: `wait-for-mutation '#app' --details --json`

Use one explicit wait after each action instead of sleeping.

## JavaScript patterns

Prefer inline `eval-js` only for short expressions:

```powershell
& 'D:\silmaril cdp\silmaril.cmd' eval-js "document.title" --allow-unsafe-js --yes --json
```

Prefer file mode for longer logic:

```powershell
Set-Content -LiteralPath 'C:\Users\hangx\silmaril-expr.js' -Encoding UTF8 -Value "JSON.stringify(Array.from(document.querySelectorAll('a[href]')).map(a => a.href))"
& 'D:\silmaril cdp\silmaril.cmd' eval-js --file 'C:\Users\hangx\silmaril-expr.js' --allow-unsafe-js --yes --json
```

If the file declares top-level helpers that may be reused on the same tab, isolate it:

```powershell
& 'D:\silmaril cdp\silmaril.cmd' eval-js --file 'C:\Users\hangx\silmaril-expr.js' --allow-unsafe-js --yes --isolate-scope --json
```

High-risk rule:

- `eval-js` requires `--allow-unsafe-js` unless `SILMARIL_ALLOW_UNSAFE_JS=1` is already set for a trusted local session.
- Proxy commands require `--allow-mitm` unless `SILMARIL_ALLOW_MITM=1` is already set for a trusted local session.
- Proxy listeners stay loopback-only unless `--allow-nonlocal-bind` is explicitly requested.

## Targeting rules

- Use `--target-id` when a specific CDP page target is already known.
- Use `--url-match` when selecting a page by URL pattern is simpler.
- Never pass both flags in the same call.
- When no targeting flag is passed, Silmaril prefers a pinned target for the port, then the last ephemeral target.
- When a target is resolved, Silmaril activates that tab automatically so the visible browser tab follows the command target.
- If `--url-match` hits multiple tabs, use `target-pin --yes` or `target-id` to break the tie instead of relying on tab order.

Useful inspection commands:

- `target-show --json` to inspect pinned and ephemeral state for a port.
- `target-pin --current --yes --json` to make the current page the default target.
- `target-clear --yes --json` to remove stored target state.

## Source files

For deeper details, consult the local toolkit docs in `D:\silmaril cdp\COMMAND_GUIDE.md` and the command implementations under `D:\silmaril cdp\commands\`.
