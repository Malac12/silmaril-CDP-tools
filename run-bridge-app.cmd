@echo off
setlocal
pushd "%~dp0bridge-app"
call npm.cmd start
set "exit_code=%ERRORLEVEL%"
popd
exit /b %exit_code%
