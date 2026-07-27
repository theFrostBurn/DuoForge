@echo off
setlocal
pwsh.exe -NoLogo -NoProfile -File "%~dp0duoforge.ps1" %*
exit /b %ERRORLEVEL%
