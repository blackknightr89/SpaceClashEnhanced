@echo off
rem Instalador de Space Clash para Windows 10/11 (doble clic). Ver README.md.
rem Pasa los argumentos a install-spaceclash.ps1, p.ej.:  install-spaceclash.cmd -Display Native
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-spaceclash.ps1" %*
echo.
pause
