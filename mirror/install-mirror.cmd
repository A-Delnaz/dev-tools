@echo off
rem Installs the update mirror on this PC. Right click > Run as administrator.
rem Remove it again:  install-mirror.cmd -Uninstall
chcp 65001 >nul
set "PSModulePath="
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-mirror.ps1" %*
pause
