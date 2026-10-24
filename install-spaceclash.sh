#!/usr/bin/env bash
# =============================================================================
#  install-spaceclash.sh — Instalador automatizado de "Space Clash: The Last
#  Frontier" (Dinamic Multimedia / Enigma Software, 1999) para Linux + Wine.
#
#  Plataforma objetivo: CachyOS / Arch Linux (Wine >= 9 en modo WoW64).
#  Documentación para usuarios: README.md
#
#  Uso rápido:
#     ./install-spaceclash.sh install            # instala todo
#     ./install-spaceclash.sh reinstall          # reinstalación completa (vuelve a detectar el monitor)
#     ./install-spaceclash.sh run                # ejecuta el juego
#     ./install-spaceclash.sh doctor             # diagnóstico
#     ./install-spaceclash.sh uninstall          # elimina la instalación
#     ./install-spaceclash.sh help               # todas las opciones
# =============================================================================
set -Eeuo pipefail

# --------------------------------------------------------------------------- #
#  Configuración (todo se puede sobreescribir con variables de entorno)
# --------------------------------------------------------------------------- #
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SC_ROOT="${SC_ROOT:-$HOME/Games/space-clash}"           # raíz de la instalación
SC_DISK_DIR="${SC_DISK_DIR:-$SCRIPT_DIR/disk}"          # dónde están .bin/.cue
SC_IMAGE="${SC_IMAGE:-${SC_BIN:-}}"                     # .cue/.bin/.iso (vacío = buscar en disk/)
SC_WINE="${SC_WINE:-wine}"                              # binario de wine a usar
SC_DISPLAY="${SC_DISPLAY:-scaled}"                      # scaled (pantalla completa 4:3 escalada) | window (ventana tamaño original)
SC_RENDERER="${SC_RENDERER:-opengl}"                    # renderer de cnc-ddraw en modo scaled: opengl | gdi | auto
SC_SCALING="${SC_SCALING:-fit}"                         # scaled: fit (llenar el alto, 4:3) | integer (solo factores enteros, más borde)
SC_FILTER="${SC_FILTER:-auto}"                          # scaled+opengl: auto | nearest | sharp | smooth | xbr | crt
SC_GAME_RES="${SC_GAME_RES:-auto}"                      # resolución del juego (CLASH.CFG): auto (1024 al instalar de cero, si no keep) | keep | 640 | 800 | 1024
SC_PATCH="${SC_PATCH:-1}"                               # 1 = aplicar parches de compatibilidad (ver sección 5b)
SC_RES="${SC_RES:-auto}"                                # pantalla panorámica: auto (la del monitor al instalar de cero) | WxH | off
SC_RUNTIME="${SC_RUNTIME:-1}"                           # 1 = runtime de mejoras scenh.dll (velocidad, avisos…; sección 5c)
SC_VDESKTOP="${SC_VDESKTOP:-1}"                         # 1 = ejecutar en escritorio virtual de Wine
SC_VDESKTOP_RES="${SC_VDESKTOP_RES:-auto}"              # tamaño del escritorio virtual (auto = monitor en scaled, 1024x768 en window)
SC_GAMESCOPE="${SC_GAMESCOPE:-0}"                       # 1 = envolver con gamescope (escalado a pantalla completa)
SC_FULL="${SC_FULL:-0}"                                 # 1 = copiar música y vídeos al disco
SC_VIDEOS="${SC_VIDEOS:-ask}"                           # ask (preguntar; al reinstalar, lo elegido) | fit (vídeos 4:3 con barras) | original
SC_VIDEOS_AI="${SC_VIDEOS_AI:-ask}"                     # ask (preguntar, def. no) | off | general | general-sharp | x4plus: vídeos con IA
SC_PYTHON="${SC_PYTHON:-}"                              # Python con torch + spandrel (vacío = buscarlo; ver setup_videos_ai)
SC_DESKTOP="${SC_DESKTOP:-1}"                           # 1 = crear acceso directo .desktop
SC_STEAM="${SC_STEAM:-1}"                               # 1 = agregar a la biblioteca de Steam (si está instalado)
SC_CD_LETTER="${SC_CD_LETTER:-r}"                       # letra del CD virtual (R:; S:/T: las reserva Proton)
SC_CNC_URL="${SC_CNC_URL:-https://github.com/FunkyFr3sh/cnc-ddraw/releases/download/v7.1.0.0/cnc-ddraw.zip}"

# Hash SHA-256 conocido de la imagen (Space Clash (Spain).bin, 791527968 bytes)
SC_BIN_SHA256="a0d007d205f83c3307294b5d8211eca588361584dba986010b6516efe0bc2e10"
SC_ISO_SHA256="88f14eb7c20cef85b5ba563b1127b821419159ac057b0999cce22f0944889c0b"   # misma imagen ya convertida a .iso

# Rutas derivadas
ISO_PATH="$SC_ROOT/media/SPACE_CLASH.iso"
CD_DIR="$SC_ROOT/cd"                         # contenido del CD → unidad R: (tipo cdrom)
export WINEPREFIX="$SC_ROOT/prefix"
GAME_DIR="$WINEPREFIX/drive_c/SCLASH"        # misma ruta por defecto que el instalador original
LAUNCHER="$SC_ROOT/spaceclash.sh"
LOG_DIR="$SC_ROOT/logs"
DESKTOP_FILE="$HOME/.local/share/applications/space-clash.desktop"
DESKTOP_FILE_NV="$HOME/.local/share/applications/space-clash-sin-videos.desktop"   # sin vídeos de inicio
NOVID_DIR="$SC_ROOT/cd-sin-videos"           # vista del CD sin LOGO/DINAMIC/INTRO (la arma el lanzador)
ICON_FILE="$HOME/.local/share/icons/hicolor/48x48/apps/space-clash.png"

export WINEDEBUG="${WINEDEBUG:--all}"

# --------------------------------------------------------------------------- #
#  Utilidades
# --------------------------------------------------------------------------- #
c_info=$'\e[1;34m'; c_ok=$'\e[1;32m'; c_warn=$'\e[1;33m'; c_err=$'\e[1;31m'; c_off=$'\e[0m'
[[ -t 1 ]] || { c_info=; c_ok=; c_warn=; c_err=; c_off=; }

log()  { printf '%s==>%s %s\n' "$c_info" "$c_off" "$*"; }
ok()   { printf '%s ok%s %s\n'  "$c_ok"   "$c_off" "$*"; }
warn() { printf '%s !!%s %s\n'  "$c_warn" "$c_off" "$*" >&2; }
die()  { printf '%sERROR:%s %s\n' "$c_err" "$c_off" "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

trap 'die "falló el comando en la línea $LINENO: $BASH_COMMAND"' ERR

wine_q() { "$SC_WINE" "$@" >/dev/null 2>&1; }   # wine silencioso

# --------------------------------------------------------------------------- #
#  1. Dependencias
# --------------------------------------------------------------------------- #
# Paquetes de Arch/CachyOS necesarios (Wine >= 9 de Arch es WoW64 puro: NO hace
# falta ningún paquete lib32-* para ejecutar este juego de 32 bits).
PACMAN_PKGS=(wine 7zip python unzip curl imagemagick ffmpeg
             gst-plugins-base gst-plugins-good gst-plugins-bad gst-plugins-ugly gst-libav)
# Ubuntu/Debian: el Wine de Ubuntu 24.04 (9.0) no es WoW64, así que el juego de 32 bits necesita wine32
# (arquitectura i386) y los plugins de GStreamer de 32 bits para los vídeos (winegstreamer de 32 bits).
APT_PKGS=(wine wine64 wine32:i386 7zip python3 unzip curl imagemagick ffmpeg x11-xserver-utils
          gstreamer1.0-plugins-base:i386 gstreamer1.0-plugins-good:i386 gstreamer1.0-plugins-bad:i386
          gstreamer1.0-plugins-ugly:i386 gstreamer1.0-libav:i386)

pkg_family() {   # arch | apt | otra
    if have pacman; then echo arch; elif have apt-get && have dpkg-query; then echo apt; else echo otra; fi
}
as_root() { if ((EUID == 0)); then "$@"; else sudo "$@"; fi; }
deps_cmd() {     # comando para instalar todas las dependencias en esta distribución
    case "$(pkg_family)" in
        arch) echo "sudo pacman -S --needed ${PACMAN_PKGS[*]}" ;;
        apt)  echo "sudo dpkg --add-architecture i386 && sudo apt update && sudo apt install ${APT_PKGS[*]}" ;;
        *)    echo "Wine >= 9 (con soporte de 32 bits), 7-Zip, Python 3, unzip, curl, ffmpeg y los plugins de GStreamer (base, good, bad, ugly, libav)" ;;
    esac
}
pkg_hint() {     # pkg_hint ffmpeg|mingw → comando para instalar solo eso
    case "$(pkg_family):$1" in
        arch:ffmpeg) echo "sudo pacman -S ffmpeg" ;;
        apt:ffmpeg)  echo "sudo apt install ffmpeg" ;;
        arch:mingw)  echo "sudo pacman -S mingw-w64-gcc" ;;
        apt:mingw)   echo "sudo apt install gcc-mingw-w64-i686" ;;
        *:ffmpeg)    echo "instalá ffmpeg" ;;
        *:mingw)     echo "instalá MinGW-w64 para i686" ;;
    esac
}
apt_missing() {  # imprime los paquetes de la lista que no están instalados
    local p
    for p in "$@"; do
        [[ "$(dpkg-query -W -f='${Status}' "$p" 2>/dev/null)" == "install ok installed" ]] || echo "$p"
    done
}
install_deps() {
    case "$(pkg_family)" in
        arch)
            log "Instalando dependencias con pacman (pedirá contraseña de sudo)…"
            as_root pacman -S --needed "${PACMAN_PKGS[@]}" ;;
        apt)
            log "Instalando dependencias con apt (pedirá contraseña de sudo)…"
            dpkg --print-foreign-architectures | grep -qx i386 || as_root dpkg --add-architecture i386
            as_root apt-get update
            as_root apt-get install -y "${APT_PKGS[@]}" ;;
        *) die "No sé instalar dependencias en esta distribución. Instalá: $(deps_cmd)" ;;
    esac
}

check_deps() {
    local missing=() fam
    fam=$(pkg_family)
    for bin in "$SC_WINE" 7z python3 unzip curl; do
        have "$bin" || missing+=("$bin")
    done
    # Ubuntu/Debian con el Wine del sistema: sin wine32 el juego (32 bits) no arranca
    if [[ "$fam" == apt && "$SC_WINE" == wine ]] && [[ -n "$(apt_missing wine32:i386)" ]]; then
        missing+=("wine32:i386")
    fi
    if ((${#missing[@]})); then
        warn "Faltan: ${missing[*]}"
        if [[ "${INSTALL_DEPS:-0}" == 1 ]]; then
            install_deps
        else
            die "Instalá las dependencias: $(deps_cmd)
       (o re-ejecutá con --install-deps)"
        fi
    fi
    # GStreamer: necesario para los vídeos MPEG-1 (DirectShow → winegstreamer)
    if [[ "$fam" == apt && "$SC_WINE" == wine ]]; then
        local gst
        gst=$(apt_missing gstreamer1.0-plugins-bad:i386 gstreamer1.0-libav:i386 gstreamer1.0-plugins-ugly:i386 | tr '\n' ' ')
        [[ -z "$gst" ]] || warn "Faltan plugins de GStreamer de 32 bits ($gst): los vídeos podrían no reproducirse. sudo apt install $gst"
    elif have gst-inspect-1.0; then
        gst-inspect-1.0 mpegpsdemux >/dev/null 2>&1 || warn "Falta el plugin GStreamer 'mpegpsdemux' (gst-plugins-bad). Los vídeos podrían no reproducirse."
        gst-inspect-1.0 mpeg2dec     >/dev/null 2>&1 || gst-inspect-1.0 avdec_mpeg2video >/dev/null 2>&1 \
            || warn "Falta decodificador MPEG-1 (gst-libav o gst-plugins-ugly). Los vídeos podrían no reproducirse."
    else
        warn "gst-inspect-1.0 no encontrado: no se puede verificar GStreamer (vídeos)."
    fi
    if [[ "$SC_DISPLAY" == scaled && "$SC_VIDEOS" == fit ]] && ! have ffmpeg; then
        warn "Falta ffmpeg ($(pkg_hint ffmpeg)): sin él los vídeos se verán estirados a lo ancho."
    fi
    ok "Dependencias: $("$SC_WINE" --version 2>/dev/null)"
}

# --------------------------------------------------------------------------- #
#  2. Imagen de disco: verificación + conversión BIN/CUE (MODE1/2352) → ISO
# --------------------------------------------------------------------------- #
# Busca la imagen: --image/SC_IMAGE, o el primer .cue, .bin o .iso dentro de disk/ (cualquier nombre).
resolve_image() {
    local img=$SC_IMAGE f
    if [[ -z "$img" ]]; then
        local cues bins isos
        shopt -s nullglob nocaseglob
        cues=("$SC_DISK_DIR"/*.cue); bins=("$SC_DISK_DIR"/*.bin); isos=("$SC_DISK_DIR"/*.iso)
        shopt -u nullglob nocaseglob
        if   ((${#cues[@]})); then img=${cues[0]}
        elif ((${#bins[@]})); then img=${bins[0]}
        elif ((${#isos[@]})); then img=${isos[0]}
        else die "No encontré la imagen del juego. Copiá el .bin + .cue (o la .iso) de tu CD de Space Clash en: $SC_DISK_DIR"
        fi
    fi
    [[ -f "$img" ]] || die "No encuentro la imagen: $img"
    SC_BIN=""; SC_ISO_SRC=""
    case "${img,,}" in
        *.cue)
            grep -q "MODE1/2352" "$img" || die "El .cue no es una pista de datos MODE1/2352; no está soportado."
            f=$(sed -nE 's/^[[:space:]]*FILE[[:space:]]+"([^"]+)".*/\1/p' "$img" | head -1)
            [[ -n "$f" ]] || die "El .cue no indica el archivo .bin (línea FILE)."
            SC_BIN="$(dirname "$img")/$f"
            [[ -f "$SC_BIN" ]] || die "El .cue apunta a \"$f\", que no está junto al .cue." ;;
        *.bin) SC_BIN=$img ;;
        *.iso) SC_ISO_SRC=$img ;;
        *) die "Formato de imagen no soportado: $img (usá .cue/.bin o .iso)" ;;
    esac
    ok "Imagen: ${SC_BIN:-$SC_ISO_SRC}"
}

verify_image() {
    resolve_image
    if [[ "${SKIP_HASH:-0}" != 1 ]]; then
        log "Verificando SHA-256 de la imagen (puede tardar unos segundos)…"
        local h; h=$(sha256sum "${SC_BIN:-$SC_ISO_SRC}" | cut -d' ' -f1)
        if [[ "$h" == "$SC_BIN_SHA256" || "$h" == "$SC_ISO_SHA256" ]]; then ok "Imagen verificada"
        else warn "Hash distinto al esperado ($h). Puede ser otra edición; se continúa igualmente."; fi
    fi
}

bin_to_iso() {
    if [[ -n "${SC_ISO_SRC:-}" ]]; then ISO_PATH=$SC_ISO_SRC; ok "Se usa la ISO tal cual"; return; fi
    if [[ -f "$ISO_PATH" && "${FORCE:-0}" != 1 ]]; then ok "ISO ya existe: $ISO_PATH"; return; fi
    mkdir -p "$(dirname "$ISO_PATH")"
    log "Convirtiendo BIN (2352 bytes/sector) → ISO (2048 bytes/sector)…"
    python3 - "$SC_BIN" "$ISO_PATH.part" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
SECTOR, HDR, DATA = 2352, 16, 2048          # MODE1: 12 sync + 4 header + 2048 datos + 288 EDC/ECC
CHUNK = 512                                 # sectores por lectura
with open(src, 'rb') as f, open(dst, 'wb') as o:
    while True:
        buf = f.read(SECTOR * CHUNK)
        if not buf:
            break
        n = len(buf) // SECTOR
        o.write(b''.join(buf[i*SECTOR+HDR:i*SECTOR+HDR+DATA] for i in range(n)))
PY
    mv "$ISO_PATH.part" "$ISO_PATH"
    7z l "$ISO_PATH" 2>/dev/null | grep -q "UNCLASH.EXE" || die "La ISO generada no parece válida."
    ok "ISO generada: $ISO_PATH ($(du -h "$ISO_PATH" | cut -f1))"
}

# --------------------------------------------------------------------------- #
#  3. "CD virtual": contenido de la ISO en un directorio mapeado como R: (cdrom)
# --------------------------------------------------------------------------- #
#  SC.EXE (lanzador) recorre las unidades, busca una de tipo DRIVE_CDROM que
#  contenga \UNCLASH.EXE y escribe su raíz (p.ej. "R:\") en CDSC.INS. CLASH.EXE lee
#  después la música de <letra>:\Musicas y los vídeos de <letra>:\Videos.
#  No hay chequeo de etiqueta de volumen ni protección física, así que un
#  directorio declarado como "cdrom" en Wine es suficiente.
#  Se usa R: y no D: porque el mountmgr de Wine asigna automáticamente D:, E:…
#  a los dispositivos removibles del host (lectores de tarjetas, USB) y borra
#  cualquier enlace manual en esas letras al arrancar. Tampoco S:/T:, que Proton
#  reserva (gamedrive/steamdrive) y borra en cada arranque.
extract_cd() {
    if [[ -f "$CD_DIR/UNCLASH.EXE" && "${FORCE:-0}" != 1 ]]; then ok "CD ya extraído en $CD_DIR"; return; fi
    log "Extrayendo el contenido del CD en $CD_DIR…"
    rm -rf "$CD_DIR"; mkdir -p "$CD_DIR"
    7z x -y -o"$CD_DIR" "$ISO_PATH" >/dev/null
    printf 'SPACE_CLASH' > "$CD_DIR/.windows-label"   # etiqueta de volumen original
    ok "CD extraído ($(du -sh "$CD_DIR" | cut -f1))"
}

# --------------------------------------------------------------------------- #
#  4. Prefijo de Wine
# --------------------------------------------------------------------------- #
create_prefix() {
    if [[ -f "$WINEPREFIX/system.reg" && "${FORCE:-0}" != 1 ]]; then
        ok "Prefijo existente: $WINEPREFIX"
    else
        log "Creando prefijo de Wine en $WINEPREFIX…"
        mkdir -p "$WINEPREFIX"
        # mscoree/mshtml vacíos: evita los diálogos de descarga de Mono/Gecko (no hacen falta)
        WINEDLLOVERRIDES="mscoree=;mshtml=" "$SC_WINE" wineboot --init >/dev/null 2>&1 || true
        "$SC_WINE"server -w 2>/dev/null || wineserver -w
        [[ -f "$WINEPREFIX/system.reg" ]] || die "wineboot no creó el prefijo."
        ok "Prefijo creado"
    fi

    local L="${SC_CD_LETTER,,}"
    log "Configurando Windows XP y unidad ${L^^}: (CD-ROM virtual)…"
    wine_q reg add 'HKCU\Software\Wine' /v Version /d winxp /f
    # Unidad R: → directorio del CD, declarada como CD-ROM (GetDriveType == 5)
    # Quitar mapeos del CD en otras letras (p.ej. S: de versiones anteriores del script)
    local link old
    for link in "$WINEPREFIX"/dosdevices/?:; do
        old=$(basename "$link"); old=${old%:}
        if [[ "$old" != "$L" && "$(readlink "$link")" == "$CD_DIR" ]]; then
            rm -f "$link"; wine_q reg delete 'HKLM\Software\Wine\Drives' /v "$old:" /f || true
            wine_q reg delete 'HKLM\Software\Wine\Drives' /v "$old:" /f /reg:64 || true
            log "Quitado el mapeo anterior del CD en ${old^^}:"
        fi
    done
    ln -sfn "$CD_DIR" "$WINEPREFIX/dosdevices/$L:"
    wine_q reg add 'HKLM\Software\Wine\Drives' /v "$L:" /d cdrom /f
    # También en la vista de 64 bits: con un Wine que no es WoW64 (Ubuntu/Debian), "wine reg" es el de 32
    # bits y escribe en Wow6432Node, pero el tipo de unidad lo decide el mountmgr de 64 bits
    wine_q reg add 'HKLM\Software\Wine\Drives' /v "$L:" /d cdrom /f /reg:64 || true
    # El juego no es Unicode y usa la página de códigos 1252 (español)
    wine_q reg add 'HKCU\Control Panel\International' /v Locale /d 00000c0a /f || true
    "$SC_WINE"server -w 2>/dev/null || wineserver -w
    # Verificación: arrancar Wine de nuevo y comprobar que el mountmgr no borró la unidad
    "$SC_WINE" cmd /c "dir $L:\\UNCLASH.EXE" >/dev/null 2>&1 \
        && [[ -L "$WINEPREFIX/dosdevices/$L:" ]] \
        || die "La unidad ${L^^}: no quedó mapeada (¿la ocupa un dispositivo del host?). Probá con --cd-letter q"
    ok "Prefijo configurado (CD virtual en ${L^^}:)"
}

# --------------------------------------------------------------------------- #
#  5. Instalación de los archivos del juego (réplica de INSTALAR.EXE / SC.NFO)
# --------------------------------------------------------------------------- #
#  No se ejecuta INSTALAR.EXE porque instala DirectX 6 y ActiveMovie 1.0, que
#  sobreescribirían las DLL de Wine y romperían el prefijo. En su lugar se
#  replica la lista de SC.NFO: F = archivo, X = directorio, D = crear dir,
#  "*" = solo en instalación completa (música y vídeos; el juego los lee del CD).
# Partidas (*.sav), su índice (*.nfo) y las opciones del juego (CLASH.CFG): lo que uninstall copia a
# ../space-clash-partidas-<fecha> y una instalación de cero ofrece restaurar.
SAVE_GLOBS=('*.sav' '*.nfo' 'CLASH.CFG')

restore_saves() {
    local f backups=() last a
    [[ -f "$GAME_DIR/CLASH.CFG" ]] && return
    for f in "$GAME_DIR"/*.sav; do [[ -f "$f" ]] && return; done
    for f in "$(dirname "$SC_ROOT")"/space-clash-partidas-*/; do [[ -d "$f" ]] && backups+=("${f%/}"); done
    ((${#backups[@]})) || return 0
    last=${backups[-1]}                       # el glob ordena por nombre = por fecha
    read -r -p "Hay una copia de tus partidas en $last. ¿Restaurarla? [S/n] " a || a=""
    [[ "$a" =~ ^[nN]$ ]] && { echo "    Sin restaurar (la copia sigue en $last)"; return; }
    cp -p "$last"/* "$GAME_DIR/"
    ok "Partidas restauradas desde $last"
}

install_files() {
    log "Copiando archivos del juego a $GAME_DIR…"
    mkdir -p "$GAME_DIR"
    local f d
    restore_saves
    for f in SC.EXE CLASH.EXE SPACE.EXE UNCLASH.EXE \
             PALCF.DAT PALCS.DAT PALS.DAT PALT020.DAT PALT030.DAT PALT040.DAT ICON.ICO; do
        install -m 0644 "$CD_DIR/$f" "$GAME_DIR/$f"
    done
    # Opciones del juego: solo la primera vez (una reinstalación conserva las del usuario).
    # Las partidas (*.sav) nunca se tocan.
    if [[ ! -f "$GAME_DIR/CLASH.CFG" ]]; then
        install -m 0644 "$CD_DIR/CLASH.CFG" "$GAME_DIR/CLASH.CFG"; NEW_CFG=1
    fi
    install -m 0644 "$CD_DIR/MANUAL/MANUAL.PDF" "$GAME_DIR/MANUAL.PDF"
    for d in EFECTOS IMG LOCU MAPAS SPC SPR; do
        rm -rf "${GAME_DIR:?}/$d"; cp -r "$CD_DIR/$d" "$GAME_DIR/$d"
    done
    if [[ "$SC_FULL" == 1 ]]; then
        for d in MUSICAS VIDEOS; do rm -rf "${GAME_DIR:?}/$d"; cp -r "$CD_DIR/$d" "$GAME_DIR/$d"; done
    fi
    log "Descomprimiendo animaciones (ANI.ZIP, 361 archivos FLC)…"
    rm -rf "$GAME_DIR/ANI"; mkdir -p "$GAME_DIR/ANI"
    unzip -q -o "$CD_DIR/ANI.ZIP" -d "$GAME_DIR/ANI"
    chmod -R u+w "$GAME_DIR"

    # Claves de registro equivalentes a las que crea el instalador original
    wine_q reg add 'HKLM\Software\Dinamic Multimedia\Instalar\Space Clash' /v Path /d 'C:\SCLASH' /f || true
    ok "Juego instalado ($(du -sh "$GAME_DIR" | cut -f1))"
}

# --------------------------------------------------------------------------- #
#  5b. Parches de compatibilidad (bugs del juego original)
# --------------------------------------------------------------------------- #
#  P1 (CLASH.EXE y SPACE.EXE) — chequeo de procesos roto.
#     CLASH.EXE exige un proceso "SC.EXE" y SPACE.EXE uno "CLASH.EXE", usando
#     Process32First sin inicializar PROCESSENTRY32.dwSize (basura de pila). En
#     9x/XP funcionaba de casualidad; en Wine falla siempre ("Para jugar a Space
#     Clash debes ejecutar SC.EXE"). Se cambia jne (75) por jmp (EB).
#  P2 (SPACE.EXE) — desborde de la superficie DirectDraw al iniciar.
#     SPACE.EXE arranca en 640x480 pero deja ancho/alto en 1024x768 (tamaño de
#     reserva de búferes) y presenta la pantalla de carga con esas medidas:
#     copia 786 432 bytes a un backbuffer de 307 200. En las placas de 1999 el
#     exceso caía en VRAM contigua; en Wine la superficie está en RAM → crash en
#     0x420F23. Se reemplaza el bloque que muestra la pantalla de carga
#     (0x40E2FD, 18 bytes) por "ancho=640; alto=480" (coherente con el modo).
#  P3 (SPACE.EXE) — mismo desborde al cambiar de resolución (0x420DE0).
#     Borra la pantalla dos veces con las medidas NUEVAS (p.ej. 800x600) antes
#     de cambiar el modo (superficie aún 640x480) → crash en 0x420F7D. Los dos
#     borrados son cosméticos (el cambio de modo recrea las superficies): NOP.
#  P4 (SPACE.EXE) — red de seguridad general para el mismo bug (7 sitios).
#     Las funciones que presentan/borran/copian la pantalla (0x420EF0, 0x420F50,
#     0x420F9x, 0x420FEx, bucle de render del mapa estelar 0x41CC70, 0x4211B7,
#     0x42123A) calculan los bytes como ancho×alto DEL JUEGO, que puede no
#     coincidir con la superficie (p.ej. al volver de una misión: SPACE.EXE
#     arranca en 640x480, carga esp.sav con 800x600 y presenta la pantalla de
#     carga antes de cambiar de modo → crash en 0x420F23). Se reemplaza
#     "movsx ecx,[alto]; movsx edx,[ancho]; imul ecx,edx" (17 B) por
#     "mov ecx,[desc.dwHeight]; imul ecx,[desc.lPitch]; nop×4": el tamaño REAL
#     de la superficie que devolvió Lock (DDSURFACEDESC en 0x467668).
#
#  Formato: ARCHIVO|sha256_original|sha256_final|offset:bytes_orig:bytes_nuevos ...
PATCHES=(
  "CLASH.EXE|78fb6b3f8cf44887e76dd731e96b13a12cbca3bd5378c49dc8a9a8ae798ce8dc|0d7249b71fddbe7ae21384ffa4d04dedcddda8bfddc60e64f319ec0e09cbf507|0x15206:75:eb"
  "SPACE.EXE|755e60f6f820377b45088841fd109174071b97e96c361cc40424dcaf87201cba|11cf4fd0865fcd813063565fb972176ae00c748509b1bddd1eab36e746526a93|0x0df86:75:eb 0x0d6fd:e8ee2b010085c07509e8e52b010085c074f7:66c705907081008002 0x0d706::66c70592708100e001 0x201e1:e86a010000:9090909090 0x201eb:e860010000:9090909090 0x1c070:0fbf0d927081000fbf15907081000fafca:8b0d707646000faf0d7876460090909090 0x20303:0fbf0d927081000fbf15907081000fafca:8b0d707646000faf0d7876460090909090 0x20365:0fbf0d927081000fbf15907081000fafca:8b0d707646000faf0d7876460090909090 0x203ae:0fbf0d927081000fbf15907081000fafca:8b0d707646000faf0d7876460090909090 0x203f7:0fbf0d927081000fbf15907081000fafca:8b0d707646000faf0d7876460090909090 0x205b7:0fbf0d927081000fbf15907081000fafca:8b0d707646000faf0d7876460090909090 0x2063a:0fbf0d927081000fbf15907081000fafca:8b0d707646000faf0d7876460090909090"
)

apply_patches() {
    if [[ "$SC_PATCH" != 1 ]]; then warn "Parches desactivados (SC_PATCH=0): el juego no funcionará en Wine."; return; fi
    log "Aplicando parches de compatibilidad…"
    local e f orig final list h p off ob nb cur
    for e in "${PATCHES[@]}"; do
        IFS='|' read -r f orig final list <<<"$e"
        h=$(sha256sum "$GAME_DIR/$f" | cut -d' ' -f1)
        if [[ "$h" == "$final" ]]; then ok "$f ya estaba parcheado"; continue; fi
        # Parcheado con una versión anterior del script → partir del original
        if [[ "$h" != "$orig" && -f "$GAME_DIR/$f.ORIG" ]] \
           && [[ $(sha256sum "$GAME_DIR/$f.ORIG" | cut -d' ' -f1) == "$orig" ]]; then
            cp -p "$GAME_DIR/$f.ORIG" "$GAME_DIR/$f"; h=$orig
        fi
        [[ "$h" == "$orig" ]] || die "$f tiene un hash desconocido ($h); no se parchea. ¿Otra versión del juego?"
        cp -p "$GAME_DIR/$f" "$GAME_DIR/$f.ORIG"
        for p in $list; do
            IFS=: read -r off ob nb <<<"$p"
            if [[ -n "$ob" ]]; then   # comprobar bytes originales (vacío = continuación del parche anterior)
                cur=$(od -An -tx1 -v -j $((off)) -N $(( ${#ob} / 2 )) "$GAME_DIR/$f" | tr -d ' \n')
                [[ "$cur" == "$ob" ]] || { cp -p "$GAME_DIR/$f.ORIG" "$GAME_DIR/$f"; die "$f: bytes inesperados en $off ($cur)"; }
            fi
            printf "$(sed 's/../\\x&/g' <<<"$nb")" | dd of="$GAME_DIR/$f" bs=1 seek=$((off)) conv=notrunc status=none
        done
        h=$(sha256sum "$GAME_DIR/$f" | cut -d' ' -f1)
        [[ "$h" == "$final" ]] || { cp -p "$GAME_DIR/$f.ORIG" "$GAME_DIR/$f"; die "Verificación de parches de $f falló ($h); restaurado el original."; }
        ok "$f parcheado (original en $f.ORIG)"
    done
}

# --------------------------------------------------------------------------- #
#  5c. Runtime de mejoras (scenh.dll, carpeta runtime/ del repositorio)
# --------------------------------------------------------------------------- #
#  Una DLL propia que el juego carga al arrancar y que aplica mejoras en memoria (velocidad de juego con
#  +/-, menos consumo de CPU, avisos en pantalla; opciones en scenh.ini junto al juego). Para que la cargue
#  se renombra el import "GDI32.dll" de CLASH.EXE y SPACE.EXE a "SCENH.dll" (9 bytes, mismo largo; la DLL
#  reenvía a gdi32 lo único que el juego usaba de ella). Antes de los parches de compatibilidad se vuelve
#  al nombre original, así que reinstalar o desactivarlo (--no-runtime) deja los EXE como en la sección 5b.
#
#  Formato: ARCHIVO|offset del nombre|sha256 con parches 5b + runtime
RUNTIME_IMPORTS=(
  "CLASH.EXE|0x806d4|eac913cae176c501d718fcf3a63a39539458834bff97511d5813fb3deaa0f353"
  "SPACE.EXE|0x65aaa|142ef3a4530165765c1bc886e3b93880997b392bddffa4e34c5abcfe164137ea"
)

import_name() {   # import_name ARCHIVO OFFSET → GDI32.dll | SCENH.dll | otro
    dd if="$1" bs=1 skip=$(($2)) count=9 status=none 2>/dev/null
}

set_import_name() {   # set_import_name NOMBRE: GDI32.dll (original) o SCENH.dll (runtime) en ambos EXE
    local e f off h cur
    for e in "${RUNTIME_IMPORTS[@]}"; do
        IFS='|' read -r f off h <<<"$e"
        [[ -f "$GAME_DIR/$f" ]] || continue
        cur=$(import_name "$GAME_DIR/$f" "$off")
        [[ "$cur" == "$1" ]] && continue
        [[ "$cur" == GDI32.dll || "$cur" == SCENH.dll ]] || { warn "$f: import inesperado en $off ('$cur'); no se toca"; return 1; }
        printf '%s' "$1" | dd of="$GAME_DIR/$f" bs=1 seek=$((off)) conv=notrunc status=none
    done
}

ini_section_set() {   # ini_section_set ARCHIVO SECCIÓN CLAVE VALOR (crea la sección o la clave si faltan)
    local f=$1 sec=$2 key=$3 val=$4
    grep -q "^\[$sec\]" "$f" || printf '\n[%s]\n' "$sec" >>"$f"
    # El juego reescribe scenh.ini con WritePrivateProfileString (finales CRLF): ignorar el \r al comparar
    if awk -v s="[$sec]" -v k="$key" '{sub(/\r$/,"")} $0==s{f=1;next} /^\[/{f=0} f&&index($0,k"=")==1{found=1} END{exit !found}' "$f"; then
        sed -i "/^\[$sec\]/,/^\[/ s|^$key=[^\r]*|$key=$val|" "$f"
    else
        sed -i "/^\[$sec\]/a $key=$val" "$f"
    fi
}

fit_res() {   # fit_res W H → imprime el tamaño admitido más parecido (misma proporción) o nada
    local W=$1 H=$2 k w h
    for k in 1 2 3 4; do   # monitores grandes (4K, ultrawide): dividir por un entero → escalado nítido
        w=$(( (W / k) & ~7 ))
        h=$(( (w * H / W + 1) & ~1 ))
        if (( w >= 1024 && w <= 2560 && h >= 600 && h <= 1600 && w * h >= 1024 * 768 )); then
            echo "${w}x${h}"; return
        fi
        (( w < 1024 )) && return 0
    done
    return 0
}

monitor_res() {   # resolución del monitor (o del escritorio virtual pedido con --vdesktop-res)
    local r=$SC_VDESKTOP_RES
    [[ "$r" == auto ]] && r=$(xrandr --current 2>/dev/null | awk '/\*/{print $1; exit}' || true)
    [[ "$r" =~ ^[0-9]+x[0-9]+$ ]] && echo "$r"
    return 0   # sin pantalla (SSH, contenedor): vacío, sin cortar la instalación
}

check_res() {   # valida --res antes de empezar a instalar
    [[ -z "$SC_RES" || "$SC_RES" == off || "$SC_RES" == auto ]] && return 0
    [[ "$SC_RES" =~ ^([0-9]+)x([0-9]+)$ ]] || die "--res inválido: $SC_RES (p. ej. 1920x1080, u off)"
    local w=${BASH_REMATCH[1]} h=${BASH_REMATCH[2]}
    (( w >= 1024 && w <= 2560 && w % 8 == 0 && h >= 600 && h <= 1600 && w * h >= 1024 * 768 )) \
        || die "--res $SC_RES fuera de rango: ancho 1024–2560 (múltiplo de 8), alto 600–1600, área ≥ 1024x768"
}

set_runtime_res() {   # --res WxH: modo 1024 del juego → WxH (scenh.ini [resolucion]); --res off lo desactiva
    local ini="$GAME_DIR/scenh.ini" w h
    [[ -z "$SC_RES" ]] && return
    if [[ "$SC_RES" == auto ]]; then
        # Solo en una instalación nueva o con reinstall (scenh.ini recién creado) y en pantalla completa
        # escalada; al actualizar con install se respeta lo que haya en scenh.ini.
        [[ "${NEW_SCENH_INI:-0}" == 1 && "$SC_DISPLAY" == scaled ]] || return 0
        local mon fit
        mon=$(monitor_res)
        fit=""
        [[ -n "$mon" ]] && fit=$(fit_res "${mon%x*}" "${mon#*x}")
        if [[ -z "$fit" || "$fit" == 1024x768 ]]; then
            ok "Pantalla: 1024x768 (no se detectó un monitor compatible con la pantalla panorámica)"
            return
        fi
        SC_RES=$fit
    fi
    if [[ "$SC_RES" == off ]]; then
        ini_section_set "$ini" resolucion activar 0; ok "Resolución panorámica desactivada"; return
    fi
    check_res
    w=${SC_RES%x*}; h=${SC_RES#*x}
    ini_section_set "$ini" resolucion activar 1
    ini_section_set "$ini" resolucion ancho "$w"
    ini_section_set "$ini" resolucion alto "$h"
    SC_GAME_RES=1024   # la resolución panorámica reemplaza al modo 1024 del juego
    ok "Resolución panorámica (experimental): ${w}x${h}"
}

find_runtime_dll() {   # imprime la ruta de scenh.dll: la compilada aquí (si hay MinGW) o la del ZIP
    # Con MinGW se compila siempre (make solo rehace lo que cambió): así una copia del repositorio no
    # instala una DLL vieja de runtime/build/ cuando el código es más nuevo.
    if [[ -f "$SCRIPT_DIR/runtime/Makefile" ]] && have make && have i686-w64-mingw32-gcc \
       && make -s -C "$SCRIPT_DIR/runtime" >&2 && [[ -f "$SCRIPT_DIR/runtime/build/scenh.dll" ]]; then
        echo "$SCRIPT_DIR/runtime/build/scenh.dll"; return
    fi
    local f
    for f in "$SCRIPT_DIR/runtime/scenh.dll" "$SCRIPT_DIR/runtime/build/scenh.dll"; do
        [[ -f "$f" ]] && { echo "$f"; return; }
    done
}

setup_runtime() {
    if [[ "$SC_RUNTIME" != 1 || "$SC_PATCH" != 1 ]]; then
        set_import_name GDI32.dll
        [[ "$SC_RUNTIME" != 1 ]] && ok "Runtime de mejoras desactivado (--no-runtime)"
        return
    fi
    local dll
    dll=$(find_runtime_dll)
    if [[ -z "$dll" ]]; then
        warn "No está scenh.dll (runtime/) ni MinGW para compilarla ($(pkg_hint mingw)): se instala sin mejoras"
        set_import_name GDI32.dll
        return
    fi
    cp -f "$dll" "$GAME_DIR/scenh.dll"
    # reinstall: scenh.ini de cero (con las opciones nuevas y la resolución del monitor detectada otra vez)
    if [[ "${REINSTALL:-0}" == 1 && -f "$GAME_DIR/scenh.ini" ]]; then
        mv -f "$GAME_DIR/scenh.ini" "$GAME_DIR/scenh.ini.anterior"
        log "Opciones del runtime restablecidas (las anteriores quedan en scenh.ini.anterior)"
    fi
    if [[ ! -f "$GAME_DIR/scenh.ini" ]]; then
        cp "$SCRIPT_DIR/runtime/scenh.ini" "$GAME_DIR/scenh.ini"
        NEW_SCENH_INI=1
    fi
    set_import_name SCENH.dll || { set_import_name GDI32.dll; return; }
    set_runtime_res
    ok "Runtime de mejoras instalado: velocidad con + y - durante la partida (opciones en $GAME_DIR/scenh.ini)"
}

# --------------------------------------------------------------------------- #
#  6. Modo de pantalla: DirectDraw + renderizador de vídeo
# --------------------------------------------------------------------------- #
#  El juego usa DirectDraw 8 bits con paleta a 640x480/800x600 (y 1024x768) y
#  reproduce los vídeos MPEG-1 con DirectShow (quartz) dentro del mismo proceso.
#
#  scaled (por defecto) — pantalla completa, escalado 4:3 centrado:
#    * cnc-ddraw (ddraw.dll nativa solo para SC/CLASH/SPACE.EXE) escala cada
#      modo del juego a la resolución del escritorio virtual (= monitor), con
#      barras negras laterales, y traduce las coordenadas del ratón.
#    * El renderizador de vídeo por defecto de Wine (VMR7) usa DirectDraw y con
#      cnc-ddraw muestra blanco. Se baja el mérito de "Video Renderer default"
#      ({6BC1CFFA…}) para que DirectShow elija el "Video Renderer" GDI clásico
#      ({70E102B0…}). Limitación: el juego pone el vídeo en una ventana hija
#      de 4000x4000 + "pantalla completa" (no implementado en Wine), así que los
#      vídeos se estiran a toda la pantalla. Lo corrige setup_videos (6b).
#  window — el modo original verificado primero: DirectDraw de Wine (wined3d) y
#    VMR7; el escritorio virtual adopta el tamaño del modo del juego (640x480…),
#    sin escalar. Vídeos perfectos, ventana chica.
VMR_DEFAULT_KEY='HKCR\Wow6432Node\CLSID\{083863F1-70DE-11D0-BD40-00A0C911CE86}\Instance\{6BC1CFFA-8FC1-4261-AC22-CFB4CC38DB50}'
VMR_FILTERDATA_TAIL='010000000000000030706933020000000000000001000000000000000000000030747933000000003800000048000000766964730000100080000000aa00389b710000000000000000000000000000000000'

set_vmr_merit() {   # set_vmr_merit orig|low — FilterData = versión 02000000 | mérito (4 bytes LE) | resto
    local merit=01008000                     # 0x00800001 (original de Wine)
    [[ $1 == low ]] && merit=00002000        # 0x00200000 = MERIT_DO_NOT_USE
    wine_q reg add "$VMR_DEFAULT_KEY" /v FilterData /t REG_BINARY /d "02000000${merit}${VMR_FILTERDATA_TAIL}" /f
}

setup_ddraw() {
    local apps=(SC.EXE CLASH.EXE SPACE.EXE) a
    if [[ "$SC_DISPLAY" == window ]]; then
        log "Modo de pantalla: window (DirectDraw de Wine, tamaño original)."
        rm -f "$GAME_DIR/ddraw.dll"
        for a in "${apps[@]}"; do
            wine_q reg delete "HKCU\\Software\\Wine\\AppDefaults\\$a\\DllOverrides" /v ddraw /f || true
        done
        set_vmr_merit orig
        "$SC_WINE"server -w 2>/dev/null || wineserver -w
        return
    fi
    [[ "$SC_DISPLAY" == scaled ]] || die "SC_DISPLAY inválido: $SC_DISPLAY (scaled|window)"
    log "Modo de pantalla: scaled (cnc-ddraw, pantalla completa escalada)…"
    local cache="$SC_ROOT/media/cnc-ddraw.zip" tmp boxing shader filter=$SC_FILTER
    case "$SC_SCALING" in
        fit)     boxing=false ;;
        integer) boxing=true ;;
        *) die "SC_SCALING inválido: $SC_SCALING (fit|integer)" ;;
    esac
    # auto: con escalado libre el factor no es entero (1080p: x1,8-x2,25) y "sharp" evita píxeles
    # de ancho desparejo; con escalado entero, píxeles exactos.
    [[ "$filter" == auto ]] && { [[ "$SC_SCALING" == integer ]] && filter=nearest || filter=sharp; }
    case "$filter" in   # valores internos de cnc-ddraw o rutas a Shaders\ (copiados abajo)
        nearest) shader="Nearest neighbor" ;;
        sharp)   shader='Shaders\interpolation\sharp-bilinear-simple-bilinear.glsl' ;;
        smooth)  shader="Bicubic" ;;
        xbr)     shader="xBR-lv2" ;;
        crt)     shader='Shaders\crt\crt-lottes-fast-no-warp-bilinear.glsl' ;;
        *) die "SC_FILTER inválido: $SC_FILTER (auto|nearest|sharp|smooth|xbr|crt)" ;;
    esac
    [[ "${REINSTALL:-0}" == 1 ]] && rm -f "$cache"   # reinstall: descargar cnc-ddraw de nuevo
    [[ "$SC_RENDERER" == gdi && "$filter" != nearest ]] && warn "--filter $filter no tiene efecto con renderer=gdi (escalado simple por CPU)"
    if [[ ! -f "$cache" ]]; then
        mkdir -p "$(dirname "$cache")"
        curl -fsSL --retry 3 -o "$cache.part" "$SC_CNC_URL" || die "No se pudo descargar cnc-ddraw ($SC_CNC_URL). Usá --display window o descargalo a mano en $cache"
        mv "$cache.part" "$cache"
    fi
    tmp=$(mktemp -d); unzip -q -o "$cache" -d "$tmp"
    install -m 0644 "$tmp/ddraw.dll" "$GAME_DIR/ddraw.dll"
    install -m 0644 "$tmp/ddraw.ini" "$GAME_DIR/ddraw.ini"
    sed -i 's/\r$//' "$GAME_DIR/ddraw.ini"      # viene con CRLF; ini_set trabaja con LF
    # Shaders de escalado (GLSL de libretro): los del zip + el paquete ampliado que trae dentro
    rm -rf "$GAME_DIR/Shaders"; cp -r "$tmp/Shaders" "$GAME_DIR/Shaders"
    if [[ -f "$GAME_DIR/Shaders/shader-package.zip" ]]; then
        unzip -q -o "$GAME_DIR/Shaders/shader-package.zip" -d "$GAME_DIR" && rm -f "$GAME_DIR/Shaders/shader-package.zip"
    fi
    rm -rf "$tmp"
    ini_set fullscreen   true      # ventana sin bordes del tamaño del escritorio virtual
    ini_set windowed     false
    ini_set maintas      true      # mantener 4:3 (barras negras a los lados)
    ini_set boxing       "$boxing" # true = solo escalado entero (más nítido, más borde)
    ini_set width        0
    ini_set height       0
    ini_set renderer     "$SC_RENDERER"
    ini_set shader       "$shader" # solo con renderer=opengl
    ini_set adjmouse     true      # traducir coordenadas del ratón al modo del juego
    ini_set vsync        false
    ini_set devmode      false
    ini_set savesettings 0
    for a in "${apps[@]}"; do
        wine_q reg add "HKCU\\Software\\Wine\\AppDefaults\\$a\\DllOverrides" /v ddraw /d native,builtin /f
    done
    set_vmr_merit low
    "$SC_WINE"server -w 2>/dev/null || wineserver -w
    ok "cnc-ddraw configurado (renderer=$SC_RENDERER, escalado=$SC_SCALING, filtro=$filter; ajustes en $GAME_DIR/ddraw.ini, sección [ddraw])"
}

ini_set() {   # ini_set clave valor → fija "clave=valor" SOLO dentro de la sección [ddraw]
    local k=$1 v=$2 ini="$GAME_DIR/ddraw.ini" tmp
    tmp=$(mktemp)
    # Valores por ENVIRON y no con awk -v, que interpreta las barras invertidas (rutas de shaders)
    K="$k" V="$v" awk '
        BEGIN { k = ENVIRON["K"]; v = ENVIRON["V"] }
        /^\[/ { if (insec && !done) { print k "=" v; done=1 } insec = ($0 == "[ddraw]") }
        insec && $0 ~ "^[;[:space:]]*" k "[[:space:]]*=" { if (!done) { print k "=" v; done=1 }; next }
        { print }
        END { if (insec && !done) print k "=" v }
    ' "$ini" > "$tmp" && mv "$tmp" "$ini" && chmod 0644 "$ini"
}

# Resolución del juego (la misma opción que el menú Opciones → Resolución de Pantalla).
# CLASH.CFG (18 bytes): el byte 0x10 es el modo: 1 = 640x480, 2 = 800x600, 3 = 1024x768.
# 1024x768 muestra más área del mapa; con --scaling integer en 4K queda a x2 (2048x1536).
set_game_res() {
    local cfg="$GAME_DIR/CLASH.CFG" idx
    local res=$SC_GAME_RES
    # auto: 1024x768 (más mapa visible) si CLASH.CFG es nuevo o con reinstall; al actualizar con install
    # se respeta lo que el jugador eligió en Opciones.
    [[ "$res" == auto ]] && { [[ "${NEW_CFG:-0}" == 1 || "${REINSTALL:-0}" == 1 ]] && res=1024 || res=keep; }
    case "$res" in
        keep) return 0 ;;
        640) idx=1 ;; 800) idx=2 ;; 1024) idx=3 ;;
        *) die "SC_GAME_RES inválido: $SC_GAME_RES (auto|keep|640|800|1024)" ;;
    esac
    [[ $(stat -c %s "$cfg") == 18 ]] || { warn "CLASH.CFG con tamaño inesperado; no se cambia la resolución"; return; }
    printf "\\x0$idx" | dd of="$cfg" bs=1 seek=16 conv=notrunc status=none
    ok "Resolución del juego: $(game_res_name) (CLASH.CFG)"
}

game_res_name() {   # nombre de la resolución guardada en CLASH.CFG
    local b; b=$(od -An -tu1 -j16 -N1 "$GAME_DIR/CLASH.CFG" 2>/dev/null | tr -d ' ')
    case "$b" in 0) echo 640x400 ;; 1) echo 640x480 ;; 2) echo 800x600 ;; 3) echo 1024x768 ;; *) echo "? ($b)" ;; esac
}

# --------------------------------------------------------------------------- #
#  6b. Vídeos a pantalla completa sin deformar (modo scaled)
# --------------------------------------------------------------------------- #
#  El renderizador de vídeo estira cada .MPG (320x240, 4:3) a toda la pantalla,
#  sin respetar el aspect ratio (en 16:9 se ven un 33 % más anchos). Se
#  reencodean a la resolución EXACTA de la pantalla, con la imagen 4:3 centrada
#  y barras negras: el estirado queda 1:1. Siguen siendo MPEG-1 System con el
#  mismo nombre (el formato que el juego ya reproduce) y el audio MP2 se copia
#  sin tocar. Los originales quedan en cd/VIDEOS/ORIG/. Lo hace videos-fit.sh,
#  que también usa el lanzador para regenerarlos si cambia la resolución.
#  Detalle y alternativas: docs/VIDEOS.md.
create_video_helper() {
    cat > "$SC_ROOT/videos-fit.sh" <<'EOF'
#!/usr/bin/env bash
# videos-fit.sh — adapta los vídeos de Space Clash a la pantalla (generado por install-spaceclash.sh)
#   videos-fit.sh check WxH    ¿ya están generados para WxH? (código 0 = sí)
#   videos-fit.sh ensure WxH   los genera para WxH si hace falta (~1 min)
#   videos-fit.sh restore      vuelve a los vídeos originales
#   videos-fit.sh status       muestra el estado
# Si existe un máster escalado con IA (tools/upscale-videos.py → videos-hd/), se usa como fuente.
set -uo pipefail
R="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V="$R/cd/VIDEOS"; O="$V/ORIG"; STAMP="$V/.fit"
HD="${SC_VIDEOS_HD:-$R/videos-hd}"
FIT_VERSION=2   # subir si cambian los parámetros de codificación (fuerza regenerar)
declare -A SHA=(
    [LOGO.MPG]=73b260e5f9c53d198d3872719b86c99d58059fa01224cce937bcd660af97306d
    [DINAMIC.MPG]=18d721c17d4f0f3cfab163ccf2255500427ce0ee9441ad97be632cdbe9d6e794
    [INTRO.MPG]=21ccc54cf26092b1fc9af45ea764f3d0e356fb993715ebc25a45b5225a577955
    [FINAL00.MPG]=9d961881d5a076c6d1899e626b9ca519630aad6c7c2aea64f44f2b58493e5774
    [FINAL01.MPG]=35286ae006a543096b6ee1e2bb2b17990680152703a3d790861909396535a278
    [FINAL02.MPG]=76b406415b48813c0a79e83596e83bcf1f2f4e7f05a73954503a1d1a31e1ac37
    [FINAL03.MPG]=13a2dd30aa8547d0560cc24fdc6ed87b3468310779c86146835cc2dabb8df983
)
fail() { echo "videos-fit: $*" >&2; exit 1; }

backup() {   # copia los originales a ORIG/ (una sola vez)
    local f
    mkdir -p "$O" || fail "no se pudo crear $O"
    for f in "${!SHA[@]}"; do
        [[ -f "$O/$f" ]] && continue
        [[ -f "$STAMP" ]] && fail "falta el original $O/$f y $V/$f ya está adaptado (reinstalá con --force)"
        [[ -f "$V/$f" ]] || fail "falta $V/$f"
        [[ $(sha256sum "$V/$f" | cut -c1-64) == "${SHA[$f]}" ]] || echo "videos-fit: aviso: $f no coincide con el del CD conocido; se usa igual" >&2
        cp -p --reflink=auto "$V/$f" "$O/$f.part" && mv "$O/$f.part" "$O/$f" || fail "no se pudo copiar $f a $O"
    done
}

restore() {
    local f
    rm -f "$STAMP" "$V"/.*.part
    [[ -d "$O" ]] || return 0
    for f in "${!SHA[@]}"; do
        [[ -f "$O/$f" ]] && { cp -p --reflink=auto "$O/$f" "$V/$f" || fail "no se pudo restaurar $f"; }
    done
    rm -rf "$O"
}

# Fuente de cada vídeo: el máster HD si está completo, si no el original de 320x240
hd_ok() { [[ -f "$HD/manifest.json" ]] && for f in "${!SHA[@]}"; do [[ -s "$HD/${f%.MPG}.mkv" ]] || return 1; done; }
source_tag() { if hd_ok; then echo "hd-$(cksum <"$HD/manifest.json" | cut -d' ' -f1)"; else echo orig; fi; }
src_of() { if hd_ok; then echo "$HD/${1%.MPG}.mkv"; else echo "$O/$1"; fi; }

check() { [[ "$(cat "$STAMP" 2>/dev/null)" == "$1 v$FIT_VERSION $(source_tag)" ]]; }

ensure() {
    local res=$1 w h vf f p ok=1 pids=()
    [[ $res =~ ^([0-9]+)x([0-9]+)$ ]] || fail "resolución inválida: $res"
    w=${BASH_REMATCH[1]}; h=${BASH_REMATCH[2]}
    check "$res" && return 0
    command -v ffmpeg >/dev/null || fail "falta ffmpeg; se usan los vídeos actuales"
    # Más de 1080 líneas no aporta nada (fuente de 320x240, o máster HD de 960): en pantallas mayores se
    # genera a 1080 de alto con la MISMA proporción y el renderizador lo estira sin deformar.
    if ((h > 1080)); then w=$(( (w * 1080 / h + 1) / 2 * 2 )); h=1080; fi
    backup
    local tag q=3 rate=15M
    tag=$(source_tag)
    [[ $tag == hd-* ]] && { q=2; rate=30M; }   # el máster tiene detalle real: más bitrate
    echo "videos-fit: generando los vídeos para $res (${w}x$h, fuente: ${tag%%-*})…"
    # setsar=1: los originales declaran un pel aspect ratio erróneo (178:163); son 4:3 con píxeles cuadrados
    vf="setsar=1,scale=$w:$h:force_original_aspect_ratio=decrease:force_divisible_by=2:flags=lanczos"
    vf+=",pad=$w:$h:(ow-iw)/2:(oh-ih)/2:black,setsar=1"
    rm -f "$STAMP"
    for f in "${!SHA[@]}"; do
        ffmpeg -nostdin -v error -y -i "$(src_of "$f")" -map 0:v:0 -map 0:a:0 -vf "$vf" \
            -c:v mpeg1video -q:v "$q" -maxrate "$rate" -bufsize 8M -g 12 -bf 2 \
            -c:a copy -f mpeg "$V/.$f.part" &
        pids+=($!)
    done
    for p in "${pids[@]}"; do wait "$p" || ok=0; done
    for f in "${!SHA[@]}"; do [[ -s "$V/.$f.part" ]] || ok=0; done
    if ((!ok)); then restore; fail "ffmpeg falló; se restauraron los vídeos originales"; fi
    for f in "${!SHA[@]}"; do mv "$V/.$f.part" "$V/$f"; done
    echo "$res v$FIT_VERSION $tag" > "$STAMP"
    echo "videos-fit: listo ($res)"
}

case "${1:-status}" in
    check)   check "${2:?falta WxH}" ;;
    ensure)  ensure "${2:?falta WxH}" ;;
    restore) restore ;;
    status)  if [[ -f "$STAMP" ]]; then echo "adaptados: $(cat "$STAMP")"; else echo "originales"; fi ;;
    *)       fail "uso: $0 check|ensure WxH | restore | status" ;;
esac
EOF
    chmod +x "$SC_ROOT/videos-fit.sh"
}

# Escalado con IA (opcional): genera el máster $SC_ROOT/videos-hd con tools/upscale-videos.py.
# Necesita PyTorch + spandrel (y una GPU para que tarde minutos y no horas). Por defecto se PREGUNTA
# (respuesta por defecto: no), solo si hay terminal, si hay PyTorch y si todavía no hay máster.
# --videos-ai MODELO lo hace sin preguntar; --videos-ai off no pregunta.
# Python: SC_PYTHON, o el entorno $AI_VENV (lo crea este instalador), o python3. Si python3 tiene PyTorch
# pero no spandrel, se crea $AI_VENV (reutiliza el PyTorch del sistema) y se instala spandrel ahí.
AI_VENV="${XDG_DATA_HOME:-$HOME/.local/share}/spaceclash-venv"
ai_ready() { "$1" -c 'import torch, spandrel, numpy' 2>/dev/null; }
find_ai_python() {   # imprime el primer Python listo para el escalado
    local py
    for py in ${SC_PYTHON:+"$SC_PYTHON"} "$AI_VENV/bin/python" python3; do
        have "$py" && ai_ready "$py" && { echo "$py"; return 0; }
    done
    return 1
}
make_ai_venv() {     # python3 con PyTorch → entorno con spandrel
    log "Creando $AI_VENV con spandrel (reutiliza el PyTorch de python3)…"
    python3 -m venv --system-site-packages "$AI_VENV" && "$AI_VENV/bin/pip" install -q spandrel \
        && ai_ready "$AI_VENV/bin/python"
}
setup_videos_ai() {
    local tool="$SCRIPT_DIR/tools/upscale-videos.py" model=$SC_VIDEOS_AI a py="" need_venv=0
    [[ "$model" == off ]] && return
    [[ "$model" =~ ^(ask|general|general-sharp|x4plus)$ ]] \
        || die "SC_VIDEOS_AI inválido: $model (ask|off|general|general-sharp|x4plus)"
    [[ "$SC_DISPLAY" == scaled && "$SC_VIDEOS" == fit && -f "$tool" ]] || return
    [[ "$model" == ask && -f "$SC_ROOT/videos-hd/manifest.json" ]] && return   # ya hecho: videos-fit lo usa solo
    [[ "$model" == ask && ! -t 0 ]] && return
    if ! py=$(find_ai_python); then
        if have python3 && python3 -c 'import torch, numpy' 2>/dev/null; then
            need_venv=1
        elif [[ "$model" == ask ]]; then
            echo "    Opcional: los vídeos se pueden escalar con IA (más nítidos). Requiere PyTorch:"
            echo "    pip install torch (ver https://pytorch.org) y volver a instalar. Detalle: README.md"
            return
        else
            warn "Para --videos-ai hace falta Python con PyTorch (ver https://pytorch.org). Se usan los vídeos normales."
            return
        fi
    fi
    if [[ "$model" == ask ]]; then
        echo "    Los vídeos (logos, intro y finales) se pueden escalar con IA: más nítidos y sin bloques."
        echo "    Tarda ≈10 min con una GPU NVIDIA (horas sin GPU) y se hace una sola vez."
        read -r -p "    ¿Escalar los vídeos con IA ahora? [s/N] " a || a=""
        [[ "$a" =~ ^[sSyY]$ ]] || { echo "    Sin escalar (se puede hacer después: ver README.md)"; return; }
        model=general
    fi
    if ((need_venv)); then
        make_ai_venv || { warn "No se pudo instalar spandrel en $AI_VENV: se usan los vídeos normales."; return; }
        py="$AI_VENV/bin/python"
    fi
    "$py" -c 'import torch,sys; sys.exit(0 if torch.cuda.is_available() else 1)' 2>/dev/null \
        || warn "PyTorch no ve una GPU CUDA: el escalado en CPU puede tardar horas."
    log "Escalando los vídeos con IA (modelo $model; ≈10 min con GPU, una sola vez)…"
    if "$py" "$tool" --root "$SC_ROOT" --model "$model"; then
        ok "Máster de vídeo escalado con IA en $SC_ROOT/videos-hd"
    else
        warn "Falló el escalado con IA: se usan los vídeos normales (detalle arriba)."
    fi
}

# --videos ask (por defecto): al actualizar con install se conserva lo elegido (el lanzador lo guarda); en
# una instalación nueva o con reinstall se pregunta (respuesta por defecto: sí). Sin terminal, lo elegido
# antes o, si no hay, vídeos originales.
resolve_videos() {
    local a prev
    [[ "$SC_VIDEOS" =~ ^(ask|fit|original)$ ]] || die "SC_VIDEOS inválido: $SC_VIDEOS (ask|fit|original)"
    [[ "$SC_VIDEOS" == ask ]] || return 0
    prev=""
    [[ -f "$LAUNCHER" ]] && ! [[ "${REINSTALL:-0}" == 1 && -t 0 ]] && prev=$(sed -n 's/^SC_VIDEOS="\${SC_VIDEOS:-\(fit\|original\)}"$/\1/p' "$LAUNCHER")
    if [[ -n "$prev" ]]; then
        SC_VIDEOS=$prev
    elif [[ "$SC_DISPLAY" != scaled ]]; then
        SC_VIDEOS=original   # en ventana los vídeos no se estiran
    elif [[ -t 0 ]]; then
        echo "    El juego estira los vídeos (logos, intro y finales) a lo ancho de la pantalla. Se puede"
        echo "    hacer una copia adaptada a tu monitor, en 4:3 con barras negras (≈1 min; los originales"
        echo "    se conservan; requiere ffmpeg)."
        read -r -p "    ¿Adaptar los vídeos a 4:3? [S/n] " a || a=""
        [[ "$a" =~ ^[nN]$ ]] && SC_VIDEOS=original || SC_VIDEOS=fit
    else
        SC_VIDEOS=original
        log "Sin terminal para preguntar: vídeos originales (para adaptarlos: --videos fit)"
    fi
}

setup_videos() {
    local helper="$SC_ROOT/videos-fit.sh" res
    [[ "$SC_VIDEOS" == fit || "$SC_VIDEOS" == original ]] || die "SC_VIDEOS inválido: $SC_VIDEOS (fit|original)"
    create_video_helper
    if [[ "$SC_DISPLAY" != scaled || "$SC_VIDEOS" != fit ]]; then
        "$helper" restore && ok "Vídeos originales"
        return
    fi
    if ! have ffmpeg; then
        warn "Sin ffmpeg los vídeos se verán estirados. Instalalo ($(pkg_hint ffmpeg)): el lanzador los adaptará al arrancar."
        return
    fi
    res=$SC_VDESKTOP_RES
    [[ "$res" == auto ]] && res=$(xrandr --current 2>/dev/null | awk '/\*/{print $1; exit}' || true)
    if [[ ! "$res" =~ ^[0-9]+x[0-9]+$ ]]; then
        log "No se pudo detectar la resolución: los vídeos se adaptarán al arrancar el juego."
        return
    fi
    [[ "${FORCE:-0}" == 1 ]] && rm -f "$CD_DIR/VIDEOS/.fit"
    log "Adaptando los vídeos a $res (4:3 centrado con barras negras; ~1 min)…"
    [[ -f "$SC_ROOT/videos-hd/manifest.json" ]] && log "Se usa el máster escalado con IA de $SC_ROOT/videos-hd"
    if "$helper" ensure "$res" >/dev/null; then ok "Vídeos adaptados a $res (originales en $CD_DIR/VIDEOS/ORIG)"
    else warn "No se pudieron adaptar los vídeos: se usan los originales (estirados)."; fi
}

# --------------------------------------------------------------------------- #
#  7. Lanzador + acceso directo de escritorio
# --------------------------------------------------------------------------- #
create_launcher() {
    log "Creando lanzador $LAUNCHER…"
    mkdir -p "$LOG_DIR"
    cat > "$LAUNCHER" <<EOF
#!/usr/bin/env bash
# Lanzador de Space Clash (generado por install-spaceclash.sh)
export WINEPREFIX="$WINEPREFIX"
export WINEDEBUG="\${WINEDEBUG:--all}"
# Si 'wine' no está en el PATH del entorno gráfico, ajustá SC_WINE.
SC_WINE="\${SC_WINE:-$SC_WINE}"
SC_VDESKTOP="\${SC_VDESKTOP:-$SC_VDESKTOP}"
SC_VDESKTOP_RES="\${SC_VDESKTOP_RES:-$SC_VDESKTOP_RES}"
SC_DISPLAY="$SC_DISPLAY"   # fijado al instalar (cambiar con: install-spaceclash.sh install --display …)
if [[ "\$SC_VDESKTOP_RES" == auto ]]; then
    if [[ "\$SC_DISPLAY" == scaled ]]; then
        # Resolución del monitor principal (XWayland/X11); el escritorio virtual de Wine
        # del mismo tamaño que la pantalla se muestra a pantalla completa.
        SC_VDESKTOP_RES=\$(xrandr --current 2>/dev/null | awk '/\*/{print \$1; exit}' || true)
        [[ "\$SC_VDESKTOP_RES" =~ ^[0-9]+x[0-9]+\$ ]] || SC_VDESKTOP_RES=1920x1080
    else
        SC_VDESKTOP_RES=1024x768
    fi
fi
SC_GAMESCOPE="\${SC_GAMESCOPE:-$SC_GAMESCOPE}"
SC_VIDEOS="\${SC_VIDEOS:-$SC_VIDEOS}"
# Vídeos 4:3 con barras para esta resolución: se regeneran si cambió el monitor (~1 min)
if [[ "\$SC_DISPLAY" == scaled && "\$SC_VIDEOS" == fit && -x "$SC_ROOT/videos-fit.sh" ]] \
   && ! "$SC_ROOT/videos-fit.sh" check "\$SC_VDESKTOP_RES"; then
    command -v notify-send >/dev/null && notify-send -a 'Space Clash' 'Space Clash' "Adaptando los vídeos a \$SC_VDESKTOP_RES…"
    "$SC_ROOT/videos-fit.sh" ensure "\$SC_VDESKTOP_RES" >>"$LOG_DIR/wine.log" 2>&1
fi
# --sin-videos: directo al menú principal. La unidad del CD apunta a una vista con enlaces simbólicos
# que no tiene LOGO, DINAMIC ni INTRO (el juego omite los vídeos que no existen); los finales siguen.
# Al salir vuelve al CD completo, y el arranque normal también lo restablece.
NOVID=0
[[ "\${1:-}" == --sin-videos ]] && { NOVID=1; shift; }
CD_LINK="$WINEPREFIX/dosdevices/${SC_CD_LETTER,,}:"
if ((NOVID)); then
    rm -rf "$NOVID_DIR" && mkdir -p "$NOVID_DIR/VIDEOS" || exit 1
    for e in "$CD_DIR"/* "$CD_DIR"/.windows-*; do
        [[ -e "\$e" && "\${e##*/}" != VIDEOS ]] && ln -s "\$e" "$NOVID_DIR/"
    done
    for e in "$CD_DIR"/VIDEOS/FINAL*.MPG; do [[ -e "\$e" ]] && ln -s "\$e" "$NOVID_DIR/VIDEOS/"; done
    ln -sfn "$NOVID_DIR" "\$CD_LINK"
else
    ln -sfn "$CD_DIR" "\$CD_LINK"
fi
cd "$GAME_DIR" || exit 1
# Se hace lo que haría SC.EXE (el lanzador original): escribir en CDSC.INS la raíz del CD virtual y abrir
# CLASH.EXE, que el parche P1 deja arrancar sin SC.EXE (igual que el lanzador de Windows). SC.EXE espera
# en un diálogo modal de MFC que se cierra con EndDialog al encontrar el CD; con el Wine 9 de Ubuntu ese
# EndDialog falla y el juego no se abre (INSTALADORES §7 nº 26). Sin los parches (--no-patch) se usa SC.EXE.
# Ruta completa obligatoria: dentro de explorer, "SC.EXE" a secas resuelve al sc.exe de sistema.
printf '%s' '${SC_CD_LETTER^^}:\' > "$GAME_DIR/CDSC.INS"
cmd=("\$SC_WINE")
if [[ "\$SC_VDESKTOP" == 1 ]]; then
    # Escritorio virtual: evita que la ventana a pantalla completa se minimice
    # al perder el foco tras los vídeos, y no cambia la resolución del monitor.
    cmd+=(explorer "/desktop=SpaceClash,\$SC_VDESKTOP_RES")
fi
cmd+=('$( [[ "$SC_PATCH" == 1 ]] && echo 'C:\SCLASH\CLASH.EXE' || echo 'C:\SCLASH\SC.EXE' )' "\$@")
# gamescope: alternativa NO verificada para escalar el modo "window" (requiere: pacman -S gamescope)
if [[ "\$SC_GAMESCOPE" == 1 ]] && command -v gamescope >/dev/null; then
    cmd=(gamescope -w 640 -h 480 -f -S fit -- "\${cmd[@]}")
fi
echo "=== \$(date '+%F %T') \${cmd[*]}\$( ((NOVID)) && echo ' (sin vídeos)')" >>"$LOG_DIR/wine.log"
((NOVID)) || exec "\${cmd[@]}" >>"$LOG_DIR/wine.log" 2>&1
"\${cmd[@]}" >>"$LOG_DIR/wine.log" 2>&1
rc=\$?
# Esperar a que terminen todos los procesos del prefijo (CLASH.EXE → SPACE.EXE) y volver al CD completo
ws="\${SC_WINE%wine}wineserver"; command -v "\$ws" >/dev/null || ws=wineserver
"\$ws" -w
ln -sfn "$CD_DIR" "\$CD_LINK"
exit "\$rc"
EOF
    chmod +x "$LAUNCHER"

    if [[ "$SC_DESKTOP" == 1 ]]; then
        mkdir -p "$(dirname "$DESKTOP_FILE")" "$(dirname "$ICON_FILE")"
        if have magick; then
            magick "$GAME_DIR/ICON.ICO[0]" -resize 48x48 "$ICON_FILE" 2>/dev/null || true
        elif have convert; then   # ImageMagick 6 (Ubuntu/Debian)
            convert "$GAME_DIR/ICON.ICO[0]" -resize 48x48 "$ICON_FILE" 2>/dev/null || true
        fi
        cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Type=Application
Name=Space Clash: The Last Frontier
Comment=Estrategia en tiempo real (Dinamic Multimedia, 1999) vía Wine
Exec="$LAUNCHER"
Path=$GAME_DIR
Icon=$( [[ -f "$ICON_FILE" ]] && echo "$ICON_FILE" || echo wine )
Terminal=false
Categories=Game;StrategyGame;
StartupWMClass=sc.exe
EOF
        sed -e 's/^Name=.*/Name=Space Clash (sin vídeos)/' \
            -e 's/^Comment=.*/Comment=Space Clash directo al menú principal, sin los vídeos de inicio/' \
            -e "s|^Exec=.*|Exec=\"$LAUNCHER\" --sin-videos|" "$DESKTOP_FILE" > "$DESKTOP_FILE_NV"
        have update-desktop-database && update-desktop-database "$(dirname "$DESKTOP_FILE")" >/dev/null 2>&1 || true
        ok "Accesos directos: $DESKTOP_FILE (y «sin vídeos»: $DESKTOP_FILE_NV)"
    fi
}

# --------------------------------------------------------------------------- #
#  8. Biblioteca de Steam (juego que no es de Steam, con portada, cabecera e icono)
# --------------------------------------------------------------------------- #
#  Steam guarda los juegos agregados a mano en userdata/<cuenta>/config/shortcuts.vdf (VDF binario) y
#  sus imágenes en config/grid/<appid>{p,,_hero}.png. Lee el archivo al arrancar y lo reescribe al
#  cerrarse, así que hay que editarlo con Steam cerrado. Se agregan dos entradas (normal y «sin
#  vídeos»); si ya existen (también las agregadas a mano: el mismo lanzador) se actualizan sin cambiar
#  el appid, así se conservan las horas jugadas y las colecciones. Las imágenes salen del propio CD:
#  PORTADA.PCX (portada y cápsula ancha), FONDO.PCX (cabecera) e ICON.ICO. No se usa Proton: el
#  lanzador ya ejecuta Wine. Steam de Flatpak no puede ejecutar el Wine del sistema y se omite.
STEAM_ART="$SC_ROOT/steam"

steam_dirs() {   # imprime los config/ de cada cuenta de Steam (nativo)
    local root d
    for root in "$HOME/.local/share/Steam" "$HOME/.steam/steam"; do
        [[ -d "$root/userdata" ]] && break
    done
    [[ -d "$root/userdata" ]] || return 0
    for d in "$root"/userdata/*/; do
        if [[ "$(basename "$d")" =~ ^[1-9][0-9]*$ ]]; then echo "${d}config"; fi
    done
}

steam_running() { pgrep -x steam >/dev/null 2>&1; }

steam_close() {   # cierra Steam (preguntando) o devuelve 1
    steam_running || return 0
    if [[ ! -t 0 ]]; then
        warn "Steam está abierto: no se agregó el juego a la biblioteca. Cerralo y ejecutá: $0 steam"
        return 1
    fi
    local a
    read -r -p "    Steam está abierto y hay que cerrarlo para agregar el juego. ¿Cerrarlo ahora? [S/n] " a || a=""
    if [[ "$a" =~ ^[nN]$ ]]; then
        warn "No se agregó el juego a Steam. Para hacerlo más tarde, con Steam cerrado: $0 steam"
        return 1
    fi
    if have steam; then steam -shutdown >/dev/null 2>&1 & else xdg-open steam://exit >/dev/null 2>&1 & fi
    local i
    for ((i = 0; i < 60; i++)); do steam_running || return 0; sleep 0.5; done
    warn "Steam no se cerró a tiempo. Cerralo y ejecutá: $0 steam"
    return 1
}

steam_art() {   # genera las imágenes en $STEAM_ART (sin ImageMagick, Steam usa las suyas)
    local im
    if have magick; then im=magick; elif have convert; then im=convert; else return 0; fi
    local P="$CD_DIR/IMG/PORTADA.PCX"
    mkdir -p "$STEAM_ART"
    [[ -f "$P" ]] && {
        # Portada 600x900: la ilustración 4:3 sobre una versión desenfocada, con los bordes fundidos
        $im "$P" -resize 600x900^ -gravity center -extent 600x900 -blur 0x18 -modulate 55 \
            \( "$P" -resize 600x \( -size 600x450 xc:white -size 600x70 gradient:black-white -gravity north -composite \
                                    -size 600x70 gradient:white-black -gravity south -composite \) \
               -alpha off -compose CopyOpacity -composite \) \
            -compose over -gravity center -geometry +0-60 -composite "$STEAM_ART/portrait.png"
        $im "$P" -resize 920x -gravity north -extent 920x430 "$STEAM_ART/wide.png"
    } 2>/dev/null || true
    [[ -f "$CD_DIR/IMG/FONDO.PCX" ]] && \
        $im "$CD_DIR/IMG/FONDO.PCX" -resize 1920x -gravity north -crop 1920x620+0+120 +repage "$STEAM_ART/hero.png" 2>/dev/null || true
    [[ -f "$GAME_DIR/ICON.ICO" ]] && \
        $im "$GAME_DIR/ICON.ICO[0]" -filter point -resize 256x256 "$STEAM_ART/icon.png" 2>/dev/null || true
}

# steam_vdf add|remove|list ARCHIVO → edita shortcuts.vdf; imprime "appid_sin_signo clave" de cada entrada
steam_vdf() {
    python3 - "$@" "$LAUNCHER" "$SC_ROOT" "$STEAM_ART/icon.png" "$DESKTOP_FILE" "$DESKTOP_FILE_NV" <<'PY'
import os, struct, sys, zlib
mode, path, launcher, root, icon, desk, desk_nv = sys.argv[1:8]

def parse(d, i):                        # mapa VDF binario → lista de (tipo, clave, valor), índice
    out = []
    while True:
        t = d[i]; i += 1
        if t == 8:
            return out, i
        j = d.index(b'\0', i); k = d[i:j].decode('utf-8', 'surrogateescape'); i = j + 1
        if t == 0:   v, i = parse(d, i)
        elif t == 1: j = d.index(b'\0', i); v = d[i:j].decode('utf-8', 'surrogateescape'); i = j + 1
        elif t == 2: v = struct.unpack_from('<i', d, i)[0]; i += 4
        elif t == 7: v = struct.unpack_from('<Q', d, i)[0]; i += 8
        else: raise SystemExit(f'shortcuts.vdf: tipo {t} desconocido')
        out.append((t, k, v))

def dump(m):
    b = bytearray()
    for t, k, v in m:
        b += bytes([t]) + k.encode('utf-8', 'surrogateescape') + b'\0'
        if t == 0:   b += dump(v) + b'\x08'
        elif t == 1: b += v.encode('utf-8', 'surrogateescape') + b'\0'
        elif t == 2: b += struct.pack('<i', v)
        elif t == 7: b += struct.pack('<Q', v)
    return bytes(b)

get = lambda m, k, dflt=None: next((v for _, kk, v in m if kk.lower() == k.lower()), dflt)
def put(m, t, k, v):
    for n, (_, kk, _) in enumerate(m):
        if kk.lower() == k.lower():
            m[n] = (t, kk, v); return
    m.append((t, k, v))

top = [(0, 'shortcuts', [])]
if os.path.exists(path) and os.path.getsize(path):
    top, _ = parse(open(path, 'rb').read(), 0)
shortcuts = get(top, 'shortcuts')
if shortcuts is None:
    shortcuts = []; top.append((0, 'shortcuts', shortcuts))

def key(e):                             # 'normal' | 'sin-videos' | None (otro juego)
    if get(e, 'Exe', '').strip('"') != launcher:
        return None
    return 'sin-videos' if '--sin-videos' in get(e, 'LaunchOptions', '') else 'normal'

entries = [v for _, _, v in shortcuts]
if mode == 'add':
    specs = {'normal': ('Space Clash: The Last Frontier', '', desk),
             'sin-videos': ('Space Clash (sin vídeos)', '--sin-videos', desk_nv)}
    for k, (name, opts, sc) in specs.items():
        e = next((e for e in entries if key(e) == k), None)
        if e is None:
            exe = f'"{launcher}"'
            appid = (zlib.crc32((exe + name).encode()) | 0x80000000) - (1 << 32)   # estable; bit alto = no es de Steam
            e = [(2, 'appid', appid), (1, 'appname', name), (1, 'Exe', exe), (1, 'StartDir', ''),
                 (1, 'icon', ''), (1, 'ShortcutPath', ''), (1, 'LaunchOptions', ''), (2, 'IsHidden', 0),
                 (2, 'AllowDesktopConfig', 1), (2, 'AllowOverlay', 1), (2, 'OpenVR', 0), (2, 'Devkit', 0),
                 (1, 'DevkitGameID', ''), (2, 'DevkitOverrideAppID', 0), (2, 'LastPlayTime', 0),
                 (1, 'FlatpakAppID', ''), (1, 'sortas', ''), (0, 'tags', [])]
            entries.append(e)
        put(e, 1, 'appname', name)
        put(e, 1, 'StartDir', f'"{root}/"')
        put(e, 1, 'icon', icon if os.path.exists(icon) else '')
        put(e, 1, 'ShortcutPath', sc if os.path.exists(sc) else '')
        put(e, 1, 'LaunchOptions', opts)
elif mode == 'remove':
    entries = [e for e in entries if key(e) is None]
for e in entries:
    if key(e) and mode != 'remove':
        print(get(e, 'appid') & 0xffffffff, key(e))
if mode != 'list':
    shortcuts[:] = [(0, str(n), e) for n, e in enumerate(entries)]
    with open(path + '.tmp', 'wb') as f:
        f.write(dump(top) + b'\x08')
    os.replace(path + '.tmp', path)
PY
}

setup_steam() {
    [[ "$SC_STEAM" == 1 ]] || return 0
    local dirs; dirs=$(steam_dirs)
    if [[ -z "$dirs" ]]; then
        [[ -d "$HOME/.var/app/com.valvesoftware.Steam" ]] \
            && warn "Steam de Flatpak no puede ejecutar el Wine del sistema: no se agregó el juego a la biblioteca."
        return 0
    fi
    log "Agregando el juego a la biblioteca de Steam…"
    steam_close || return 0
    steam_art
    local cfg ids id k n=0
    art() { [[ -f "$STEAM_ART/$1.png" ]] && cp "$STEAM_ART/$1.png" "$cfg/grid/$id$2.png" || true; }
    while read -r cfg; do
        [[ -f "$cfg/shortcuts.vdf" && ! -f "$cfg/shortcuts.vdf.antes-spaceclash" ]] \
            && cp -p "$cfg/shortcuts.vdf" "$cfg/shortcuts.vdf.antes-spaceclash"
        ids=$(steam_vdf add "$cfg/shortcuts.vdf") || { warn "No pude editar $cfg/shortcuts.vdf"; continue; }
        mkdir -p "$cfg/grid"
        while read -r id k; do
            art portrait p; art wide ""; art hero _hero   # portada, cápsula ancha, cabecera
        done <<<"$ids"
        ((++n))
    done <<<"$dirs"
    ((n)) && ok "En la biblioteca de Steam: «Space Clash: The Last Frontier» y «Space Clash (sin vídeos)» ($n cuenta(s))" || true
}

remove_steam() {
    local cfg ids id k n=0
    while read -r cfg; do
        [[ -f "$cfg/shortcuts.vdf" ]] || continue
        ids=$(steam_vdf list "$cfg/shortcuts.vdf" 2>/dev/null) || continue
        [[ -n "$ids" ]] || continue
        if steam_running; then
            warn "Steam está abierto: quitá «Space Clash» de la biblioteca a mano (o cerralo y volvé a desinstalar)."
            return 0
        fi
        while read -r id k; do rm -f "$cfg/grid/$id"{p,,_hero}.png; done <<<"$ids"
        steam_vdf remove "$cfg/shortcuts.vdf" && ((++n)) || warn "No pude editar $cfg/shortcuts.vdf"
    done < <(steam_dirs)
    ((n)) && ok "Quitado de la biblioteca de Steam" || true
}

# --------------------------------------------------------------------------- #
#  Subcomandos
# --------------------------------------------------------------------------- #
cmd_install() {
    if pgrep -x 'SC.EXE|CLASH.EXE|SPACE.EXE|Space.exe' >/dev/null 2>&1; then
        die "El juego está abierto. Cerralo antes de instalar/actualizar (si quedó colgado: WINEPREFIX=\"$WINEPREFIX\" wineserver -k)."
    fi
    [[ "$SC_SCALING" =~ ^(fit|integer)$ ]] || die "SC_SCALING inválido: $SC_SCALING (fit|integer)"
    [[ "$SC_FILTER" =~ ^(auto|nearest|sharp|smooth|xbr|crt)$ ]] || die "SC_FILTER inválido: $SC_FILTER (auto|nearest|sharp|smooth|xbr|crt)"
    [[ "$SC_GAME_RES" =~ ^(auto|keep|640|800|1024)$ ]] || die "SC_GAME_RES inválido: $SC_GAME_RES (auto|keep|640|800|1024)"
    log "Instalando Space Clash en $SC_ROOT"
    check_res
    resolve_videos
    check_deps
    if [[ -f "$CD_DIR/UNCLASH.EXE" && ( "${FORCE:-0}" != 1 || "${KEEP_CD:-0}" == 1 ) ]]; then
        ok "CD ya extraído en $CD_DIR (no hace falta la imagen)"
    else
        verify_image
        bin_to_iso
        extract_cd
    fi
    create_prefix
    install_files
    set_import_name GDI32.dll   # los parches 5b se verifican sobre el EXE sin el runtime
    apply_patches
    setup_runtime
    setup_ddraw
    set_game_res
    setup_videos_ai
    setup_videos
    create_launcher
    setup_steam
    echo
    ok "Instalación completa."
    echo "   Ejecutar:   $LAUNCHER"
    echo "   o bien:     $0 run --root \"$SC_ROOT\""
    echo "   Logs:       $LOG_DIR/wine.log"
    echo "   Config gfx: $GAME_DIR/ddraw.ini"
}

# Reinstalación completa: todo lo de install --force (imagen, CD, prefijo, archivos, parches, runtime,
# cnc-ddraw, vídeos) y además la configuración como en una instalación nueva: scenh.ini de cero con la
# resolución del monitor detectada otra vez, el juego en 1024x768 y la pregunta de los vídeos. Se
# conservan las partidas (*.sav, *.nfo), CLASH.CFG (salvo la resolución) y el máster de vídeo con IA.
cmd_reinstall() {
    [[ -d "$SC_ROOT" ]] || { log "No hay una instalación en $SC_ROOT: se hace una instalación nueva"; cmd_install; return; }
    log "Reinstalación completa en $SC_ROOT (se conservan las partidas)"
    FORCE=1; REINSTALL=1
    if [[ -f "$CD_DIR/UNCLASH.EXE" ]] && ! (resolve_image) >/dev/null 2>&1; then
        KEEP_CD=1
        warn "No encontré la imagen del CD: se conserva el CD ya extraído en $CD_DIR"
    fi
    cmd_install
}

cmd_steam() {
    [[ -x "$LAUNCHER" ]] || die "No está instalado. Ejecutá: $0 install"
    [[ -n "$(steam_dirs)" ]] || die "No encontré Steam (se busca en ~/.local/share/Steam; el de Flatpak no sirve)"
    SC_STEAM=1 setup_steam
}

cmd_run() {
    [[ -x "$LAUNCHER" ]] || die "No está instalado. Ejecutá: $0 install"
    exec "$LAUNCHER" "$@"
}

cmd_doctor() {
    trap - ERR
    local rc=0
    echo "SC_ROOT     = $SC_ROOT"
    echo "WINEPREFIX  = $WINEPREFIX"
    echo "Wine        = $("$SC_WINE" --version 2>/dev/null || echo 'NO ENCONTRADO')"
    chk() { if eval "$2"; then ok "$1"; else warn "$1"; rc=1; fi; }
    chk "CD extraído (UNCLASH.EXE en la raíz)"     "[[ -f \"$CD_DIR/UNCLASH.EXE\" ]]"
    chk "CD contiene MUSICAS y VIDEOS"             "[[ -d \"$CD_DIR/MUSICAS\" && -d \"$CD_DIR/VIDEOS\" ]]"
    chk "Prefijo creado"                           "[[ -f \"$WINEPREFIX/system.reg\" ]]"
    local L="${SC_CD_LETTER,,}"
    chk "dosdevices/$L: → CD"                       "[[ \"\$(readlink \"$WINEPREFIX/dosdevices/$L:\")\" == \"$CD_DIR\" ]]"
    chk "${L^^}: declarada como cdrom"                  "grep -qi '\"$L:\"=\"cdrom\"' \"$WINEPREFIX/system.reg\""
    chk "Versión de Windows = winxp"               "grep -qi '\"Version\"=\"winxp\"' \"$WINEPREFIX/user.reg\""
    chk "SC.EXE / CLASH.EXE / SPACE.EXE (mayúsc.)" "[[ -f \"$GAME_DIR/SC.EXE\" && -f \"$GAME_DIR/CLASH.EXE\" && -f \"$GAME_DIR/SPACE.EXE\" ]]"
    chk "Animaciones ANI/*.FLC"                    "(( \$(ls \"$GAME_DIR/ANI\" 2>/dev/null | wc -l) > 300 ))"
    if [[ "$SC_PATCH" == 1 ]]; then
        local e f orig final rest
        local rt=0 off h
        [[ -f "$GAME_DIR/scenh.dll" && $(import_name "$GAME_DIR/CLASH.EXE" 0x806d4) == SCENH.dll ]] && rt=1
        for e in "${PATCHES[@]}"; do
            IFS='|' read -r f orig final rest <<<"$e"
            if ((rt)); then
                for h in "${RUNTIME_IMPORTS[@]}"; do [[ $h == "$f|"* ]] && IFS='|' read -r _ off final <<<"$h"; done
            fi
            chk "$f parcheado$( ((rt)) && echo ' (con runtime)')" "[[ \$(sha256sum \"$GAME_DIR/$f\" | cut -c1-64) == $final ]]"
        done
        if ((rt)); then
            ok "Runtime de mejoras activo (scenh.dll; opciones en scenh.ini$([[ -f "$GAME_DIR/scenh.log" ]] && echo '; registro en scenh.log'))"
            local res; res=$(awk -F= '/^\[/{f=($0=="[resolucion]")} f&&$1=="activar"{a=$2} f&&$1=="ancho"{w=$2} f&&$1=="alto"{h=$2} END{if(a==1)print w"x"h}' "$GAME_DIR/scenh.ini")
            [[ -n "$res" ]] && echo "    Resolución panorámica (experimental): $res en lugar de 1024x768"
        else
            echo "    Runtime de mejoras: no instalado (ver --no-runtime en la ayuda)"
        fi
    fi
    if [[ -f "$GAME_DIR/ddraw.dll" ]]; then
        chk "Override ddraw=native para CLASH.EXE" "grep -A2 -i 'AppDefaults\\\\\\\\CLASH.EXE\\\\\\\\DllOverrides' \"$WINEPREFIX/user.reg\" | grep -qi native"
    else
        echo "    Modo de pantalla: window (cnc-ddraw no instalado: se usa wined3d)"
    fi
    if [[ -f "$GAME_DIR/ddraw.dll" ]]; then
        echo "    Modo de pantalla: scaled ($(awk '/^\[ddraw\]/{f=1;next} /^\[/{f=0} f&&/^(renderer|boxing|shader)=/{printf "%s%s", s, $0; s="; "}' "$GAME_DIR/ddraw.ini"))"
        chk "Vídeo: renderer GDI preferido (mérito VMR bajado)" \
            "grep -A3 -i 'Instance\\\\\\\\{6BC1CFFA' \"$WINEPREFIX/system.reg\" | grep -qi 'filterdata\"=hex:02,00,00,00,00,00,20,00'"
        if [[ -f "$CD_DIR/VIDEOS/.fit" ]]; then
            ok "Vídeos adaptados a la pantalla ($(cat "$CD_DIR/VIDEOS/.fit"); originales en cd/VIDEOS/ORIG)"
        else
            echo "    Vídeos: originales (se ven estirados a lo ancho; ver --videos)"
        fi
        [[ -f "$SC_ROOT/videos-hd/manifest.json" ]] && \
            echo "    Máster de vídeo escalado con IA: $SC_ROOT/videos-hd (tools/upscale-videos.py)"
        have ffmpeg || echo "    ffmpeg no instalado (necesario para adaptar los vídeos)"
    fi
    if [[ -f "$GAME_DIR/CDSC.INS" ]]; then echo "    CDSC.INS = $(cat "$GAME_DIR/CDSC.INS")"; fi
    [[ -f "$GAME_DIR/CLASH.CFG" ]] && echo "    Resolución del juego: $(game_res_name) (Opciones del juego o --game-res)"
    if [[ "$(pkg_family)" == apt && "$SC_WINE" == wine ]]; then   # Ubuntu/Debian: lo que usa el Wine de 32 bits
        chk "wine32 (i386)"                        "[[ -z \"\$(apt_missing wine32:i386)\" ]]"
        chk "GStreamer de 32 bits (bad, ugly, libav)" "[[ -z \"\$(apt_missing gstreamer1.0-plugins-bad:i386 gstreamer1.0-plugins-ugly:i386 gstreamer1.0-libav:i386)\" ]]"
    elif have gst-inspect-1.0; then
        chk "GStreamer mpegpsdemux"                "gst-inspect-1.0 mpegpsdemux >/dev/null 2>&1"
        chk "GStreamer decodificador MPEG-1"       "gst-inspect-1.0 avdec_mpeg2video >/dev/null 2>&1 || gst-inspect-1.0 mpeg2dec >/dev/null 2>&1"
    fi
    if [[ -n "$(steam_dirs)" ]]; then
        if steam_dirs | while read -r c; do steam_vdf list "$c/shortcuts.vdf" 2>/dev/null; done | grep -q .; then
            echo "    En la biblioteca de Steam"
        else
            echo "    No está en la biblioteca de Steam (con Steam cerrado: $0 steam)"
        fi
    fi
    return $rc
}

cmd_uninstall() {
    [[ -d "$SC_ROOT" ]] || { ok "Nada que desinstalar en $SC_ROOT"; return; }
    local saves=() g f backup=""
    for g in "${SAVE_GLOBS[@]}"; do
        for f in "$GAME_DIR"/$g; do [[ -f "$f" ]] && saves+=("$f"); done
    done
    if ((${#saves[@]})) && [[ "${NO_BACKUP:-0}" != 1 ]]; then
        backup="$(dirname "$SC_ROOT")/space-clash-partidas-$(date +%Y%m%d-%H%M%S)"
        echo "Se eliminará $SC_ROOT. Las partidas se copian antes a $backup"
    else
        echo "Se eliminará $SC_ROOT (prefijo, CD extraído, ISO y ${#saves[@]} archivo(s) de partidas)."
    fi
    read -r -p "¿Continuar? [s/N] " a
    [[ "$a" =~ ^[sSyY]$ ]] || { echo "Cancelado."; return; }
    WINEPREFIX="$WINEPREFIX" wineserver -k 2>/dev/null || true
    if [[ -n "$backup" ]]; then
        mkdir -p "$backup" && cp -p "${saves[@]}" "$backup/" || die "No pude copiar las partidas a $backup; no se borró nada."
        ok "Partidas copiadas a $backup (para recuperarlas, copialas a $GAME_DIR después de instalar)"
    fi
    remove_steam
    rm -rf "$SC_ROOT" "$DESKTOP_FILE" "$DESKTOP_FILE_NV" "$ICON_FILE"
    ok "Desinstalado."
}

usage() {
    cat <<EOF
Uso: $0 <comando> [opciones]

Comandos:
  install      Verifica la imagen, la convierte a ISO, crea el prefijo y copia el juego. Sobre una
               instalación existente la actualiza y conserva las opciones elegidas
  reinstall    Reinstalación completa: rehace todo y vuelve a configurar como una instalación nueva
               (detecta otra vez la resolución del monitor, scenh.ini de cero, pregunta por los vídeos).
               Conserva las partidas; las opciones anteriores del runtime quedan en scenh.ini.anterior
  run          Ejecuta el juego
  steam        Agrega el juego a la biblioteca de Steam, con portada e icono (install ya lo hace;
               hay que cerrar Steam, el instalador ofrece cerrarlo)
  doctor       Diagnostica la instalación
  uninstall    Borra todo lo instalado (pide confirmación; antes copia las partidas)
  help         Esta ayuda

Opciones (o variables de entorno equivalentes):
  --root DIR          Directorio de instalación          (SC_ROOT, def: ~/Games/space-clash)
  --image FILE        Imagen del CD: .cue/.bin/.iso       (SC_IMAGE, def: la que haya en disk/)
  --wine BIN          Binario de Wine                     (SC_WINE, def: wine)
  --display MODO      scaled = pantalla completa 4:3 escalada (cnc-ddraw)
                      window = ventana del tamaño original (DirectDraw de Wine)
                                                          (SC_DISPLAY, def: scaled)
  --renderer R        Renderer de cnc-ddraw: opengl|gdi|auto (SC_RENDERER, def: opengl)
                      Si se ve negro, usar gdi (sin filtros)
  --scaling MODO      fit = llenar el alto de la pantalla en 4:3
                      integer = solo factores enteros (más nítido, más borde)
                                                          (SC_SCALING, def: fit)
  --filter F          Filtro de escalado (renderer opengl):
                      auto|nearest|sharp|smooth|xbr|crt   (SC_FILTER, def: auto =
                      sharp con fit, nearest con integer)
  --game-res R        Resolución del juego: auto|keep|640|800|1024 (SC_GAME_RES, def: auto
                      = 1024 en una instalación nueva; al reinstalar se conserva la elegida)
                      1024 = más área del mapa visible
  --no-patch          No aplicar el parche de compatibilidad (SC_PATCH=0)
  --res auto|WxH|off  Pantalla panorámica (experimental): la partida en WxH en lugar de 1024x768,
                      con más mapa visible; requiere el runtime. auto = la del monitor en una
                      instalación nueva o con reinstall (install conserva la anterior);
                      off = 4:3 original (SC_RES, def: auto)
  --no-runtime        Sin el runtime de mejoras scenh.dll (velocidad con +/-, menos CPU) (SC_RUNTIME=0)
  --no-vdesktop       Sin escritorio virtual de Wine      (SC_VDESKTOP=0)
  --vdesktop-res WxH  Tamaño del escritorio virtual       (SC_VDESKTOP_RES, def: auto)
  --gamescope         Envolver con gamescope (escalado)   (SC_GAMESCOPE=1)
  --cd-letter X       Letra del CD virtual                (SC_CD_LETTER, def: r)
  --full              Copia también MUSICAS y VIDEOS al disco (SC_FULL=1)
  --videos MODO       ask = preguntar en una instalación nueva (al reinstalar se conserva lo elegido)
                      fit = vídeos 4:3 con barras a pantalla completa (requiere ffmpeg)
                      original = vídeos sin tocar (estirados en modo scaled)
                                                          (SC_VIDEOS, def: ask)
  --videos-ai M       Escalado de los vídeos con IA (una vez; requiere Python con PyTorch y
                      spandrel, ideal con GPU NVIDIA): ask|off|general|general-sharp|x4plus
                      ask = preguntar al instalar (respuesta por defecto: no)
                                                          (SC_VIDEOS_AI, def: ask)
                      También: python3 tools/upscale-videos.py --root DIR (en cualquier momento)
  --no-desktop        No crear acceso directo .desktop    (SC_DESKTOP=0)
  --no-steam          No agregar el juego a Steam         (SC_STEAM=0)
  --install-deps      Instala dependencias si faltan (pacman en Arch/CachyOS, apt en Ubuntu/Debian)
  --skip-hash         No verificar SHA-256 de la imagen
  --force             Rehace ISO, extracción y configuración aunque existan
  --no-backup         uninstall: no copiar las partidas antes de borrar
EOF
}

# --------------------------------------------------------------------------- #
#  Parseo de argumentos
# --------------------------------------------------------------------------- #
CMD="${1:-help}"; shift || true
while (($#)); do
    case "$1" in
        --root)         SC_ROOT=$2; shift ;;
        --image|--bin)  SC_IMAGE=$2; shift ;;
        --wine)         SC_WINE=$2; shift ;;
        --display)      SC_DISPLAY=$2; shift ;;
        --renderer)     SC_RENDERER=$2; shift ;;
        --scaling)      SC_SCALING=$2; shift ;;
        --filter)       SC_FILTER=$2; shift ;;
        --game-res)     SC_GAME_RES=$2; shift ;;
        --ddraw)        [[ $2 == cnc ]] && SC_DISPLAY=scaled || SC_DISPLAY=window; shift ;;   # compatibilidad
        --cd-letter)    SC_CD_LETTER=$2; shift ;;
        --no-patch)     SC_PATCH=0 ;;
        --no-runtime)   SC_RUNTIME=0 ;;
        --res)          SC_RES=$2; shift ;;
        --no-vdesktop)  SC_VDESKTOP=0 ;;
        --vdesktop-res) SC_VDESKTOP_RES=$2; shift ;;
        --gamescope)    SC_GAMESCOPE=1 ;;
        --full)         SC_FULL=1 ;;
        --videos)       SC_VIDEOS=$2; shift ;;
        --videos-ai)    SC_VIDEOS_AI=$2; shift ;;
        --no-desktop)   SC_DESKTOP=0 ;;
        --no-steam)     SC_STEAM=0 ;;
        --install-deps) INSTALL_DEPS=1 ;;
        --skip-hash)    SKIP_HASH=1 ;;
        --force)        FORCE=1 ;;
        --no-backup)    NO_BACKUP=1 ;;
        *) [[ "$CMD" == run ]] && break || die "Opción desconocida: $1" ;;
    esac
    shift
done
# Recalcular rutas derivadas si cambió --root
ISO_PATH="$SC_ROOT/media/SPACE_CLASH.iso"; CD_DIR="$SC_ROOT/cd"
export WINEPREFIX="$SC_ROOT/prefix"; GAME_DIR="$WINEPREFIX/drive_c/SCLASH"
LAUNCHER="$SC_ROOT/spaceclash.sh"; LOG_DIR="$SC_ROOT/logs"; NOVID_DIR="$SC_ROOT/cd-sin-videos"
STEAM_ART="$SC_ROOT/steam"

case "$CMD" in
    install)   cmd_install ;;
    reinstall) cmd_reinstall ;;
    run)       cmd_run "$@" ;;
    steam)     cmd_steam ;;
    doctor)    cmd_doctor ;;
    uninstall) cmd_uninstall ;;
    help|-h|--help) usage ;;
    *) usage; exit 1 ;;
esac
