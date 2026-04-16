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

## What It Does

Silmaril provides a local command layer over Chrome DevTools Protocol workflows, including:

- opening or attaching to a browser with CDP enabled
- navigating to pages
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
```

Practical rules:

- `snapshot` defaults to `viewport` coverage. That mode captures what is meaningfully visible in the current viewport, not the entire page.
- `snapshot --coverage content` keeps the snapshot bounded but prefers richer content roots such as `main` and reaches further below the fold.
- On sticky-header or nav-heavy pages, a top-of-page snapshot may mostly contain header refs.
- If you want refs for deeper content such as a main feed, either scroll that content into view first or use `snapshot --coverage content`.
- Refs are for the latest snapshot on the current page target and port.
- After page-changing navigation or a meaningful page transition, run `snapshot` again before reusing refs.
- Ref-aware commands currently include `click`, `type`, `get-text`, `get-dom`, `exists`, `wait-for`, `wait-for-gone`, and `scroll`.

## Positioning

Silmaril is not trying to replace Playwright for test suites or large automation systems.

It is for a different job:

- everyday browser tasks
- local authenticated browsing
- terminal-driven agent workflows
- flexible, human-supervised browser control

If you want to build a browser automation system, use Playwright.

If you want Codex or Claude to help with real browser work directly from the terminal, use Silmaril.
