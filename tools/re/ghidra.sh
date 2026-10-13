#!/usr/bin/env bash
# ghidra.sh — crea o actualiza el proyecto Ghidra de Space Clash en modo headless.
#
#   tools/re/ghidra.sh import CARPETA_CON_LOS_EXE   # importa CLASH.EXE y SPACE.EXE originales y los analiza
#   tools/re/ghidra.sh symbols                      # vuelve a aplicar re/symbols.csv
#   tools/re/ghidra.sh decompile SALIDA_DIR         # exporta el pseudo-C de ambos EXE (para grep)
#
# El proyecto queda en re/proyecto/ (excluido de git: contiene los binarios). Abrirlo en la GUI con
# File → Open Project → re/proyecto/SpaceClash.gpr. Variables: GHIDRA_HOME (por defecto /opt/ghidra).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ghidra="${GHIDRA_HOME:-/opt/ghidra}"
headless="$ghidra/support/analyzeHeadless"
proj_dir="$here/re/proyecto"
proj=SpaceClash
scripts="$here/re/ghidra"
[[ -x "$headless" ]] || { echo "No encuentro $headless (definí GHIDRA_HOME)" >&2; exit 1; }

# SHA-256 de los EXE del CD español: solo se analizan los originales sin parchear
declare -A SHA=(
  [CLASH.EXE]=78fb6b3f8cf44887e76dd731e96b13a12cbca3bd5378c49dc8a9a8ae798ce8dc
  [SPACE.EXE]=755e60f6f820377b45088841fd109174071b97e96c361cc40424dcaf87201cba
)

find_ci() { find "$1" -maxdepth 1 -iname "$2" -print -quit; }

case "${1:-}" in
  import)
    src="${2:?falta la carpeta con CLASH.EXE y SPACE.EXE}"
    mkdir -p "$proj_dir"
    for exe in CLASH.EXE SPACE.EXE; do
      f="$(find_ci "$src" "$exe")"
      [[ -n "$f" ]] || { echo "Falta $exe en $src" >&2; exit 1; }
      if [[ -n "${SHA[$exe]:-}" ]] && [[ "$(sha256sum "$f" | cut -d' ' -f1)" != "${SHA[$exe]}" ]]; then
        echo "$f no es el $exe original del CD (¿parcheado?): usá el del CD o el .ORIG" >&2; exit 1
      fi
      "$headless" "$proj_dir" "$proj" -import "$f" -overwrite \
        -scriptPath "$scripts" -postScript ImportScSymbols.java
    done ;;
  symbols)
    "$headless" "$proj_dir" "$proj" -process -noanalysis -scriptPath "$scripts" -postScript ImportScSymbols.java ;;
  decompile)
    out="${2:?falta la carpeta de salida}"
    mkdir -p "$out"
    for exe in CLASH.EXE SPACE.EXE; do
      "$headless" "$proj_dir" "$proj" -process "$exe" -noanalysis -readOnly \
        -scriptPath "$scripts" -postScript ExportDecompiled.java "$(realpath "$out")/${exe%.EXE}.c"
    done ;;
  *)
    sed -n '2,10p' "$0" >&2; exit 2 ;;
esac
