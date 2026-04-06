# Install Silmaril Skill

This repository includes installers that can install the `silmaril-cdp` skill into personal skill directories for Codex and Claude Code.

## One-command install

Windows PowerShell, install to both Codex and Claude Code:

```powershell
irm https://raw.githubusercontent.com/Malac12/silmaril-CDP-tools/main/install-skill.ps1 | iex
```

Windows PowerShell, install to Codex only:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/Malac12/silmaril-CDP-tools/main/install-skill.ps1))) -Target codex
```

Windows PowerShell, install to Claude Code only:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/Malac12/silmaril-CDP-tools/main/install-skill.ps1))) -Target claude
```

macOS shell, install to both Codex and Claude Code:

```bash
curl -fsSL https://raw.githubusercontent.com/Malac12/silmaril-CDP-tools/main/install-skill.sh | bash
```

macOS shell, install to Codex only:

```bash
curl -fsSL https://raw.githubusercontent.com/Malac12/silmaril-CDP-tools/main/install-skill.sh | bash -s -- --target codex
```

macOS shell, install to Claude Code only:

```bash
curl -fsSL https://raw.githubusercontent.com/Malac12/silmaril-CDP-tools/main/install-skill.sh | bash -s -- --target claude
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

On macOS:

```bash
chmod +x ./install-skill.sh
./install-skill.sh --target both
```

## What the installer does

- Reuses the current repo checkout when run locally.
- Otherwise installs the toolkit into `%USERPROFILE%\silmaril-cdp-tools` on Windows or `~/silmaril-cdp-tools` on macOS by default.
- Installs the skill into:
  - Codex: `%USERPROFILE%\.codex\skills\silmaril-cdp`
  - Claude Code: `%USERPROFILE%\.claude\skills\silmaril-cdp`
- On macOS, installs the skill into:
  - Codex: `~/.codex/skills/silmaril-cdp`
  - Claude Code: `~/.claude/skills/silmaril-cdp`
- Writes `LOCAL_PATHS.md` into the installed skill so the agent can find the exact local toolkit path and launcher.

## Useful options

```powershell
.\install-skill.ps1 -Target both -ToolkitDir "D:\tools\silmaril-cdp"
.\install-skill.ps1 -Target codex -Force
.\install-skill.ps1 -Target both -DryRun
.\install-skill.ps1 -Target both -SkipSmokeTest
```

```bash
./install-skill.sh --target both --toolkit-dir "$HOME/tools/silmaril-cdp"
./install-skill.sh --target codex --force
./install-skill.sh --target both --dry-run
./install-skill.sh --target both --skip-smoke-test
```

## Notes

- This installer is Windows-first because the toolkit is currently PowerShell-based and uses Windows browser launch conventions.
- If `git` is unavailable, the installer falls back to downloading the GitHub ZIP archive.
- The installer does not require changing machine-wide PowerShell execution policy.
- On macOS, the installer copies the toolkit and skill, but running Silmaril still requires PowerShell 7 available as `pwsh`.
