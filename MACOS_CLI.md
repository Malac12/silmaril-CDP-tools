# Silmaril macOS CLI

This repository now includes a macOS CLI entrypoint for the core Silmaril toolkit.

## Scope

- Included: the PowerShell-based CLI toolkit and command surface
- First browser target: Google Chrome on macOS

## Prerequisites

- PowerShell 7 available as `pwsh`
- Google Chrome installed in `/Applications` or `~/Applications`
- Optional for proxy workflows: `mitmdump` on `PATH`

## Install the skill

One-command install for Codex and Claude Code:

```bash
curl -fsSL https://raw.githubusercontent.com/Malac12/silmaril-CDP-tools/main/install-skill.sh | bash
```

Install from a local checkout:

```bash
chmod +x ./install-skill.sh
./install-skill.sh --target both
```

## Launch

From the repo root on a Mac:

```bash
bash ./silmaril-mac.sh openbrowser --json
```

Or after making the script executable:

```bash
chmod +x ./silmaril-mac.sh
./silmaril-mac.sh openbrowser --json
```

The macOS launcher delegates to `silmaril.ps1` through `pwsh` and preserves the existing command names and JSON contracts.

## Common Commands

The macOS launcher supports the same snapshot and ref workflow as the Windows CLI.

Examples:

```bash
./silmaril-mac.sh snapshot --json
./silmaril-mac.sh snapshot --coverage content --json
./silmaril-mac.sh get-text "e12" --json
./silmaril-mac.sh click "e27" --yes --json
```

Practical rules:

- `snapshot` defaults to `viewport` coverage and captures what is meaningfully visible in the current viewport.
- `snapshot --coverage content` stays bounded but prefers richer content roots such as `main` and reaches further below the fold.
- On sticky-header or nav-heavy pages, either scroll the content you care about into view first or use `snapshot --coverage content`.
- After page-changing navigation or a meaningful page transition, run `snapshot` again before reusing refs.

## Smoke Test

Run the bundled mac smoke script from PowerShell 7 on a Mac:

```bash
pwsh ./tests/Run-Mac-Smoke.ps1
```

That smoke flow validates:

- `openbrowser`
- `openurl`
- `wait-for`
- `get-text`
- `list-urls`
- `set-text`
- `eval-js`

