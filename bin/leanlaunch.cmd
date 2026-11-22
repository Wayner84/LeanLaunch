@echo off
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\leanlaunch.ps1" %*
exit /b %ERRORLEVEL%
