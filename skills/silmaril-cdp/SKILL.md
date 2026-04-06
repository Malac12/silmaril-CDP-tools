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
4. Navigate with `openUrl`.
5. Read page state with `exists`, `get-text`, `query`, or `get-dom`.
6. Mutate only after validating selectors.
7. Wait on one clear synchronization signal after each action.
8. Prefer `run` for short repeatable flows.

## Operating rules

- Prefer `--json` for almost every command so later steps can parse structured output.
- Do not launch a fresh browser blindly. Always check whether a CDP session is already available first, and only call `openbrowser` when no session is reachable.
- Prefer live DOM commands over `get-source` when choosing selectors or checking rendered state.
- Prefer stable selectors such as `data-test`, `data-testid`, semantic IDs, and meaningful attributes.
- Use either `--target-id` or `--url-match` when multiple tabs exist; never use both together.
- Use `target-show`, `target-pin --yes`, and `target-clear --yes` to manage persistent target selection instead of depending on tab order.
- Commands that resolve a page target now activate that tab automatically, so the visible Chrome tab follows the target being controlled.
- Pass `--yes` for page actions and mutations such as `click`, `type`, `set-text`, `set-html`, and `eval-js`.
- Treat `eval-js`, `proxy-override`, `proxy-switch`, and `openurl-proxy` as high-risk commands.
- Use `--allow-unsafe-js` for `eval-js`, or set `SILMARIL_ALLOW_UNSAFE_JS=1` only for a trusted local session.
- Use `--allow-mitm` for proxy commands, or set `SILMARIL_ALLOW_MITM=1` only for a trusted local session.
- Keep proxy listeners on loopback addresses unless the user explicitly requests `--allow-nonlocal-bind`.
- Put long JavaScript in a file and use `eval-js --file` instead of pasting large inline expressions.
- Add `--isolate-scope` when rerunning helper-heavy JS on the same live page to avoid top-level redeclaration errors.
- Avoid fixed sleeps when a wait command can express the intended state.

## Command selection

- Use `get-text` for a single text value.
- Use `query` for structured multi-row extraction.
- Use `get-dom` to debug selector or markup issues.
- Use `get-source` only when raw response HTML matters more than the rendered DOM.
- Use `wait-for`, `wait-for-any`, `wait-for-gone`, `wait-until-js`, or `wait-for-mutation` to synchronize.

## References

- Read `references/command-patterns.md` for common command shapes and PowerShell-safe examples.
- Read `references/flows.md` before building or editing a `run` flow.
- Read `references/proxy.md` when working with `openurl-proxy`, `proxy-override`, or `proxy-switch`.
