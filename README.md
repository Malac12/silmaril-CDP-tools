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
- querying structured page data
- clicking, typing, and updating page content
- waiting on browser state changes
- pinning and resolving the right browser tab

It also includes:

- a Codex / Claude skill install path
- a local Electron bridge app
- JSON-friendly command output for agent workflows

## Quick Start

Install the skill:

```powershell
irm https://raw.githubusercontent.com/Malac12/silmaril-CDP-tools/main/install-skill.ps1 | iex
```

Install the Electron bridge app:

```powershell
irm https://raw.githubusercontent.com/Malac12/silmaril-CDP-tools/main/install-bridge-app.ps1 | iex
```

## Documentation

- Skill install: [INSTALL_SKILL.md](INSTALL_SKILL.md)
- Bridge app install: [INSTALL_BRIDGE_APP.md](INSTALL_BRIDGE_APP.md)
- Command guide: [COMMAND_GUIDE.md](COMMAND_GUIDE.md)

## Positioning

Silmaril is not trying to replace Playwright for test suites or large automation systems.

It is for a different job:

- everyday browser tasks
- local authenticated browsing
- terminal-driven agent workflows
- flexible, human-supervised browser control

If you want to build a browser automation system, use Playwright.

If you want Codex or Claude to help with real browser work directly from the terminal, use Silmaril.
