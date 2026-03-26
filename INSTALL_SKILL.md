# Install Silmaril Skill

This repository includes a Windows PowerShell installer that can install the `silmaril-cdp` skill into personal skill directories for Codex and Claude Code.

## One-command install

Install to both Codex and Claude Code:

```powershell
irm https://raw.githubusercontent.com/Malac12/silmaril-CDP-tools/main/install-skill.ps1 | iex
```

Install to Codex only:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/Malac12/silmaril-CDP-tools/main/install-skill.ps1))) -Target codex
```

Install to Claude Code only:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/Malac12/silmaril-CDP-tools/main/install-skill.ps1))) -Target claude
```

## Local install from a clone

From a local checkout of this repo:

```powershell
.\install-skill.ps1 -Target both
```

Or:

```powershell
.\install-skill.cmd
```

## What the installer does

- Reuses the current repo checkout when run locally.
- Otherwise installs the toolkit into `%USERPROFILE%\silmaril-cdp-tools` by default.
- Installs the skill into:
  - Codex: `%USERPROFILE%\.codex\skills\silmaril-cdp`
  - Claude Code: `%USERPROFILE%\.claude\skills\silmaril-cdp`
- Writes `LOCAL_PATHS.md` into the installed skill so the agent can find the exact local toolkit path.

## Useful options

```powershell
.\install-skill.ps1 -Target both -ToolkitDir "D:\tools\silmaril-cdp"
.\install-skill.ps1 -Target codex -Force
.\install-skill.ps1 -Target both -DryRun
.\install-skill.ps1 -Target both -SkipSmokeTest
```

## Notes

- This installer is Windows-first because the toolkit is currently PowerShell-based and uses Windows browser launch conventions.
- If `git` is unavailable, the installer falls back to downloading the GitHub ZIP archive.
- The installer does not require changing machine-wide PowerShell execution policy.
