# Install Silmaril Electron Bridge App

This repository includes a Windows PowerShell installer for the Electron bridge app under `bridge-app`.

## One-command install

```powershell
irm https://raw.githubusercontent.com/Malac12/silmaril-CDP-tools/main/install-bridge-app.ps1 | iex
```

## Local install from a clone

```powershell
.\install-bridge-app.ps1
```

Or:

```powershell
.\install-bridge-app.cmd
```

## What the installer does

- Reuses the current repo checkout when run locally.
- Otherwise installs the toolkit into `%USERPROFILE%\silmaril-cdp-tools` by default.
- Installs the `bridge-app` npm dependencies with `npm.cmd install`.
- Adds a simple launcher at `run-bridge-app.cmd`.

## Launch after install

```powershell
%USERPROFILE%\silmaril-cdp-tools\run-bridge-app.cmd
```

## Useful options

```powershell
.\install-bridge-app.ps1 -ToolkitDir "D:\tools\silmaril-cdp"
.\install-bridge-app.ps1 -Force
.\install-bridge-app.ps1 -SkipNpmInstall
.\install-bridge-app.ps1 -DryRun
```

## Notes

- This installer is Windows-first.
- Node.js and `npm.cmd` must already be installed.
- If `git` is unavailable, the installer falls back to downloading the GitHub ZIP archive.
