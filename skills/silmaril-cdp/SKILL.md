---
name: silmaril-cdp
description: Browser automation, DOM inspection, page mutation, wait orchestration, flow execution, and local proxy override work through the Silmaril Chrome DevTools Protocol toolkit. Use when the task requires opening Chrome with CDP, navigating pages, reading DOM or source, extracting structured data, clicking or typing into elements, evaluating JavaScript, waiting for UI state changes, running Silmaril flow JSON files, or managing mitmproxy-backed local overrides.
---

# Silmaril CDP

Use this skill to operate the local Silmaril toolkit from PowerShell on Windows or PowerShell 7 on macOS.

## Local path hint

- If a `LOCAL_PATHS.md` file exists beside this skill, read it first and treat it as the authoritative local installation path for the toolkit.
- If `LOCAL_PATHS.md` lists both a Windows and macOS launcher, pick the one that matches the current OS.

## Locate the toolkit

- Prefer the toolkit path recorded in `LOCAL_PATHS.md` when present.
- Otherwise prefer `D:\silmaril cdp\silmaril.cmd` in this environment.
- On macOS, prefer a nearby checkout `silmaril-mac.sh` or `~/silmaril-cdp-tools/silmaril-mac.sh`.
- If that path is missing, also check `%USERPROFILE%\silmaril-cdp-tools\silmaril.cmd`.
- If neither exists, look for `silmaril.cmd` or `silmaril-mac.sh` on `PATH` or in a nearby checkout.
- Invoke from PowerShell with `& '...\silmaril.cmd' ...` on Windows or `& '...\silmaril-mac.sh' ...` on macOS.

## Install the toolkit if missing

Use this setup on Windows when the toolkit is not already present:

Only clone or copy the toolkit after the user explicitly approves fetching or installing remote code.

1. Clone or copy the repository:

   `git clone https://github.com/Malac12/silmaril-CDP-tools.git "D:\silmaril cdp"`

2. Ensure Chrome, Chromium, or Edge is installed.

   The toolkit checks standard Windows install paths and falls back to `chrome.exe` on `PATH`.

3. Run the toolkit from PowerShell:

   `& 'D:\silmaril cdp\silmaril.cmd' openbrowser --json`
   `& 'D:\silmaril cdp\silmaril.cmd' openUrl 'https://example.com' --json`
   `& 'D:\silmaril cdp\silmaril.cmd' get-text 'body' --json`

This is sufficient for the core CDP workflow. No machine-wide PowerShell execution policy change is required because `silmaril.cmd` invokes PowerShell with `ExecutionPolicy Bypass`.

On macOS, use the shell launcher:

`./silmaril-mac.sh openbrowser --json`
`./silmaril-mac.sh openUrl 'https://example.com' --json`
`./silmaril-mac.sh get-text 'body' --json`

## Default workflow

1. Check for an existing CDP browser session first with a lightweight command such as `get-currentUrl --json`.
2. If the session check succeeds, reuse that browser instead of opening a new one.
3. If the session check returns `CDP_UNAVAILABLE` or another no-browser signal, start a CDP browser with `openbrowser --json`, then recheck once with `get-currentUrl --json`.
4. After attaching to the page you plan to use, check `page-memory lookup --json` early when the page might be a revisit, an app-like UI, or a workflow with non-obvious selectors or pitfalls.
5. If page memory returns a strong match, treat it as the default starting point for selectors, playbooks, and known failure modes.
6. Navigate with `openUrl` when needed.
7. If you want ref-based interaction, run `snapshot --json` for visible-page refs or `snapshot --coverage content --json` for a richer content-focused map.
8. Read page state with `exists`, `get-text`, `query`, `get-dom`, or snapshot refs.
9. Mutate only after validating selectors or capturing a fresh snapshot.
10. Wait on one clear synchronization signal after each action.
11. Prefer `run` for short repeatable flows.

## Page Memory First

Page Memory is one of the highest-leverage parts of Silmaril. Use it early instead of treating it as an optional extra.

- Run `page-memory lookup --json` near the start of work when you are revisiting a site, working inside a web app, or dealing with a UI that may have non-obvious selectors, affordances, or pitfalls.
- If lookup returns a recommended or strong match, prefer its selectors and playbooks over rediscovering the page from scratch.
- Use `page-memory verify --id <memoryId> --json` before trusting a saved record on a live page when the workflow matters or the page may have changed.
- When you discover stable selectors, repeatable playbooks, or important pitfalls that would help later runs, consider saving them back into page memory rather than leaving them as one-off chat knowledge.
- Treat page memory as advisory but high-value: verify it when needed, but bias toward using it rather than ignoring it.

## Operating rules

- Prefer `--json` for almost every command so later steps can parse structured output.
- Do not launch a fresh browser blindly. Always check whether a CDP session is already available first, and only call `openbrowser` when no session is reachable.
- Prefer `page-memory lookup --json` early on revisited pages or app-like workflows before spending time rediscovering selectors and behaviors manually.
- Prefer live DOM commands over `get-source` when choosing selectors or checking rendered state.
- Selector reads are visibility-aware where that helps normal interaction: `get-text` prefers the first visible match and falls back to the first DOM match only when every match is hidden. `get-dom` stays DOM-first for markup debugging and reports visibility metadata.
- Plain `query` returns rows in DOM order. Use `query --visible-only` for visible rows first/only, especially on feeds, search results, and pages with hidden mobile/desktop duplicates.
- Use `snapshot --json` when you want a compact map of the current visible page with reusable refs such as `e1`, `e2`, and `e27`.
- `snapshot` defaults to `viewport` coverage. If the useful content is below a sticky header or top nav, either scroll that content into view first or use `snapshot --coverage content`.
- `snapshot --coverage content` keeps the snapshot bounded but prefers richer content roots such as `main` and reaches further below the fold.
- Treat refs as short-lived. After page-changing navigation or a meaningful content transition, rerun `snapshot` before using refs again.
- Prefer stable selectors such as `data-test`, `data-testid`, semantic IDs, and meaningful attributes.
- When multiple tabs exist, run `list-pages --json`, then use one page selector: `--page-id`, `--url-contains`, `--url-match`, `--title-contains`, or `--title-match`.
- Prefer `set-page --yes` to make the intended page the default target for the port. `target-show`, `target-pin --yes`, and `target-clear --yes` remain available for lower-level CDP target work.
- Commands that resolve a page target now activate that tab automatically, so the visible Chrome tab follows the target being controlled.
- When a selector command fails in JSON mode, inspect `suggestedSelectors`, `candidates`, `recovery`, labels, roles, and visibility before retrying. Do not guess a new selector when recovery data is available.
- Pass `--yes` for page actions and mutations such as `click`, `type`, `set-text`, `set-html`, and `eval-js`.
- Treat `eval-js`, `proxy-override`, `proxy-switch`, and `openurl-proxy` as high-risk commands.
- Use `--allow-unsafe-js` for `eval-js`, or set `SILMARIL_ALLOW_UNSAFE_JS=1` only for a trusted local session.
- Use `--allow-mitm` for proxy commands, or set `SILMARIL_ALLOW_MITM=1` only for a trusted local session.
- Keep proxy listeners on loopback addresses unless the user explicitly requests `--allow-nonlocal-bind`.
- Put long JavaScript in a file and use `eval-js --file` instead of pasting large inline expressions.
- Add `--isolate-scope` when rerunning helper-heavy JS on the same live page to avoid top-level redeclaration errors.
- Avoid fixed sleeps when a wait command can express the intended state.

## Command selection

- Use `get-text` for a single text value; selector reads prefer the first visible match.
- Use `query` for structured multi-row extraction. Add `--visible-only` when the task wants visible page content instead of raw DOM order.
- Use `get-dom` to debug selector or markup issues. Selector mode is DOM-first and reports `selectionPolicy`, `selectedMatch`, `selectedVisible`, `matchedCount`, and `visibleCount` in JSON output.
- Use `snapshot` when a balanced page map plus short refs is more useful than raw selectors.
- Use `get-source` only when raw response HTML matters more than the rendered DOM.
- Use `wait-for`, `wait-for-any`, `wait-for-gone`, `wait-for-visible-count`, `wait-for-count`, `wait-until-js`, or `wait-for-mutation` to synchronize.
- Prefer `wait-for-visible-count` or `wait-for-count` over raw JS when waiting for list/feed growth.
- Use `page-memory lookup --json` early when revisiting a page/app and reusable selectors, pitfalls, or playbooks might already be stored.
- Use `page-memory verify --id <memoryId> --json` before trusting saved memory on a live page; verification includes selector existence, counts, visible counts, and first-match role/label/text metadata.

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

## References

- Read `references/command-patterns.md` for common command shapes and PowerShell-safe examples.
- Read `references/flows.md` before building or editing a `run` flow.
- Read `references/proxy.md` when working with `openurl-proxy`, `proxy-override`, or `proxy-switch`.
