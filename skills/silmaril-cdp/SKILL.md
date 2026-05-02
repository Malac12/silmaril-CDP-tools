---
name: silmaril-cdp
description: Browser automation, DOM inspection, page mutation, wait orchestration, flow execution, and local proxy override work through the Silmaril Chrome DevTools Protocol toolkit. Use when the task requires opening Chrome with CDP, navigating pages, reading DOM or source, extracting structured data, clicking or typing into elements, evaluating JavaScript, waiting for UI state changes, running Silmaril flow JSON files, or managing mitmproxy-backed local overrides.
---

# Silmaril CDP

Use this skill to operate the local Silmaril toolkit from PowerShell on Windows or PowerShell 7 on macOS. Silmaril is meant to be agent-friendly browser control: reuse browser sessions, target the intended page explicitly, inspect live DOM state, recover from selector failures with structured hints, and keep useful page knowledge in page memory.

## Agent Golden Path

1. Check for an existing CDP browser session: `get-currentUrl --json`.
2. If unavailable, start one: `openbrowser --json`, then recheck once.
3. If the intended tab is uncertain, run `list-pages --json`.
4. Pin the intended page when multiple tabs or target drift are possible: `set-page --url-contains "..." --yes --json`.
5. On revisited sites or app-like workflows, run `page-memory lookup --json` before rediscovering selectors.
6. Inspect current UI with `snapshot --json`, `query --json`, `get-text --json`, or `get-dom --json`.
7. Act only after selector validation or a fresh snapshot: `click ... --yes --json`, `type ... --yes --json`, etc.
8. After each mutation, wait on one clear signal with a wait command instead of sleeping.
9. If a selector fails, use the JSON `recovery`, `suggestedSelectors`, and `candidates` before guessing.
10. Prefer `run` for short repeatable flows once the command sequence is known.

## Core Recipes

### Reuse Or Open Browser

Use `get-currentUrl --json` first. If it returns `CDP_UNAVAILABLE` or another no-browser signal, run `openbrowser --json`; otherwise reuse the existing browser.

### Multi-Tab Targeting

When more than one page may exist:

1. Run `list-pages --json`.
2. Choose one page selector: `--page-id`, `--url-contains`, `--url-match`, `--title-contains`, or `--title-match`.
3. Pin it with `set-page --url-contains "checkout" --yes --json` when later commands should default to that page.
4. Pass a page selector directly on commands when you do not want to rely on pinned state.

Commands that resolve a page target activate that Chrome tab, so the visible tab follows the page being controlled.

### Page Memory

Use page memory early when returning to a site, working in a web app, or handling a workflow with non-obvious selectors or pitfalls.

1. Run `page-memory lookup --json`.
2. If it returns a recommended or strong match, prefer its selectors and playbooks.
3. Before trusting saved memory for important work, run `page-memory verify --id <memoryId> --json`.
4. Verification reports selector existence, match counts, visible counts, and first-match role/label/text metadata.
5. When you discover stable selectors, repeatable playbooks, or important pitfalls, consider saving them back into page memory.

Treat page memory as advisory but high-value: verify when needed, but do not ignore a strong match by default.

### Selector Failure Recovery

When a selector command fails in JSON mode:

1. Inspect `recovery.suggestedSelectors`, top-level `suggestedSelectors`, `candidates`, labels, roles, visibility, and disabled state.
2. Retry the best suggested stable selector first.
3. If recovery candidates are weak, run `snapshot --json` for refs or `query --visible-only --json` for visible rows.
4. Use `get-dom` when debugging markup; it is DOM-first and reports visibility metadata.

Do not guess a new selector when structured recovery data is available.

### Long JavaScript

Put long JavaScript in a file and run `eval-js --file <path> --allow-unsafe-js --yes --json`. Add `--isolate-scope` when rerunning helper-heavy JS on the same live page to avoid top-level redeclaration errors.

## Command Selection

- Use `get-text` for one text value; it prefers the first visible match and falls back to the first DOM match only when all matches are hidden.
- Use `query` for structured multi-row extraction. Add `--visible-only` when the task wants visible page content instead of raw DOM order.
- Use `get-dom` for selector or markup debugging. Selector mode is DOM-first and reports `selectionPolicy`, `selectedMatch`, `selectedVisible`, `matchedCount`, and `visibleCount`.
- Use `snapshot --json` for a compact visible-page map with reusable refs such as `e1`, `e2`, and `e27`.
- Use `snapshot --coverage content --json` when useful content is below sticky navigation or outside the first viewport.
- Use `get-source` only when raw response HTML matters more than rendered DOM.
- Use `wait-for`, `wait-for-any`, `wait-for-gone`, `wait-for-visible-count`, `wait-for-count`, `wait-until-js`, or `wait-for-mutation` to synchronize.
- Prefer `wait-for-visible-count` or `wait-for-count` over raw JS when waiting for list or feed growth.

Ref-aware selector commands:

- `click`
- `type`
- `get-text`
- `get-dom`
- `exists`
- `wait-for`
- `wait-for-gone`
- `scroll`

`scroll --container` also accepts a ref.

## Operating Rules

- Prefer `--json` for almost every command so later steps can parse structured output.
- Do not launch a fresh browser blindly. Check for a reachable CDP session first.
- Prefer live DOM commands over `get-source` when choosing selectors or checking rendered state.
- Prefer stable selectors such as `data-test`, `data-testid`, semantic IDs, and meaningful attributes.
- Treat snapshot refs as short-lived. After navigation or a meaningful content transition, rerun `snapshot`.
- Pass `--yes` for page actions and mutations such as `click`, `type`, `set-text`, `set-html`, and `eval-js`.
- Use only one page selector per command: `--page-id`, `--target-id`, `--url-contains`, `--url-match`, `--title-contains`, or `--title-match`.
- Prefer `set-page --yes` over lower-level target pinning. `target-show`, `target-pin --yes`, and `target-clear --yes` remain available for CDP target work.
- Treat `eval-js`, `proxy-override`, `proxy-switch`, and `openurl-proxy` as high-risk commands.
- Use `--allow-unsafe-js` for `eval-js`, or set `SILMARIL_ALLOW_UNSAFE_JS=1` only for a trusted local session.
- Use `--allow-mitm` for proxy commands, or set `SILMARIL_ALLOW_MITM=1` only for a trusted local session.
- Keep proxy listeners on loopback addresses unless the user explicitly requests `--allow-nonlocal-bind`.
- Avoid fixed sleeps when a wait command can express the intended state.

## Locate The Toolkit

- If a `LOCAL_PATHS.md` file exists beside this skill, read it first and treat it as the authoritative local installation path.
- Prefer the toolkit path recorded in `LOCAL_PATHS.md` when present.
- Otherwise prefer `D:\silmaril cdp\silmaril.cmd` in this environment.
- On macOS, prefer a nearby checkout `silmaril-mac.sh` or `~/silmaril-cdp-tools/silmaril-mac.sh`.
- If that path is missing, also check `%USERPROFILE%\silmaril-cdp-tools\silmaril.cmd`.
- If neither exists, look for `silmaril.cmd` or `silmaril-mac.sh` on `PATH` or in a nearby checkout.
- Invoke from PowerShell with `& '...\silmaril.cmd' ...` on Windows or `& '...\silmaril-mac.sh' ...` on macOS.

## Install If Missing

Only clone or copy the toolkit after the user explicitly approves fetching or installing remote code.

Windows setup:

1. Clone or copy the repository: `git clone https://github.com/Malac12/silmaril-CDP-tools.git "D:\silmaril cdp"`.
2. Ensure Chrome, Chromium, or Edge is installed.
3. Run a smoke command: `& 'D:\silmaril cdp\silmaril.cmd' openbrowser --json`.

macOS setup:

1. Use the shell launcher: `./silmaril-mac.sh openbrowser --json`.
2. Then run `./silmaril-mac.sh openUrl 'https://example.com' --json`.
3. Read a simple value with `./silmaril-mac.sh get-text 'body' --json`.

No machine-wide PowerShell execution policy change is required on Windows because `silmaril.cmd` invokes PowerShell with `ExecutionPolicy Bypass`.

## References

- Read `references/command-patterns.md` for common command shapes and PowerShell-safe examples.
- Read `references/flows.md` before building or editing a `run` flow.
- Read `references/proxy.md` when working with `openurl-proxy`, `proxy-override`, or `proxy-switch`.
