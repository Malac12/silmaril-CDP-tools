@echo off
setlocal
set "SILMARIL_HOME=%~dp0"
if not exist "%SILMARIL_HOME%silmaril.ps1" (
  echo silmaril.ps1 not found at "%SILMARIL_HOME%".
  exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%SILMARIL_HOME%silmaril.ps1" %*
exit /b %ERRORLEVEL%
