# Silmaril macOS CLI

This repository now includes a macOS CLI entrypoint for the core Silmaril toolkit.

## Scope

- Included: the PowerShell-based CLI toolkit and command surface
- Not included: the Electron bridge app
- First browser target: Google Chrome on macOS

## Prerequisites

- PowerShell 7 available as `pwsh`
- Google Chrome installed in `/Applications` or `~/Applications`
- Optional for proxy workflows: `mitmdump` on `PATH`

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
