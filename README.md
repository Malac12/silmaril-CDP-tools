# Silmaril

Silmaril is a browser command kit for local AI agents.

It helps Codex or Claude run browser commands directly from the terminal against your real local browser, so they can handle everyday browser tasks without forcing you into a separate AI browser or a heavy automation setup.

## Why Silmaril

I wanted an AI assistant to help with everyday browser work:

- inspect a page quickly
- grab a piece of information from a live site
- click through a real flow
- help with a small messy task in a logged-in browser session

Existing options did not fit that workflow well:

- AI browsers often mean another standalone browser and another product to pay for
- Playwright and Puppeteer are excellent for heavier automation, but they are often too much setup and maintenance for immediate one-off tasks

Silmaril is built for that middle ground: flexible browser control for local AI agents working in real-life situations.

## Why Not Just Playwright

Playwright is excellent for test suites and scripted browser automation. The problem I kept hitting with Codex was different: I wanted an agent to operate a real browser session, stay oriented across tabs, inspect the page, make one careful move, and recover when the page changed.

Playwright can do many of those things, but it is not shaped around agent control:

- browser state usually lives inside a Playwright-managed session, not the already-open browser I am using
- snapshot refs are useful, but they go stale after meaningful UI changes
- simple browser questions often turn into ad hoc JavaScript or temporary scripts
- tab selection is mostly session or index based, which is easy for an agent to get wrong
- storage, screenshots, traces, and routing are strong, but they do not remember page-specific selector knowledge for the next agent run
- the workflow is optimized for automation engineers, not for a terminal agent repeatedly asking "what page am I on, what can I safely click, and what changed?"

Silmaril is my attempt to make the browser-control layer more agentic: JSON-first commands, explicit target control, visible-aware reads, count waits, snapshot refs, and local page memory.

## What It Does

Silmaril provides a local command layer over Chrome DevTools Protocol workflows, including:

- opening or attaching to a browser with CDP enabled
- navigating to pages
- listing, pinning, and resolving explicit browser targets
- reading DOM, text, and source
- capturing viewport snapshots with stable element refs such as `e1`, `e2`, `e3`
- querying structured page data
- clicking, typing, and updating page content
- waiting on browser state changes
- pinning and resolving the right browser tab

It also includes:

- a Codex / Claude skill install path
- JSON-friendly command output for agent workflows
- local page memory for reusable selectors, pitfalls, and playbooks
- visibility-aware query and count waits for feeds and result lists
- visible-first selector reads for `get-text`
- safer click and type behavior on pages with hidden duplicate controls
- selector normalization for common shell-damaged attribute selectors

## Agent-Focused Design

Silmaril is designed around problems that show up when a coding agent controls a browser:

- **Target drift:** `target-pin`, `target-show`, `target-clear`, `--target-id`, and `--url-match` help the agent keep acting on the intended tab instead of whichever tab happens to be active.
- **Hidden duplicate DOM:** visible-first `get-text`, DOM-first `get-dom`, `query --visible-only`, and visible count waits reduce mistakes on responsive pages with hidden mobile or desktop copies while keeping diagnostic markup inspectable.
- **State uncertainty:** commands return structured JSON with URL, title, match counts, visible counts, selected target, and actionability details where possible.
- **Repeated page work:** `page-memory` stores verified selectors, pitfalls, and playbooks so agents do not have to rediscover the same page every time.
- **Async UI changes:** explicit waits such as `wait-for-count`, `wait-for-visible-count`, `wait-for-gone`, `wait-for-any`, and `wait-for-mutation` keep the agent out of fixed sleeps.

## Quick Start

Install the skill on Windows:

```powershell
irm https://raw.githubusercontent.com/Malac12/silmaril-CDP-tools/main/install-skill.ps1 | iex
```

Install the skill on macOS:

```bash
curl -fsSL https://raw.githubusercontent.com/Malac12/silmaril-CDP-tools/main/install-skill.sh | bash
```

## Documentation

- Skill install: [INSTALL_SKILL.md](INSTALL_SKILL.md)
- Command guide: [COMMAND_GUIDE.md](COMMAND_GUIDE.md)
- macOS CLI: [MACOS_CLI.md](MACOS_CLI.md)

## Page Memory

Silmaril can store reusable page-specific knowledge locally so agents do not have to rediscover the same page behavior from scratch.

Examples:

```powershell
silmaril.cmd page-memory save --file "C:\path\record.json" --yes
silmaril.cmd page-memory lookup --json
silmaril.cmd page-memory verify --id lichess-round-v1 --json
silmaril.cmd page-memory list --json
```

This is intended for verified selectors, affordances, pitfalls, and playbooks, not raw DOM snapshots.

## Snapshot Refs

Silmaril can also capture a lightweight live page snapshot and assign short ref ids such as `e1`, `e2`, and `e27`.

Examples:

```powershell
silmaril.cmd snapshot --json
silmaril.cmd snapshot --coverage content --json
silmaril.cmd get-text "e12" --json
silmaril.cmd click "e27" --yes --json
silmaril.cmd scroll "e20" --json
silmaril.cmd query ".result-card a" --fields "text,href,visible" --visible-only --limit 20 --json
silmaril.cmd wait-for-visible-count ".result-card" --min-count 10 --json
```

Practical rules:

- `snapshot` defaults to `viewport` coverage. That mode captures what is meaningfully visible in the current viewport, not the entire page.
- `snapshot --coverage content` keeps the snapshot bounded but prefers richer content roots such as `main` and reaches further below the fold.
- On sticky-header or nav-heavy pages, a top-of-page snapshot may mostly contain header refs.
- If you want refs for deeper content such as a main feed, either scroll that content into view first or use `snapshot --coverage content`.
- Refs are for the latest snapshot on the current page target and port.
- After page-changing navigation or a meaningful page transition, run `snapshot` again before reusing refs.
- Ref-aware commands currently include `click`, `type`, `get-text`, `get-dom`, `exists`, `wait-for`, `wait-for-gone`, and `scroll`.

## Practical CLI Loop

The current default loop for messy public sites and SaaS-style pages is:

1. `query --visible-only` or `snapshot --coverage content` to discover the real content surface
2. `click` or `type`, which now prefers visible actionable or editable matches
3. `wait-for-visible-count` or `wait-for-count` instead of raw JS when the next state is list growth or async content load

Plain `query` remains DOM-order for full extraction. `get-text` is visible-first for user-facing reads, while `get-dom` remains DOM-first for markup debugging.

That keeps most interaction inside the normal selector/ref workflow and reduces the need to escalate into ad hoc DOM debugging.

## What Still Needs Work

Silmaril is not finished. The parts that matter most next are:

- clearer command semantics, especially around form controls versus text/HTML mutation
- stronger page-memory verification across redesigns, A/B tests, responsive layouts, and auth changes
- semantic control discovery, such as finding a button by role/name or a field by label before falling back to raw selectors
- better recovery hints when a pinned target closes, redirects, or becomes ambiguous
- dry-run actionability checks for every page-changing command
- richer debugging artifacts: screenshots, console summaries, network summaries, and lightweight traces
- broader interaction coverage, including hover, file upload, dialogs, keyboard chords, and drag/drop

The goal is not to out-Playwright Playwright. The goal is to make the browser command surface reliable enough that local agents can inspect, decide, act, verify, and remember.

## Positioning

Silmaril is not trying to replace Playwright for test suites or large automation systems.

It is for a different job:

- everyday browser tasks
- local authenticated browsing
- terminal-driven agent workflows
- flexible, human-supervised browser control

If you want to build a browser automation system, use Playwright.

If you want Codex or Claude to help with real browser work directly from the terminal, use Silmaril.
