---
name: silmaril-cdp
description: Browser automation, DOM inspection, page mutation, wait orchestration, flow execution, and local proxy override work through the Silmaril Chrome DevTools Protocol toolkit. Use when the task requires opening Chrome with CDP, navigating pages, reading DOM or source, extracting structured data, clicking or typing into elements, evaluating JavaScript, waiting for UI state changes, running Silmaril flow JSON files, or managing mitmproxy-backed local overrides.
---

# Silmaril CDP

Use this skill to operate the local Silmaril toolkit from PowerShell.

## Locate the toolkit

- Prefer `D:\silmairl cdp\silmaril.cmd` in this environment.
- If that path is missing, look for `silmaril.cmd` on `PATH` or in a nearby checkout.
- Invoke from PowerShell with `& 'D:\silmairl cdp\silmaril.cmd' ...`.

## Default workflow

1. Start or attach a CDP browser with `openbrowser`.
2. Navigate with `openUrl`.
3. Read page state with `exists`, `get-text`, `query`, or `get-dom`.
4. Mutate only after validating selectors.
5. Wait on one clear synchronization signal after each action.
6. Prefer `run` for short repeatable flows.

## Operating rules

- Prefer `--json` for almost every command so later steps can parse structured output.
- Prefer live DOM commands over `get-source` when choosing selectors or checking rendered state.
- Prefer stable selectors such as `data-test`, `data-testid`, semantic IDs, and meaningful attributes.
- Use either `--target-id` or `--url-match` when multiple tabs exist; never use both together.
- Pass `--yes` for page actions and mutations such as `click`, `type`, `set-text`, `set-html`, and `eval-js`.
- Put long JavaScript in a file and use `eval-js --file` instead of pasting large inline expressions.
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
