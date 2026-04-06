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
