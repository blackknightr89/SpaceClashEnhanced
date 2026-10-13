# Space Clash Enhanced

Instaladores para jugar **Space Clash: The Last Frontier** (Dinamic Multimedia / Enigma Software, 1999)
en computadoras actuales: **Linux** (CachyOS / Arch) y **Windows 10 / 11**.

- Pantalla completa en 4:3, escalada y centrada en monitores modernos (1080p, 1440p…).
- No hace falta el CD físico: alcanza con la imagen del disco (`.bin` + `.cue`, o `.iso`).
- Corrige errores del juego original que lo hacían colgarse en sistemas modernos (ver
  [qué se corrige](#qué-se-corrige)).

> ⚠️ **Este repositorio NO incluye el juego.** Necesitás tu propia copia del CD original de Space Clash
> (edición española) en forma de imagen de disco. Aquí solo hay instaladores y documentación.

---

## Qué necesitás

1. **La imagen del CD de Space Clash**: un archivo `.bin` con su `.cue`, o un archivo `.iso`.
   Si solo tenés el CD físico, creá la imagen con cualquier programa de copia de CD
   (Windows: [ImgBurn](https://www.imgburn.com/) → *Crear imagen a partir del disco*;
   Linux: K3b → *Copiar medio → Solo crear imagen*).
2. **Unos 2 GB libres** en disco.
3. **Conexión a internet** durante la instalación (para descargar
   [cnc-ddraw](https://github.com/FunkyFr3sh/cnc-ddraw), que permite la pantalla completa escalada).

## Descargar

1. **[⬇️ Descargar SpaceClashEnhanced.zip](https://github.com/blackknightr89/SpaceClashEnhanced/releases/latest/download/SpaceClashEnhanced.zip)**
   (última versión). También está en la página de
   [Releases](https://github.com/blackknightr89/SpaceClashEnhanced/releases/latest), dentro de
   *Assets*. Bajá **`SpaceClashEnhanced.zip`**, no los archivos *Source code*.
2. **Descomprimí** el ZIP donde quieras (por ejemplo, en Documentos). Se crea la carpeta
   **`SpaceClashEnhanced`**.
   - Windows: clic derecho sobre el ZIP → **Extraer todo…** → *Extraer*. No ejecutes el instalador desde
     dentro del ZIP sin extraerlo.
   - Linux: clic derecho → *Extraer aquí*.
3. Dentro de `SpaceClashEnhanced` hay una carpeta llamada **`disk`**: **copiá ahí la imagen de tu CD**
   (el `.bin` y el `.cue`, o la `.iso`). El nombre de los archivos no importa.

---

## Instalar en Windows 10 / 11

1. Comprobá que la imagen del juego esté en `SpaceClashEnhanced\disk`.
2. En la carpeta `SpaceClashEnhanced`, hacé **doble clic en `install-spaceclash.cmd`**.
   - Si Windows muestra *"Windows protegió su PC"*: **Más información → Ejecutar de todas formas**.
   - Si pregunta por **DirectPlay**, respondé que sí: el juego lo necesita. Windows pedirá permiso de
     administrador una sola vez.
3. Al terminar aparece un acceso directo **"Space Clash"** en el Escritorio y en el menú Inicio.

> Estado: el instalador de Windows fue probado en profundidad, pero **todavía no en un Windows real**.
> Si algo falla, abrí un *issue* (ver [Problemas](#problemas)).

## Instalar en Linux (CachyOS / Arch)

1. Comprobá que la imagen del juego esté en `SpaceClashEnhanced/disk`.
2. Abrí una terminal **dentro de la carpeta `SpaceClashEnhanced`** (en Dolphin: clic derecho en un
   espacio vacío → *Abrir terminal aquí*).
3. Instalá lo necesario (una sola vez; pide tu contraseña):
   ```bash
   sudo pacman -S --needed wine 7zip python unzip curl imagemagick gst-plugins-base gst-plugins-good gst-plugins-bad gst-plugins-ugly gst-libav
   ```
4. Instalá el juego:
   ```bash
   bash install-spaceclash.sh install
   ```
5. Jugá desde el menú de aplicaciones (**"Space Clash: The Last Frontier"**) o con:
   ```bash
   bash install-spaceclash.sh run
   ```

Otras distribuciones: debería funcionar si instalás los paquetes equivalentes (Wine ≥ 9, 7-Zip, Python 3,
unzip, curl y los plugins de GStreamer), pero solo se probó en CachyOS.

---

## Al jugar

- **Un clic** salta cada vídeo de introducción.
- En el menú principal, la tecla **Esc sale del juego**.
- Las partidas se guardan dentro de la carpeta de instalación:
  - Linux: `~/Games/space-clash/prefix/drive_c/SCLASH/`
  - Windows: `%USERPROFILE%\Games\SpaceClash\SCLASH\`
- Los vídeos se ven a pantalla completa, algo estirados a lo ancho. Es una limitación conocida del modo
  escalado: el juego en sí se ve en 4:3. Si preferís los vídeos perfectos en una ventana chica:
  - Linux: `bash install-spaceclash.sh install --display window`
  - Windows: `install-spaceclash.cmd -Display Native`

## Actualizar

1. Cerrá el juego.
2. Bajá la versión nueva desde [Releases](https://github.com/blackknightr89/SpaceClashEnhanced/releases/latest)
   (mismo enlace de [Descargar](#descargar)) y descomprimila.
3. Ejecutá de nuevo el instalador desde la carpeta nueva (`install-spaceclash.cmd` o
   `bash install-spaceclash.sh install`).

**Tus partidas y opciones se conservan**, y no hace falta volver a copiar la imagen del CD: el juego ya
instalado tiene su propia copia. Después podés borrar la carpeta descargada anterior.

## Desinstalar

- Windows: `install-spaceclash.cmd -Command uninstall`
- Linux: `bash install-spaceclash.sh uninstall`

⚠️ Esto también borra las partidas guardadas. Copialas antes si las querés conservar.

## Problemas

1. Ejecutá el diagnóstico:
   - Windows: `install-spaceclash.cmd -Command doctor`
   - Linux: `bash install-spaceclash.sh doctor`
2. Buscá el síntoma en esta tabla:

   | Síntoma | Qué hacer |
   |---|---|
   | *"No encontré la imagen del juego"* | Copiá el `.bin` + `.cue` (o la `.iso`) en la carpeta `disk` |
   | *"Para jugar a Space Clash debes ejecutar SC.EXE"* o el juego se cuelga | Cerrá el juego y volvé a ejecutar el instalador (reaplica los parches) |
   | *"El juego está abierto. Cerralo antes de instalar"* | Cerrá el juego. Si quedó colgado, en Linux: `WINEPREFIX=~/Games/space-clash/prefix wineserver -k`; en Windows: Administrador de tareas → finalizar `CLASH.EXE`/`SPACE.EXE` |
   | Pantalla negra (se oye el juego) | Linux: `bash install-spaceclash.sh install --renderer gdi` · Windows: `install-spaceclash.cmd -Renderer gdi` |
   | Vídeos en blanco | Windows: probá `install-spaceclash.cmd -Display Native` |
   | El juego queda minimizado | Linux: no desactives el escritorio virtual (`SC_VDESKTOP=0`) |
   | Aparece en el otro monitor | Movelo con Win/Meta + Shift + flecha |
   | *"la ejecución de scripts está deshabilitada"* (Windows) | Usá `install-spaceclash.cmd`, no el `.ps1` directamente |
   | Aviso de DirectPlay (Windows) | Aceptá instalarlo: el juego lo necesita |

3. Si no se resuelve, abrí un **issue** en este repositorio con la salida del diagnóstico y, si el juego
   se colgó, el informe de error. En Linux, Wine ofrece guardarlo como `backtrace.txt` en el Escritorio;
   en Windows, mirá `logs\launcher.log` en la carpeta de instalación.

---

## Qué se corrige

El juego original tiene errores que en Windows 95/98/XP no se notaban de casualidad y en sistemas modernos
lo hacen fallar. Los instaladores aplican parches mínimos y verificados a **tu** copia (guardan los
originales como `*.ORIG`):

| Parche | Síntoma que corrige |
|---|---|
| P1 | *"Para jugar a Space Clash debes ejecutar SC.EXE"* al arrancar |
| P2, P3 | Cuelgue de `SPACE.EXE` al iniciar la campaña espacial |
| P4 | Cuelgue al terminar una misión y volver al mapa estelar |

El detalle técnico (direcciones, bytes y causa de cada error) está comentado en los propios instaladores,
en la sección de parches de [`install-spaceclash.sh`](install-spaceclash.sh). Cada parche verifica los
bytes originales y el hash SHA-256 antes y después de aplicarse.

## Estado

| | Linux (CachyOS, Wine 11) | Windows 10/11 |
|---|---|---|
| Instalación | ✅ probado | ✅ probado fuera de Windows · ⏳ falta probar en Windows real |
| Vídeos, menú, campaña planetaria y espacial | ✅ | ⏳ |
| Pantalla completa escalada 4:3 | ✅ | ⏳ |
| Guardar/cargar, multijugador | ⏳ | ⏳ |

## Créditos y aviso legal

- *Space Clash: The Last Frontier* © 1999 Dinamic Multimedia / Enigma Software Productions. Este proyecto
  no está afiliado a sus autores ni a sus titulares de derechos. **No distribuye ningún archivo del juego**:
  trabaja sobre la copia que aporta el usuario.
- [cnc-ddraw](https://github.com/FunkyFr3sh/cnc-ddraw) (FunkyFr3sh, licencia MIT): se descarga durante la
  instalación.
- [Wine](https://www.winehq.org/) (en Linux).
- Los scripts y la documentación de este repositorio se publican bajo licencia [MIT](LICENSE).

---

### English (short)

Installers to play the Spanish edition of **Space Clash: The Last Frontier** (1999) on modern **Linux**
(via Wine) and **Windows 10/11**. They include scaled 4:3 fullscreen and binary patches for the original
game's crash bugs. **The game is not included**: download **SpaceClashEnhanced.zip** from
[Releases](https://github.com/blackknightr89/SpaceClashEnhanced/releases/latest), extract it, and put
your own CD image (`.bin`/`.cue` or `.iso`) in `SpaceClashEnhanced/disk/`.
Then run `install-spaceclash.cmd` (Windows) or `bash install-spaceclash.sh install` (Linux).
Documentation and installer messages are in Spanish.
