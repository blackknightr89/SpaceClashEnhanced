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
SC_RENDERER="${SC_RENDERER:-gdi}"                       # renderer de cnc-ddraw en modo scaled: gdi | opengl | auto
SC_PATCH="${SC_PATCH:-1}"                               # 1 = aplicar parches de compatibilidad (ver sección 5b)
SC_VDESKTOP="${SC_VDESKTOP:-1}"                         # 1 = ejecutar en escritorio virtual de Wine
SC_VDESKTOP_RES="${SC_VDESKTOP_RES:-auto}"              # tamaño del escritorio virtual (auto = monitor en scaled, 1024x768 en window)
SC_GAMESCOPE="${SC_GAMESCOPE:-0}"                       # 1 = envolver con gamescope (escalado a pantalla completa)
SC_FULL="${SC_FULL:-0}"                                 # 1 = copiar música y vídeos al disco
SC_DESKTOP="${SC_DESKTOP:-1}"                           # 1 = crear acceso directo .desktop
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
PACMAN_PKGS=(wine 7zip python unzip curl imagemagick
             gst-plugins-base gst-plugins-good gst-plugins-bad gst-plugins-ugly gst-libav)

check_deps() {
    local missing=()
    for bin in "$SC_WINE" 7z python3 unzip curl; do
        have "$bin" || missing+=("$bin")
    done
    if ((${#missing[@]})); then
        warn "Faltan comandos: ${missing[*]}"
        if [[ "${INSTALL_DEPS:-0}" == 1 ]] && have pacman; then
            log "Instalando dependencias con pacman (pedirá contraseña de sudo)…"
            sudo pacman -S --needed "${PACMAN_PKGS[@]}"
        else
            die "Instalá las dependencias: sudo pacman -S --needed ${PACMAN_PKGS[*]}
       (o re-ejecutá con --install-deps)"
        fi
    fi
    # GStreamer: necesario para los vídeos MPEG-1 (DirectShow → winegstreamer)
    if have gst-inspect-1.0; then
        gst-inspect-1.0 mpegpsdemux >/dev/null 2>&1 || warn "Falta el plugin GStreamer 'mpegpsdemux' (gst-plugins-bad). Los vídeos podrían no reproducirse."
        gst-inspect-1.0 mpeg2dec     >/dev/null 2>&1 || gst-inspect-1.0 avdec_mpeg2video >/dev/null 2>&1 \
            || warn "Falta decodificador MPEG-1 (gst-libav o gst-plugins-ugly). Los vídeos podrían no reproducirse."
    else
        warn "gst-inspect-1.0 no encontrado: no se puede verificar GStreamer (vídeos)."
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
            log "Quitado el mapeo anterior del CD en ${old^^}:"
        fi
    done
    ln -sfn "$CD_DIR" "$WINEPREFIX/dosdevices/$L:"
    wine_q reg add 'HKLM\Software\Wine\Drives' /v "$L:" /d cdrom /f
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
install_files() {
    log "Copiando archivos del juego a $GAME_DIR…"
    mkdir -p "$GAME_DIR"
    local f d
    for f in SC.EXE CLASH.EXE SPACE.EXE UNCLASH.EXE \
             PALCF.DAT PALCS.DAT PALS.DAT PALT020.DAT PALT030.DAT PALT040.DAT ICON.ICO; do
        install -m 0644 "$CD_DIR/$f" "$GAME_DIR/$f"
    done
    # Opciones del juego: solo la primera vez (una reinstalación conserva las del usuario).
    # Las partidas (*.sav) nunca se tocan.
    [[ -f "$GAME_DIR/CLASH.CFG" ]] || install -m 0644 "$CD_DIR/CLASH.CFG" "$GAME_DIR/CLASH.CFG"
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
#      vídeos se ven COMPLETOS pero ESTIRADOS a 16:9; el juego queda en 4:3.
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
    log "Modo de pantalla: scaled (cnc-ddraw, pantalla completa 4:3)…"
    local cache="$SC_ROOT/media/cnc-ddraw.zip" tmp
    if [[ ! -f "$cache" ]]; then
        mkdir -p "$(dirname "$cache")"
        curl -fsSL --retry 3 -o "$cache.part" "$SC_CNC_URL" || die "No se pudo descargar cnc-ddraw ($SC_CNC_URL). Usá --display window o descargalo a mano en $cache"
        mv "$cache.part" "$cache"
    fi
    tmp=$(mktemp -d); unzip -q -o "$cache" -d "$tmp"
    install -m 0644 "$tmp/ddraw.dll" "$GAME_DIR/ddraw.dll"
    install -m 0644 "$tmp/ddraw.ini" "$GAME_DIR/ddraw.ini"
    sed -i 's/\r$//' "$GAME_DIR/ddraw.ini"      # viene con CRLF; ini_set trabaja con LF
    rm -rf "$tmp"
    ini_set fullscreen   true      # ventana sin bordes del tamaño del escritorio virtual
    ini_set windowed     false
    ini_set maintas      true      # mantener 4:3 (barras negras a los lados)
    ini_set boxing       false     # true = solo escalado entero (más nítido, más borde)
    ini_set width        0
    ini_set height       0
    ini_set renderer     "$SC_RENDERER"
    ini_set adjmouse     true      # traducir coordenadas del ratón al modo del juego
    ini_set vsync        false
    ini_set devmode      false
    ini_set savesettings 0
    for a in "${apps[@]}"; do
        wine_q reg add "HKCU\\Software\\Wine\\AppDefaults\\$a\\DllOverrides" /v ddraw /d native,builtin /f
    done
    set_vmr_merit low
    "$SC_WINE"server -w 2>/dev/null || wineserver -w
    ok "cnc-ddraw configurado (renderer=$SC_RENDERER; ajustes en $GAME_DIR/ddraw.ini, sección [ddraw])"
}

ini_set() {   # ini_set clave valor → fija "clave=valor" SOLO dentro de la sección [ddraw]
    local k=$1 v=$2 ini="$GAME_DIR/ddraw.ini" tmp
    tmp=$(mktemp)
    awk -v k="$k" -v v="$v" '
        /^\[/ { if (insec && !done) { print k "=" v; done=1 } insec = ($0 == "[ddraw]") }
        insec && $0 ~ "^[;[:space:]]*" k "[[:space:]]*=" { if (!done) { print k "=" v; done=1 }; next }
        { print }
        END { if (insec && !done) print k "=" v }
    ' "$ini" > "$tmp" && mv "$tmp" "$ini" && chmod 0644 "$ini"
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
        SC_VDESKTOP_RES=\$(xrandr --current 2>/dev/null | awk '/\*/{print \$1; exit}')
        [[ "\$SC_VDESKTOP_RES" =~ ^[0-9]+x[0-9]+\$ ]] || SC_VDESKTOP_RES=1920x1080
    else
        SC_VDESKTOP_RES=1024x768
    fi
fi
SC_GAMESCOPE="\${SC_GAMESCOPE:-$SC_GAMESCOPE}"
cd "$GAME_DIR" || exit 1
# SC.EXE detecta el CD virtual, escribe CDSC.INS y lanza CLASH.EXE.
# Ruta completa obligatoria: dentro de explorer, "SC.EXE" a secas resuelve al
# sc.exe de sistema (control de servicios) en vez del lanzador del juego.
cmd=("\$SC_WINE")
if [[ "\$SC_VDESKTOP" == 1 ]]; then
    # Escritorio virtual: evita que la ventana a pantalla completa se minimice
    # al perder el foco tras los vídeos, y no cambia la resolución del monitor.
    cmd+=(explorer "/desktop=SpaceClash,\$SC_VDESKTOP_RES")
fi
cmd+=('C:\SCLASH\SC.EXE' "\$@")
# gamescope: alternativa NO verificada para escalar el modo "window" (requiere: pacman -S gamescope)
if [[ "\$SC_GAMESCOPE" == 1 ]] && command -v gamescope >/dev/null; then
    cmd=(gamescope -w 640 -h 480 -f -S fit -- "\${cmd[@]}")
fi
echo "=== \$(date '+%F %T') \${cmd[*]}" >>"$LOG_DIR/wine.log"
exec "\${cmd[@]}" >>"$LOG_DIR/wine.log" 2>&1
EOF
    chmod +x "$LAUNCHER"

    if [[ "$SC_DESKTOP" == 1 ]]; then
        mkdir -p "$(dirname "$DESKTOP_FILE")" "$(dirname "$ICON_FILE")"
        if have magick; then
            magick "$GAME_DIR/ICON.ICO[0]" -resize 48x48 "$ICON_FILE" 2>/dev/null || true
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
        have update-desktop-database && update-desktop-database "$(dirname "$DESKTOP_FILE")" >/dev/null 2>&1 || true
        ok "Acceso directo: $DESKTOP_FILE"
    fi
}

# --------------------------------------------------------------------------- #
#  Subcomandos
# --------------------------------------------------------------------------- #
cmd_install() {
    if pgrep -x 'SC.EXE|CLASH.EXE|SPACE.EXE|Space.exe' >/dev/null 2>&1; then
        die "El juego está abierto. Cerralo antes de instalar/actualizar (si quedó colgado: WINEPREFIX=\"$WINEPREFIX\" wineserver -k)."
    fi
    log "Instalando Space Clash en $SC_ROOT"
    check_deps
    if [[ -f "$CD_DIR/UNCLASH.EXE" && "${FORCE:-0}" != 1 ]]; then
        ok "CD ya extraído en $CD_DIR (no hace falta la imagen)"
    else
        verify_image
        bin_to_iso
        extract_cd
    fi
    create_prefix
    install_files
    apply_patches
    setup_ddraw
    create_launcher
    echo
    ok "Instalación completa."
    echo "   Ejecutar:   $LAUNCHER"
    echo "   o bien:     $0 run --root \"$SC_ROOT\""
    echo "   Logs:       $LOG_DIR/wine.log"
    echo "   Config gfx: $GAME_DIR/ddraw.ini"
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
        for e in "${PATCHES[@]}"; do
            IFS='|' read -r f orig final rest <<<"$e"
            chk "$f parcheado"                     "[[ \$(sha256sum \"$GAME_DIR/$f\" | cut -c1-64) == $final ]]"
        done
    fi
    if [[ -f "$GAME_DIR/ddraw.dll" ]]; then
        chk "Override ddraw=native para CLASH.EXE" "grep -A2 -i 'AppDefaults\\\\\\\\CLASH.EXE\\\\\\\\DllOverrides' \"$WINEPREFIX/user.reg\" | grep -qi native"
    else
        echo "    Modo de pantalla: window (cnc-ddraw no instalado: se usa wined3d)"
    fi
    if [[ -f "$GAME_DIR/ddraw.dll" ]]; then
        echo "    Modo de pantalla: scaled ($(awk '/^\[ddraw\]/{f=1;next} /^\[/{f=0} f&&/^renderer=/{print; exit}' "$GAME_DIR/ddraw.ini"))"
        chk "Vídeo: renderer GDI preferido (mérito VMR bajado)" \
            "grep -A3 -i 'Instance\\\\\\\\{6BC1CFFA' \"$WINEPREFIX/system.reg\" | grep -qi 'filterdata\"=hex:02,00,00,00,00,00,20,00'"
    fi
    if [[ -f "$GAME_DIR/CDSC.INS" ]]; then echo "    CDSC.INS = $(cat "$GAME_DIR/CDSC.INS")"; fi
    if have gst-inspect-1.0; then
        chk "GStreamer mpegpsdemux"                "gst-inspect-1.0 mpegpsdemux >/dev/null 2>&1"
        chk "GStreamer decodificador MPEG-1"       "gst-inspect-1.0 avdec_mpeg2video >/dev/null 2>&1 || gst-inspect-1.0 mpeg2dec >/dev/null 2>&1"
    fi
    return $rc
}

cmd_uninstall() {
    [[ -d "$SC_ROOT" ]] || { ok "Nada que desinstalar en $SC_ROOT"; return; }
    read -r -p "¿Eliminar $SC_ROOT (prefijo, CD extraído, ISO y partidas guardadas)? [s/N] " a
    [[ "$a" =~ ^[sSyY]$ ]] || { echo "Cancelado."; return; }
    WINEPREFIX="$WINEPREFIX" wineserver -k 2>/dev/null || true
    rm -rf "$SC_ROOT" "$DESKTOP_FILE" "$ICON_FILE"
    ok "Desinstalado."
}

usage() {
    cat <<EOF
Uso: $0 <comando> [opciones]

Comandos:
  install      Verifica la imagen, la convierte a ISO, crea el prefijo y copia el juego
  run          Ejecuta el juego
  doctor       Diagnostica la instalación
  uninstall    Borra todo lo instalado (pide confirmación)
  help         Esta ayuda

Opciones (o variables de entorno equivalentes):
  --root DIR          Directorio de instalación          (SC_ROOT, def: ~/Games/space-clash)
  --image FILE        Imagen del CD: .cue/.bin/.iso       (SC_IMAGE, def: la que haya en disk/)
  --wine BIN          Binario de Wine                     (SC_WINE, def: wine)
  --display MODO      scaled = pantalla completa 4:3 escalada (cnc-ddraw)
                      window = ventana del tamaño original (DirectDraw de Wine)
                                                          (SC_DISPLAY, def: scaled)
  --renderer R        Renderer de cnc-ddraw: gdi|opengl|auto (SC_RENDERER, def: gdi)
  --no-patch          No aplicar el parche de compatibilidad (SC_PATCH=0)
  --no-vdesktop       Sin escritorio virtual de Wine      (SC_VDESKTOP=0)
  --vdesktop-res WxH  Tamaño del escritorio virtual       (SC_VDESKTOP_RES, def: auto)
  --gamescope         Envolver con gamescope (escalado)   (SC_GAMESCOPE=1)
  --cd-letter X       Letra del CD virtual                (SC_CD_LETTER, def: r)
  --full              Copia también MUSICAS y VIDEOS al disco (SC_FULL=1)
  --no-desktop        No crear acceso directo .desktop    (SC_DESKTOP=0)
  --install-deps      Instala dependencias con pacman si faltan
  --skip-hash         No verificar SHA-256 de la imagen
  --force             Rehace ISO, extracción y configuración aunque existan
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
        --ddraw)        [[ $2 == cnc ]] && SC_DISPLAY=scaled || SC_DISPLAY=window; shift ;;   # compatibilidad
        --cd-letter)    SC_CD_LETTER=$2; shift ;;
        --no-patch)     SC_PATCH=0 ;;
        --no-vdesktop)  SC_VDESKTOP=0 ;;
        --vdesktop-res) SC_VDESKTOP_RES=$2; shift ;;
        --gamescope)    SC_GAMESCOPE=1 ;;
        --full)         SC_FULL=1 ;;
        --no-desktop)   SC_DESKTOP=0 ;;
        --install-deps) INSTALL_DEPS=1 ;;
        --skip-hash)    SKIP_HASH=1 ;;
        --force)        FORCE=1 ;;
        *) [[ "$CMD" == run ]] && break || die "Opción desconocida: $1" ;;
    esac
    shift
done
# Recalcular rutas derivadas si cambió --root
ISO_PATH="$SC_ROOT/media/SPACE_CLASH.iso"; CD_DIR="$SC_ROOT/cd"
export WINEPREFIX="$SC_ROOT/prefix"; GAME_DIR="$WINEPREFIX/drive_c/SCLASH"
LAUNCHER="$SC_ROOT/spaceclash.sh"; LOG_DIR="$SC_ROOT/logs"

case "$CMD" in
    install)   cmd_install ;;
    run)       cmd_run "$@" ;;
    doctor)    cmd_doctor ;;
    uninstall) cmd_uninstall ;;
    help|-h|--help) usage ;;
    *) usage; exit 1 ;;
esac
