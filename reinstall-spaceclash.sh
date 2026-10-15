#!/usr/bin/env bash
# Reinstalación completa de Space Clash en Linux. Ver README.md.
# Rehace todo y configura como una instalación nueva: detecta otra vez la resolución del monitor, scenh.ini
# de cero (el anterior queda en scenh.ini.anterior) y pregunta por los vídeos. Conserva las partidas.
# Acepta las mismas opciones que install-spaceclash.sh, p. ej.:  ./reinstall-spaceclash.sh --res off
exec bash "$(dirname "${BASH_SOURCE[0]}")/install-spaceclash.sh" reinstall "$@"
