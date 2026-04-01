#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v pwsh >/dev/null 2>&1; then
  echo "pwsh was not found on PATH. Install PowerShell 7 to use Silmaril on macOS." >&2
  exit 1
fi

export SILMARIL_CLI_NAME="${SILMARIL_CLI_NAME:-./silmaril-mac.sh}"

exec pwsh -NoProfile -File "$SCRIPT_DIR/silmaril.ps1" "$@"
