@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-bridge-app.ps1" %*
exit /b %ERRORLEVEL%
