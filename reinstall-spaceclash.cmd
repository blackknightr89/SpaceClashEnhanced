@echo off
rem Reinstalación completa de Space Clash para Windows 10/11 (doble clic). Ver README.md.
rem Rehace todo y configura como una instalación nueva: detecta otra vez la resolución del monitor,
rem scenh.ini de cero (el anterior queda en scenh.ini.anterior) y pregunta por los vídeos. Conserva las partidas.
rem Acepta las mismas opciones que install-spaceclash.cmd, p.ej.:  reinstall-spaceclash.cmd -Res off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-spaceclash.ps1" -Command reinstall %*
echo.
pause
