<#
.SYNOPSIS
    Instalador de "Space Clash: The Last Frontier" (Dinamic Multimedia / Enigma, 1999)
    para Windows 10 y 11. Equivalente a install-spaceclash.sh (Linux).

.DESCRIPTION
    - Lee el CD directamente desde la imagen .bin/.cue (o .iso), sin montarla.
    - Copia el juego a una carpeta del usuario (no requiere administrador).
    - Aplica los parches de compatibilidad P1-P4 (bugs del juego original; detalle en la sección «Parches» de este script).
    - Modo de pantalla "Scaled" (por defecto): cnc-ddraw, pantalla completa 4:3 centrada.
      Modo "Native": DirectDraw de Windows con capas de compatibilidad.
    - Vídeos 4:3 con barras negras a la resolución del monitor, para que no se vean estirados en modo
      Scaled (requiere ffmpeg; se descarga si no está): se pregunta en una instalación nueva (-Videos Ask);
      al reinstalar se conserva lo elegido. Ver docs/VIDEOS.md.
    - Opcional: vídeos escalados con IA (tools\upscale-videos.py; se pregunta al instalar si los vídeos
      se adaptan y hay Python con PyTorch y spandrel).
    - Crea un lanzador (accesos directos en Escritorio y menú Inicio) que asigna una letra de
      unidad a la carpeta del CD con SUBST y ejecuta el juego.
    Documentación para usuarios: README.md.

.EXAMPLE
    # Doble clic en install-spaceclash.cmd, o desde PowerShell:
    powershell -ExecutionPolicy Bypass -File .\install-spaceclash.ps1
    powershell -ExecutionPolicy Bypass -File .\install-spaceclash.ps1 -Display Native
    powershell -ExecutionPolicy Bypass -File .\install-spaceclash.ps1 -GameRes 1024 -Scaling Integer   # 4K
    powershell -ExecutionPolicy Bypass -File .\install-spaceclash.ps1 -Command doctor
    # Reinstalación completa (o doble clic en reinstall-spaceclash.cmd): vuelve a detectar el monitor
    powershell -ExecutionPolicy Bypass -File .\install-spaceclash.ps1 -Command reinstall
    powershell -ExecutionPolicy Bypass -File .\install-spaceclash.ps1 -Command uninstall
#>
[CmdletBinding()]
param(
    # install = instalar o actualizar (conserva las opciones elegidas) | reinstall = reinstalación completa:
    # rehace todo y configura como una instalación nueva (detecta otra vez la resolución del monitor,
    # scenh.ini de cero, pregunta por los vídeos); conserva las partidas
    [ValidateSet('install', 'reinstall', 'run', 'doctor', 'uninstall')]
    [string]$Command = 'install',
    # Imagen del juego: .cue, .bin (MODE1/2352) o .iso. Por defecto: la primera que haya en .\disk
    [string]$Image = '',
    # Carpeta de instalación (debe ser escribible por el usuario: el juego guarda ahí las partidas)
    [string]$InstallDir = (Join-Path $env:USERPROFILE 'Games\SpaceClash'),
    # Scaled = pantalla completa 4:3 con cnc-ddraw | Native = DirectDraw de Windows
    [ValidateSet('Scaled', 'Native')]
    [string]$Display = 'Scaled',
    # Renderer de cnc-ddraw (solo Scaled). auto = Direct3D 9 en Windows
    [ValidateSet('auto', 'direct3d9', 'opengl', 'gdi')]
    [string]$Renderer = 'auto',
    # Fit = llenar el alto de la pantalla en 4:3 | Integer = solo factores enteros (más nítido, más borde)
    [ValidateSet('Fit', 'Integer')]
    [string]$Scaling = 'Fit',
    # Filtro de escalado. Los shaders (Sharp, Xbr, Crt…) requieren -Renderer opengl; con direct3d9 solo
    # hay vecino más cercano (Nearest) o bilineal (el resto). Auto = Sharp con Fit, Nearest con Integer
    [ValidateSet('Auto', 'Nearest', 'Sharp', 'Smooth', 'Xbr', 'Crt')]
    [string]$Filter = 'Auto',
    # Resolución del juego (CLASH.CFG, igual que Opciones → Resolución de Pantalla). 1024 = más mapa visible.
    # Auto = 1024 en una instalación nueva; al reinstalar se conserva la que eligió el jugador
    [ValidateSet('Auto', 'Keep', '640', '800', '1024')]
    [string]$GameRes = 'Auto',
    # No tocar el renderizador de vídeo de DirectShow (ver Set-VmrMerit más abajo)
    [switch]$NoVideoFix,
    # Ask = preguntar en una instalación nueva (respuesta por defecto: sí); al reinstalar se conserva lo
    # elegido. Fit = vídeos 4:3 con barras a la resolución del monitor (solo Scaled; sin verificar aún en
    # Windows). Original = vídeos sin tocar (en Scaled se ven estirados)
    [ValidateSet('Ask', 'Fit', 'Original')]
    [string]$Videos = 'Ask',
    # Escalado de los vídeos con IA (tools\upscale-videos.py; requiere Python con PyTorch y spandrel, ideal
    # con GPU NVIDIA). Ask = preguntar al instalar si los vídeos se adaptan (respuesta por defecto: no)
    [ValidateSet('Ask', 'Off', 'General', 'GeneralSharp', 'X4plus')]
    [string]$VideosAi = 'Ask',
    # Python a usar para -VideosAi (por defecto: el lanzador py -3, o python.exe del PATH)
    [string]$Python = '',
    # Sin el runtime de mejoras scenh.dll (velocidad con + y -, menos consumo de CPU, avisos en pantalla)
    [switch]$NoRuntime,
    # Pantalla panorámica (experimental): la partida en WxH en lugar de 1024x768, con más mapa visible
    # (requiere el runtime). auto = la del monitor en una instalación nueva o con -Command reinstall
    # (install conserva la anterior);
    # off = 4:3 original; WxH = ese tamaño (p. ej. 1920x1080)
    [string]$Res = 'auto',
    [switch]$NoShortcut,
    [switch]$SkipHash,
    [switch]$SkipDirectPlay,
    # Para uninstall: no pedir confirmación
    [switch]$Force,
    # Para uninstall: no copiar las partidas antes de borrar
    [switch]$NoBackup
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest/Expand-Archive mucho más rápidos

# --------------------------------------------------------------------------- #
#  Constantes
# --------------------------------------------------------------------------- #
$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$BinSha256   = 'a0d007d205f83c3307294b5d8211eca588361584dba986010b6516efe0bc2e10'
$IsoSha256   = '88f14eb7c20cef85b5ba563b1127b821419159ac057b0999cce22f0944889c0b'
$CncUrl      = 'https://github.com/FunkyFr3sh/cnc-ddraw/releases/download/v7.1.0.0/cnc-ddraw.zip'
$GameExes    = @('CLASH.EXE', 'SPACE.EXE')
# ffmpeg para -Videos Fit (solo si no hay uno en el PATH). Build "essentials" de gyan.dev, versión fija.
$FfmpegUrl    = 'https://github.com/GyanD/codexffmpeg/releases/download/9.0.2/ffmpeg-9.0.2-essentials_build.zip'
$FfmpegSha256 = '60f467265b1e312373dbcd92200c2618a74850f98d3d078e94296bb3fa2047ba'
$IsWin       = [System.Environment]::OSVersion.Platform -eq 'Win32NT'
$NewCfg      = $false     # Install-GameFiles: CLASH.CFG recién copiado (instalación nueva)
$Reinstall   = $false     # -Command reinstall: configurar como una instalación nueva

# Parches (mismos que install-spaceclash.sh). Formato por archivo:
#   File, Sha256 original, Sha256 final, lista de @(offset, bytes originales, bytes nuevos)
#   P1 chequeo de procesos (dwSize sin inicializar) · P2/P3 desborde de superficie al iniciar y al
#   cambiar de resolución · P4 tamaño real de la superficie en presentar/borrar/copiar (7 sitios).
$P4o = '0fbf0d927081000fbf15907081000fafca'
$P4n = '8b0d707646000faf0d7876460090909090'
$Patches = @(
    @{ File = 'CLASH.EXE'
       Orig = '78fb6b3f8cf44887e76dd731e96b13a12cbca3bd5378c49dc8a9a8ae798ce8dc'
       Final = '0d7249b71fddbe7ae21384ffa4d04dedcddda8bfddc60e64f319ec0e09cbf507'
       Edits = @( ,@(0x15206, '75', 'eb') ) },
    @{ File = 'SPACE.EXE'
       Orig = '755e60f6f820377b45088841fd109174071b97e96c361cc40424dcaf87201cba'
       Final = '11cf4fd0865fcd813063565fb972176ae00c748509b1bddd1eab36e746526a93'
       Edits = @(
           @(0x0df86, '75', 'eb'),
           @(0x0d6fd, 'e8ee2b010085c07509e8e52b010085c074f7', '66c70590708100800266c70592708100e001'),
           @(0x201e1, 'e86a010000', '9090909090'),
           @(0x201eb, 'e860010000', '9090909090'),
           @(0x1c070, $P4o, $P4n), @(0x20303, $P4o, $P4n), @(0x20365, $P4o, $P4n),
           @(0x203ae, $P4o, $P4n), @(0x203f7, $P4o, $P4n), @(0x205b7, $P4o, $P4n),
           @(0x2063a, $P4o, $P4n)) }
)

# Runtime de mejoras (scenh.dll, carpeta runtime\). El juego la carga porque se renombra su import
# "GDI32.dll" a "SCENH.dll" (mismo largo; la DLL reenvía GetStockObject a gdi32). Antes de los parches
# P1-P4 se vuelve al nombre original, así que reinstalar o usar -NoRuntime deja los EXE como antes.
# Final = SHA-256 con P1-P4 + runtime.
$RuntimeImports = @(
    @{ File = 'CLASH.EXE'; Off = 0x806d4; Final = 'eac913cae176c501d718fcf3a63a39539458834bff97511d5813fb3deaa0f353' },
    @{ File = 'SPACE.EXE'; Off = 0x65aaa; Final = '142ef3a4530165765c1bc886e3b93880997b392bddffa4e34c5abcfe164137ea' }
)

# Filtro DirectShow "Video Renderer default" (VMR7). En modo Scaled se baja su mérito para que se use
# el "Video Renderer" GDI (con cnc-ddraw el VMR7 dibuja en blanco). Se escribe en HKCU (por usuario).
$VmrKey  = 'HKCU:\Software\Classes\Wow6432Node\CLSID\{083863F1-70DE-11D0-BD40-00A0C911CE86}\Instance\{6BC1CFFA-8FC1-4261-AC22-CFB4CC38DB50}'
$VmrTail = '010000000000000030706933020000000000000001000000000000000000000030747933000000003800000048000000766964730000100080000000aa00389b710000000000000000000000000000000000'
$CompatKey = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers'
$CompatFlags = '~ WINXPSP3 256COLOR DISABLEDXMAXIMIZEDWINDOWEDMODE HIGHDPIAWARE'

# Rutas derivadas
$CdDir    = Join-Path $InstallDir 'CD'
$GameDir  = Join-Path $InstallDir 'SCLASH'
$Launcher = Join-Path $InstallDir 'SpaceClash.ps1'
$VideoFit = Join-Path $InstallDir 'VideosFit.ps1'
$LogDir   = Join-Path $InstallDir 'logs'

# --------------------------------------------------------------------------- #
#  Utilidades
# --------------------------------------------------------------------------- #
function Write-Step($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Ok($m)   { Write-Host " ok $m" -ForegroundColor Green }
function Write-Warn2($m){ Write-Host " !! $m" -ForegroundColor Yellow }
function Fail($m)       { throw "ERROR: $m" }

function Get-Sha256([string]$Path) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $fs = [System.IO.File]::OpenRead($Path)
    try { return ([BitConverter]::ToString($sha.ComputeHash($fs)) -replace '-', '').ToLowerInvariant() }
    finally { $fs.Dispose(); $sha.Dispose() }
}

function ConvertFrom-Hex([string]$Hex) {   # compatible con PowerShell 5.1
    $b = New-Object byte[] ($Hex.Length / 2)
    for ($i = 0; $i -lt $b.Length; $i++) { $b[$i] = [Convert]::ToByte($Hex.Substring($i * 2, 2), 16) }
    return ,$b
}

# Lector ISO 9660 sobre .bin (2352 B/sector, datos en +16) o .iso (2048 B/sector). C# 5 (compatible
# con el compilador de .NET Framework que usa Windows PowerShell 5.1).
if (-not ('ScIso' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
public static class ScIso {
    static FileStream fs; static int secSize; static int dataOff;
    static void Open(string path) {
        fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 20);
        byte[] s = new byte[12]; fs.Read(s, 0, 12);
        bool raw = s[0] == 0 && s[11] == 0;
        for (int i = 1; i < 11; i++) if (s[i] != 0xFF) raw = false;
        secSize = raw ? 2352 : 2048; dataOff = raw ? 16 : 0;
    }
    static void ReadFull(byte[] buf, int n) {
        int off = 0; while (off < n) { int r = fs.Read(buf, off, n - off); if (r <= 0) throw new EndOfStreamException(); off += r; }
    }
    static byte[] ReadData(long lba, long size) {
        byte[] outb = new byte[size]; byte[] sec = new byte[secSize]; long done = 0;
        fs.Seek(lba * secSize, SeekOrigin.Begin);
        while (done < size) {
            ReadFull(sec, secSize);
            int n = (int)Math.Min(2048, size - done);
            Buffer.BlockCopy(sec, dataOff, outb, (int)done, n); done += n;
        }
        return outb;
    }
    static void CopyOut(long lba, long size, string dest) {
        byte[] sec = new byte[secSize]; long done = 0;
        fs.Seek(lba * secSize, SeekOrigin.Begin);
        using (FileStream o = new FileStream(dest, FileMode.Create, FileAccess.Write, FileShare.None, 1 << 20)) {
            while (done < size) {
                ReadFull(sec, secSize);
                int n = (int)Math.Min(2048, size - done);
                o.Write(sec, dataOff, n); done += n;
            }
        }
    }
    static void Walk(long lba, long size, string dir, ref int count) {
        Directory.CreateDirectory(dir);
        byte[] d = ReadData(lba, size); int p = 0;
        while (p < d.Length) {
            int len = d[p];
            if (len == 0) { p = (p / 2048 + 1) * 2048; continue; }
            long ext = BitConverter.ToUInt32(d, p + 2), sz = BitConverter.ToUInt32(d, p + 10);
            int flags = d[p + 25], nl = d[p + 32];
            if (!(nl == 1 && (d[p + 33] == 0 || d[p + 33] == 1))) {
                string name = Encoding.GetEncoding(28591).GetString(d, p + 33, nl);
                int semi = name.IndexOf(';'); if (semi >= 0) name = name.Substring(0, semi);
                name = name.TrimEnd('.');
                string path = Path.Combine(dir, name);
                if ((flags & 2) != 0) Walk(ext, sz, path, ref count);
                else { CopyOut(ext, sz, path); count++; }
            }
            p += len;
        }
    }
    public static string VolumeId(string image) {
        Open(image);
        try { byte[] pvd = ReadData(16, 2048); return Encoding.ASCII.GetString(pvd, 40, 32).Trim(); }
        finally { fs.Dispose(); fs = null; }
    }
    public static int ExtractAll(string image, string outDir) {
        Open(image);
        try {
            byte[] pvd = ReadData(16, 2048);
            if (Encoding.ASCII.GetString(pvd, 1, 5) != "CD001") throw new InvalidDataException("La imagen no contiene un sistema de archivos ISO 9660");
            int count = 0;
            Walk(BitConverter.ToUInt32(pvd, 158), BitConverter.ToUInt32(pvd, 166), outDir, ref count);
            return count;
        } finally { fs.Dispose(); fs = null; }
    }
}
'@
}

# --------------------------------------------------------------------------- #
#  1. Requisitos
# --------------------------------------------------------------------------- #
function Test-Requirements {
    Write-Step 'Comprobando requisitos…'
    if ($IsWin) {
        $os = [System.Environment]::OSVersion.Version
        if ($os.Major -lt 10) { Write-Warn2 "Windows $os no está soportado por este instalador (pensado para 10/11)." }
        if (-not [System.Environment]::Is64BitOperatingSystem) { Write-Warn2 'Windows de 32 bits: no probado.' }
    }
    Write-Ok "PowerShell $($PSVersionTable.PSVersion)"
}

# El juego importa DPLAYX.DLL (DirectPlay, multijugador). En Windows 10/11 es un componente heredado
# opcional; sin él, Windows muestra un aviso o el juego no arranca. Activarlo requiere administrador.
function Enable-DirectPlay {
    if (-not $IsWin -or $SkipDirectPlay) { return }
    $state = $null
    try { $state = (Get-CimInstance -ClassName Win32_OptionalFeature -Filter "Name='DirectPlay'" -ErrorAction Stop).InstallState } catch { }
    if ($state -eq 1) { Write-Ok 'DirectPlay activado'; return }
    Write-Warn2 'El componente heredado "DirectPlay" no está activado (el juego lo necesita).'
    $ans = Read-Host '¿Activarlo ahora? Se pedirá permiso de administrador (UAC) [S/n]'
    if ($ans -match '^[nN]') { Write-Warn2 'Sin DirectPlay el juego puede no arrancar. Ver README.md, sección «Problemas».'; return }
    $p = Start-Process -FilePath 'dism.exe' -Verb RunAs -Wait -PassThru `
         -ArgumentList '/online', '/enable-feature', '/featurename:DirectPlay', '/all', '/norestart'
    if ($p.ExitCode -in 0, 3010) { Write-Ok 'DirectPlay activado' } else { Write-Warn2 "dism terminó con código $($p.ExitCode)" }
}

# --------------------------------------------------------------------------- #
#  2. Imagen del juego → carpeta CD
# --------------------------------------------------------------------------- #
function Resolve-Image {
    $img = $Image
    if (-not $img) {   # buscar el primer .cue, .bin o .iso en la carpeta disk (cualquier nombre)
        $diskDir = Join-Path $ScriptDir 'disk'
        foreach ($ext in '*.cue', '*.bin', '*.iso') {
            $found = @(Get-ChildItem -LiteralPath $diskDir -Filter $ext -File -ErrorAction SilentlyContinue)
            if ($found.Count) { $img = $found[0].FullName; break }
        }
        if (-not $img) { Fail "No encontré la imagen del juego. Copiá el .bin + .cue (o la .iso) de tu CD de Space Clash en: $diskDir" }
    }
    if (-not (Test-Path -LiteralPath $img)) { Fail "No encuentro la imagen: $img (usá -Image <ruta .bin/.cue/.iso>)" }
    $img = (Resolve-Path -LiteralPath $img).ProviderPath
    if ($img -match '\.cue$') {   # tomar el .bin indicado en el .cue
        $line = Select-String -LiteralPath $img -Pattern '^\s*FILE\s+"(.+)"' | Select-Object -First 1
        if (-not $line) { Fail "El .cue no indica un archivo FILE" }
        if ((Get-Content -LiteralPath $img -Raw) -notmatch 'MODE1/2352') { Fail 'El .cue no es una pista MODE1/2352' }
        $img = Join-Path (Split-Path -Parent $img) $line.Matches[0].Groups[1].Value
        if (-not (Test-Path -LiteralPath $img)) { Fail "El .cue apunta a '$img', que no existe." }
    }
    Write-Ok "Imagen: $img"
    return $img
}

function Expand-GameImage {
    $haveCd = (Test-Path (Join-Path $CdDir 'UNCLASH.EXE')) -and (Test-Path (Join-Path $CdDir 'MUSICAS'))
    if ($haveCd -and -not $script:Reinstall) { Write-Ok "CD ya extraído en $CdDir"; return }
    if ($haveCd) {   # reinstall: extraer de nuevo si está la imagen; si no, conservar el CD
        try { $img = Resolve-Image }
        catch { Write-Warn2 "No encontré la imagen del CD: se conserva el CD ya extraído en $CdDir"; return }
    } else { $img = Resolve-Image }
    if (-not $SkipHash) {
        Write-Step 'Verificando SHA-256 de la imagen…'
        $h = Get-Sha256 $img
        if ($h -eq $BinSha256 -or $h -eq $IsoSha256) { Write-Ok 'Imagen verificada' }
        else { Write-Warn2 "Hash distinto al esperado ($h). Puede ser otra edición; se continúa." }
    }
    Write-Step "Extrayendo el CD en $CdDir (≈660 MB)…"
    if (Test-Path $CdDir) { Remove-Item -Recurse -Force $CdDir }
    $n = [ScIso]::ExtractAll($img, $CdDir)
    if (-not (Test-Path (Join-Path $CdDir 'UNCLASH.EXE'))) { Fail 'La extracción no produjo UNCLASH.EXE: imagen inválida' }
    Write-Ok "$n archivos extraídos"
}

# --------------------------------------------------------------------------- #
#  3. Copia del juego (réplica de SC.NFO, el manifiesto del instalador original)
# --------------------------------------------------------------------------- #
#  No se usa INSTALAR.EXE: instalaría DirectX 6 y ActiveMovie 1.0, innecesarios y dañinos en Windows 10/11.
# Instalación de cero: ofrecer restaurar la última copia de partidas que dejó uninstall
# (..\SpaceClash-partidas-<fecha>: *.sav, *.nfo y CLASH.CFG).
function Restore-Save {
    if (Test-Path (Join-Path $GameDir 'CLASH.CFG')) { return }
    if (@(Get-ChildItem -File -ErrorAction SilentlyContinue -Path "$GameDir\*" -Include '*.sav').Count) { return }
    $last = Get-ChildItem -Directory -ErrorAction SilentlyContinue (Split-Path $InstallDir -Parent) -Filter 'SpaceClash-partidas-*' |
        Sort-Object Name | Select-Object -Last 1
    if (-not $last) { return }
    if ((Read-Host "Hay una copia de tus partidas en $($last.FullName). ¿Restaurarla? [S/n]") -match '^[nN]') {
        Write-Host "    Sin restaurar (la copia sigue en $($last.FullName))"; return
    }
    Get-ChildItem -File $last.FullName | Copy-Item -Destination $GameDir
    Write-Ok "Partidas restauradas desde $($last.FullName)"
}

function Install-GameFiles {
    Write-Step "Copiando el juego a $GameDir…"
    New-Item -ItemType Directory -Force -Path $GameDir | Out-Null
    Restore-Save
    foreach ($f in 'SC.EXE', 'CLASH.EXE', 'SPACE.EXE', 'UNCLASH.EXE', 'PALCF.DAT', 'PALCS.DAT', 'PALS.DAT',
                   'PALT020.DAT', 'PALT030.DAT', 'PALT040.DAT', 'ICON.ICO') {
        Copy-Item -Force (Join-Path $CdDir $f) (Join-Path $GameDir $f)
    }
    # Opciones del juego: solo la primera vez. Las partidas (*.sav) nunca se tocan.
    if (-not (Test-Path (Join-Path $GameDir 'CLASH.CFG'))) {
        Copy-Item (Join-Path $CdDir 'CLASH.CFG') $GameDir; $script:NewCfg = $true
    }
    Copy-Item -Force (Join-Path $CdDir 'MANUAL\MANUAL.PDF') (Join-Path $GameDir 'MANUAL.PDF')
    foreach ($d in 'EFECTOS', 'IMG', 'LOCU', 'MAPAS', 'SPC', 'SPR') {
        $dst = Join-Path $GameDir $d
        if (Test-Path $dst) { Remove-Item -Recurse -Force $dst }
        Copy-Item -Recurse (Join-Path $CdDir $d) $dst
    }
    Write-Step 'Descomprimiendo animaciones (ANI.ZIP)…'
    $ani = Join-Path $GameDir 'ANI'
    if (Test-Path $ani) { Remove-Item -Recurse -Force $ani }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::ExtractToDirectory((Join-Path $CdDir 'ANI.ZIP'), $ani)
    # Quitar atributo de solo lectura (en algunos casos se hereda) para que el juego pueda escribir
    Get-ChildItem -Recurse $GameDir | Where-Object { -not $_.PSIsContainer -and $_.IsReadOnly } |
        ForEach-Object { $_.IsReadOnly = $false }
    Write-Ok ("Juego instalado ({0:N0} MB)" -f ((Get-ChildItem -Recurse $GameDir | Measure-Object Length -Sum).Sum / 1MB))
}

# --------------------------------------------------------------------------- #
#  4. Parches P1-P4
# --------------------------------------------------------------------------- #
function Install-Patches {
    Write-Step 'Aplicando parches de compatibilidad (P1-P4)…'
    foreach ($p in $Patches) {
        $path = Join-Path $GameDir $p.File
        $orig = "$path.ORIG"
        $h = Get-Sha256 $path
        if ($h -eq $p.Final) { Write-Ok "$($p.File) ya estaba parcheado"; continue }
        if ($h -ne $p.Orig -and (Test-Path $orig) -and (Get-Sha256 $orig) -eq $p.Orig) {
            Copy-Item -Force $orig $path; $h = $p.Orig
        }
        if ($h -ne $p.Orig) { Fail "$($p.File) tiene un hash desconocido ($h); no se parchea. ¿Otra versión del juego?" }
        Copy-Item -Force $path $orig
        $bytes = [System.IO.File]::ReadAllBytes($path)
        foreach ($e in $p.Edits) {
            $off = [int]$e[0]; $ob = ConvertFrom-Hex $e[1]; $nb = ConvertFrom-Hex $e[2]
            for ($i = 0; $i -lt $ob.Length; $i++) {
                if ($bytes[$off + $i] -ne $ob[$i]) { Fail ("{0}: bytes inesperados en 0x{1:x}" -f $p.File, $off) }
            }
            [Array]::Copy($nb, 0, $bytes, $off, $nb.Length)
        }
        [System.IO.File]::WriteAllBytes($path, $bytes)
        $h = Get-Sha256 $path
        if ($h -ne $p.Final) { Copy-Item -Force $orig $path; Fail "Verificación de $($p.File) falló ($h); restaurado el original" }
        Write-Ok "$($p.File) parcheado (original en $($p.File).ORIG)"
    }
}

function Get-ImportName([string]$Path, [int]$Off) {
    $b = [System.IO.File]::ReadAllBytes($Path)
    return [System.Text.Encoding]::ASCII.GetString($b, $Off, 9)
}

function Set-ImportName([string]$Name) {   # GDI32.dll (original) o SCENH.dll (runtime) en ambos EXE
    foreach ($r in $RuntimeImports) {
        $path = Join-Path $GameDir $r.File
        if (-not (Test-Path $path)) { continue }
        $bytes = [System.IO.File]::ReadAllBytes($path)
        $cur = [System.Text.Encoding]::ASCII.GetString($bytes, $r.Off, 9)
        if ($cur -eq $Name) { continue }
        if ($cur -ne 'GDI32.dll' -and $cur -ne 'SCENH.dll') {
            Write-Warn2 ("{0}: import inesperado en 0x{1:x} ('{2}'); no se toca" -f $r.File, $r.Off, $cur); return $false
        }
        [Array]::Copy([System.Text.Encoding]::ASCII.GetBytes($Name), 0, $bytes, $r.Off, 9)
        [System.IO.File]::WriteAllBytes($path, $bytes)
    }
    return $true
}

function Get-FitRes([int]$MonW, [int]$MonH) {   # tamaño admitido más parecido (misma proporción) o $null
    # (PowerShell no distingue mayúsculas en las variables: $w y $W serían la misma)
    foreach ($k in 1, 2, 3, 4) {   # monitores grandes (4K, ultrawide): dividir por un entero → escalado nítido
        $fw = [int][Math]::Floor($MonW / $k) -band -8
        $fh = [int][Math]::Floor($fw * $MonH / $MonW + 1) -band -2
        if ($fw -ge 1024 -and $fw -le 2560 -and $fh -ge 600 -and $fh -le 1600 -and ($fw * $fh) -ge (1024 * 768)) {
            return '{0}x{1}' -f $fw, $fh
        }
        if ($fw -lt 1024) { return $null }
    }
    return $null
}

function Test-Res {   # valida -Res antes de empezar a instalar; devuelve @(ancho, alto) o $null
    if (-not $Res -or $Res -eq 'off' -or $Res -eq 'auto') { return $null }
    if ($Res -notmatch '^(\d+)x(\d+)$') { Fail "-Res inválido: $Res (p. ej. 1920x1080, u off)" }
    $w = [int]$Matches[1]; $h = [int]$Matches[2]
    if ($w -lt 1024 -or $w -gt 2560 -or ($w % 8) -ne 0 -or $h -lt 600 -or $h -gt 1600 -or ($w * $h) -lt (1024 * 768)) {
        Fail "-Res $Res fuera de rango: ancho 1024-2560 (múltiplo de 8), alto 600-1600, área >= 1024x768"
    }
    return @($w, $h)
}

function Set-ScenhKey([string]$Ini, [string]$Section, [string]$Key, [string]$Value) {
    $utf8 = New-Object System.Text.UTF8Encoding $false   # sin BOM: lo lee GetPrivateProfileInt
    $lines = [System.Collections.Generic.List[string]]@([System.IO.File]::ReadAllLines($Ini, $utf8))
    $start = $lines.IndexOf("[$Section]")
    if ($start -lt 0) { $lines.Add(''); $lines.Add("[$Section]"); $start = $lines.Count - 1 }
    $i = $start + 1
    while ($i -lt $lines.Count -and -not $lines[$i].StartsWith('[')) {
        if ($lines[$i].StartsWith("$Key=")) { $lines[$i] = "$Key=$Value"; [System.IO.File]::WriteAllLines($Ini, $lines, $utf8); return }
        $i++
    }
    $lines.Insert($start + 1, "$Key=$Value")
    [System.IO.File]::WriteAllLines($Ini, $lines, $utf8)
}

function Install-Runtime {
    if ($NoRuntime) {
        Set-ImportName 'GDI32.dll' | Out-Null
        Write-Ok 'Runtime de mejoras desactivado (-NoRuntime)'; return
    }
    $dll = @((Join-Path $ScriptDir 'runtime\scenh.dll'), (Join-Path $ScriptDir 'runtime\build\scenh.dll')) |
        Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $dll) {
        Write-Warn2 'No está runtime\scenh.dll (viene en SpaceClashEnhanced.zip): se instala sin mejoras'
        Set-ImportName 'GDI32.dll' | Out-Null; return
    }
    Copy-Item -Force $dll (Join-Path $GameDir 'scenh.dll')
    $ini = Join-Path $GameDir 'scenh.ini'
    # reinstall: scenh.ini de cero (con las opciones nuevas y la resolución del monitor detectada otra vez)
    if ($script:Reinstall -and (Test-Path $ini)) {
        Move-Item -Force $ini (Join-Path $GameDir 'scenh.ini.anterior')
        Write-Step 'Opciones del runtime restablecidas (las anteriores quedan en scenh.ini.anterior)'
    }
    $newIni = -not (Test-Path $ini)
    if ($newIni) { Copy-Item (Join-Path $ScriptDir 'runtime\scenh.ini') $ini }
    if (-not (Set-ImportName 'SCENH.dll')) { Set-ImportName 'GDI32.dll' | Out-Null; return }
    if ($Res -eq 'auto') {
        # Solo en una instalación nueva o con reinstall (scenh.ini recién creado) y en modo Scaled; al
        # actualizar con install se respeta lo que haya en scenh.ini
        if (-not $newIni -or $Display -ne 'Scaled') { return }
        $mon = $null; try { $mon = Get-ScreenRes } catch { }
        $fit = $null
        if ($mon -match '^(\d+)x(\d+)$') { $fit = Get-FitRes ([int]$Matches[1]) ([int]$Matches[2]) }
        if (-not $fit -or $fit -eq '1024x768') {
            Write-Ok 'Pantalla: 1024x768 (no se detectó un monitor compatible con la pantalla panorámica)'
            return
        }
        $script:Res = $fit
    }
    if ($Res -eq 'off') {
        Set-ScenhKey $ini 'resolucion' 'activar' '0'; Write-Ok 'Resolución panorámica desactivada'
    } elseif ($Res) {
        $wh = Test-Res
        Set-ScenhKey $ini 'resolucion' 'activar' '1'
        Set-ScenhKey $ini 'resolucion' 'ancho' "$($wh[0])"
        Set-ScenhKey $ini 'resolucion' 'alto' "$($wh[1])"
        $script:GameRes = '1024'   # la resolución panorámica reemplaza al modo 1024 del juego
        Write-Ok "Resolución panorámica (experimental): $Res"
    }
    Write-Ok "Runtime de mejoras instalado: velocidad con + y - durante la partida (opciones en $ini)"
}

# --------------------------------------------------------------------------- #
#  5. Modo de pantalla
# --------------------------------------------------------------------------- #
function Set-IniKey([string]$Ini, [string]$Key, [string]$Value) {   # solo dentro de [ddraw]
    $lines = [System.IO.File]::ReadAllLines($Ini)
    $out = New-Object System.Collections.Generic.List[string]
    $inSec = $false; $done = $false
    foreach ($l in $lines) {
        if ($l -match '^\[') {
            if ($inSec -and -not $done) { $out.Add("$Key=$Value"); $done = $true }
            $inSec = ($l.Trim() -eq '[ddraw]')
        }
        if ($inSec -and -not $done -and $l -match "^[;\s]*$([regex]::Escape($Key))\s*=") {
            $out.Add("$Key=$Value"); $done = $true; continue
        }
        $out.Add($l)
    }
    if ($inSec -and -not $done) { $out.Add("$Key=$Value") }
    [System.IO.File]::WriteAllLines($Ini, $out.ToArray())
}

function Set-VmrMerit([bool]$Low) {
    if (-not $IsWin) { return }
    if ($Low) {
        New-Item -Force -Path $VmrKey | Out-Null
        Set-ItemProperty -Path $VmrKey -Name 'CLSID' -Value '{6BC1CFFA-8FC1-4261-AC22-CFB4CC38DB50}'
        Set-ItemProperty -Path $VmrKey -Name 'FriendlyName' -Value 'Video Renderer'
        $data = ConvertFrom-Hex ('02000000' + '00002000' + $VmrTail)    # mérito 0x00200000
        New-ItemProperty -Force -Path $VmrKey -Name 'FilterData' -PropertyType Binary -Value $data | Out-Null
        # Invalidar la caché del enumerador de DirectShow para que relea los filtros
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue 'HKCU:\Software\Microsoft\ActiveMovie\devenum'
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue 'HKCU:\Software\Microsoft\ActiveMovie\devenum 64-bit'
    } elseif (Test-Path $VmrKey) {
        Remove-Item -Recurse -Force $VmrKey
    }
}

function Set-CompatLayers([bool]$On) {
    if (-not $IsWin) { return }
    if (-not (Test-Path $CompatKey)) { New-Item -Force -Path $CompatKey | Out-Null }
    foreach ($e in $GameExes) {
        $exe = Join-Path $GameDir $e
        if ($On) { Set-ItemProperty -Path $CompatKey -Name $exe -Value $CompatFlags }
        else { Remove-ItemProperty -Path $CompatKey -Name $exe -ErrorAction SilentlyContinue }
    }
}

function Install-Display {
    $dll = Join-Path $GameDir 'ddraw.dll'; $ini = Join-Path $GameDir 'ddraw.ini'
    if ($Display -eq 'Native') {
        Write-Step 'Modo de pantalla: Native (DirectDraw de Windows + compatibilidad XP/256 colores)…'
        Remove-Item -Force -ErrorAction SilentlyContinue $dll, $ini
        Set-VmrMerit $false
        Set-CompatLayers $true
        Write-Ok 'Modo Native configurado'
        return
    }
    Write-Step 'Modo de pantalla: Scaled (cnc-ddraw, pantalla completa 4:3)…'
    $cache = Join-Path $InstallDir 'cnc-ddraw.zip'
    if ($script:Reinstall) { Remove-Item -Force -ErrorAction SilentlyContinue $cache }   # descargarlo de nuevo
    if (-not (Test-Path $cache)) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        try { Invoke-WebRequest -UseBasicParsing -Uri $CncUrl -OutFile "$cache.part" }
        catch { Fail "No se pudo descargar cnc-ddraw ($CncUrl). Descargalo a mano en $cache o usá -Display Native" }
        Move-Item -Force "$cache.part" $cache
    }
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("cnc-" + [guid]::NewGuid())
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::ExtractToDirectory($cache, $tmp)
    Copy-Item -Force (Join-Path $tmp 'ddraw.dll') $dll
    Copy-Item -Force (Join-Path $tmp 'ddraw.ini') $ini
    # Shaders de escalado (GLSL de libretro, para renderer=opengl): los del zip + el paquete ampliado
    $shaders = Join-Path $GameDir 'Shaders'
    if (Test-Path $shaders) { Remove-Item -Recurse -Force $shaders }
    Copy-Item -Recurse (Join-Path $tmp 'Shaders') $shaders
    $pkg = Join-Path $shaders 'shader-package.zip'
    if (Test-Path $pkg) {
        Add-Type -AssemblyName System.IO.Compression
        $zip = [System.IO.Compression.ZipFile]::OpenRead($pkg)
        try {
            foreach ($e in $zip.Entries) {
                if ($e.Name -eq '') { continue }
                $dst = Join-Path $GameDir ($e.FullName -replace '/', '\')
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
                [System.IO.Compression.ZipFileExtensions]::ExtractToFile($e, $dst, $true)
            }
        } finally { $zip.Dispose() }
        Remove-Item -Force $pkg
    }
    Remove-Item -Recurse -Force $tmp
    $f = $Filter
    if ($f -eq 'Auto') { $f = if ($Scaling -eq 'Integer') { 'Nearest' } else { 'Sharp' } }
    $shader = @{ Nearest = 'Nearest neighbor'; Sharp = 'Shaders\interpolation\sharp-bilinear-simple-bilinear.glsl'
                 Smooth = 'Bicubic'; Xbr = 'xBR-lv2'; Crt = 'Shaders\crt\crt-lottes-fast-no-warp-bilinear.glsl' }[$f]
    $d3d9Filter = if ($f -eq 'Nearest') { '0' } else { '1' }    # 8 bits: direct3d9 solo admite 0 o 1
    $settings = [ordered]@{ fullscreen = 'true'; windowed = 'false'; maintas = 'true'
                           boxing = $(if ($Scaling -eq 'Integer') { 'true' } else { 'false' })
                           width = '0'; height = '0'; renderer = $Renderer; shader = $shader
                           d3d9_filter = $d3d9Filter; adjmouse = 'true'
                           vsync = 'false'; devmode = 'false'; savesettings = '0' }
    foreach ($k in $settings.Keys) { Set-IniKey $ini $k $settings[$k] }
    Set-CompatLayers $false          # las capas de compatibilidad interfieren con cnc-ddraw
    Set-VmrMerit (-not $NoVideoFix)
    Write-Ok "cnc-ddraw configurado (renderer=$Renderer, escalado=$Scaling, filtro=$f; ajustes en $ini, sección [ddraw])"
}

# Resolución del juego. CLASH.CFG (18 bytes): el byte 0x10 es el modo (1 = 640x480, 2 = 800x600, 3 = 1024x768).
function Set-GameRes {
    $res = $GameRes
    # Auto: 1024 si CLASH.CFG es nuevo o con reinstall; al actualizar con install, lo elegido en Opciones
    if ($res -eq 'Auto') { $res = if ($script:NewCfg -or $script:Reinstall) { '1024' } else { 'Keep' } }
    if ($res -eq 'Keep') { return }
    $cfg = Join-Path $GameDir 'CLASH.CFG'
    $b = [System.IO.File]::ReadAllBytes($cfg)
    if ($b.Length -ne 18) { Write-Warn2 'CLASH.CFG con tamaño inesperado; no se cambia la resolución'; return }
    $b[16] = @{ '640' = 1; '800' = 2; '1024' = 3 }[$res]
    [System.IO.File]::WriteAllBytes($cfg, $b)
    Write-Ok "Resolución del juego: $res (CLASH.CFG)"
}

# --------------------------------------------------------------------------- #
#  5b. Vídeos a pantalla completa sin deformar (-Videos Fit)
# --------------------------------------------------------------------------- #
#  El juego pide a DirectShow que estire el vídeo (320x240, 4:3) a toda la ventana. En Wine se ve
#  estirado a 16:9; en Windows 10/11 está sin verificar, por eso es opcional. VideosFit.ps1 reencodea los
#  .MPG a la resolución EXACTA del monitor con la imagen 4:3 centrada y barras negras (MPEG-1 System, el
#  formato que el juego ya reproduce; audio copiado sin tocar). Originales en CD\VIDEOS\ORIG. El lanzador
#  lo vuelve a ejecutar si cambia la resolución. Mismo procedimiento que videos-fit.sh (Linux).
# Resolución del monitor: la usan el instalador (-Res auto) y VideosFit.ps1 (se inserta en su código, en
# #<Get-ScreenRes>). Hasta la v1.8 solo estaba dentro de VideosFit.ps1, así que -Res auto nunca detectaba
# el monitor en Windows.
$ScreenResCode = @'
function Get-ScreenRes {   # en píxeles físicos (sin el escalado de DPI de Windows)
    if (-not ('ScDpi' -as [type])) {
        Add-Type -TypeDefinition @"
using System.Runtime.InteropServices;
public static class ScDpi {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int index);
}
"@
    }
    [void][ScDpi]::SetProcessDPIAware()
    return '{0}x{1}' -f [ScDpi]::GetSystemMetrics(0), [ScDpi]::GetSystemMetrics(1)
}
'@
. ([scriptblock]::Create($ScreenResCode))

$VideoFitCode = @'
# VideosFit.ps1 — adapta los vídeos de Space Clash a la pantalla (generado por install-spaceclash.ps1)
#   -Mode check  [-Res WxH]   ¿ya están generados? (código 0 = sí). Sin -Res: monitor principal
#   -Mode ensure [-Res WxH]   los genera si hace falta (~1-2 min)
#   -Mode restore             vuelve a los vídeos originales
#   -Mode status
# Si existe un máster escalado con IA (tools\upscale-videos.py → videos-hd\), se usa como fuente.
param([ValidateSet('check', 'ensure', 'restore', 'status')][string]$Mode = 'status', [string]$Res = '')
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$V = Join-Path $Root 'CD\VIDEOS'; $O = Join-Path $V 'ORIG'; $Stamp = Join-Path $V '.fit'
$Hd = Join-Path $Root 'videos-hd'
$FitVersion = 2   # subir si cambian los parámetros de codificación (fuerza regenerar)
$Sha = [ordered]@{
    'LOGO.MPG'    = '73b260e5f9c53d198d3872719b86c99d58059fa01224cce937bcd660af97306d'
    'DINAMIC.MPG' = '18d721c17d4f0f3cfab163ccf2255500427ce0ee9441ad97be632cdbe9d6e794'
    'INTRO.MPG'   = '21ccc54cf26092b1fc9af45ea764f3d0e356fb993715ebc25a45b5225a577955'
    'FINAL00.MPG' = '9d961881d5a076c6d1899e626b9ca519630aad6c7c2aea64f44f2b58493e5774'
    'FINAL01.MPG' = '35286ae006a543096b6ee1e2bb2b17990680152703a3d790861909396535a278'
    'FINAL02.MPG' = '76b406415b48813c0a79e83596e83bcf1f2f4e7f05a73954503a1d1a31e1ac37'
    'FINAL03.MPG' = '13a2dd30aa8547d0560cc24fdc6ed87b3468310779c86146835cc2dabb8df983'
}

#<Get-ScreenRes>

function Find-Ffmpeg {
    $local = Join-Path $Root 'tools\ffmpeg.exe'
    if (Test-Path $local) { return $local }
    $c = Get-Command ffmpeg.exe -ErrorAction SilentlyContinue
    if ($c) { return $c.Path }
    return $null
}

# Fuente de cada vídeo: el máster HD si está completo, si no el original de 320x240
function Test-Hd {
    if (-not (Test-Path (Join-Path $Hd 'manifest.json'))) { return $false }
    foreach ($f in $Sha.Keys) {
        $m = Join-Path $Hd ([System.IO.Path]::ChangeExtension($f, '.mkv'))
        if (-not (Test-Path $m) -or (Get-Item $m).Length -eq 0) { return $false }
    }
    return $true
}
function Get-SourceTag {
    if (Test-Hd) { return 'hd-' + (Get-FileHash -Algorithm SHA256 (Join-Path $Hd 'manifest.json')).Hash.Substring(0, 12).ToLowerInvariant() }
    return 'orig'
}
function Get-Source([string]$f) {
    if (Test-Hd) { return Join-Path $Hd ([System.IO.Path]::ChangeExtension($f, '.mkv')) }
    return Join-Path $O $f
}

function Test-Fit([string]$r) {
    return (Test-Path $Stamp) -and ([System.IO.File]::ReadAllText($Stamp).Trim() -eq "$r v$FitVersion $(Get-SourceTag)")
}

function Backup-Originals {   # copia los originales a ORIG (una sola vez)
    New-Item -ItemType Directory -Force -Path $O | Out-Null
    foreach ($f in $Sha.Keys) {
        if (Test-Path (Join-Path $O $f)) { continue }
        if (Test-Path $Stamp) { throw "Falta el original ORIG\$f y $f ya está adaptado (reinstalá el juego)." }
        $src = Join-Path $V $f
        if (-not (Test-Path $src)) { throw "Falta $src" }
        if ((Get-FileHash -Algorithm SHA256 $src).Hash.ToLowerInvariant() -ne $Sha[$f]) {
            Write-Warning "$f no coincide con el del CD conocido; se usa igual"
        }
        Copy-Item -Force $src (Join-Path $O "$f.part")
        Move-Item -Force (Join-Path $O "$f.part") (Join-Path $O $f)
    }
}

function Restore-Originals {
    Remove-Item -Force -ErrorAction SilentlyContinue $Stamp
    Get-ChildItem -Force -LiteralPath $V -Filter '.*.part' -ErrorAction SilentlyContinue | Remove-Item -Force
    if (-not (Test-Path $O)) { return }
    foreach ($f in $Sha.Keys) {
        $src = Join-Path $O $f
        if (Test-Path $src) { Copy-Item -Force $src (Join-Path $V $f) }
    }
    Remove-Item -Recurse -Force $O
}

function Invoke-Ensure([string]$r) {
    if ($r -notmatch '^(\d+)x(\d+)$') { throw "Resolución inválida: $r" }
    $w = [int]$Matches[1]; $h = [int]$Matches[2]
    if (Test-Fit $r) { return }
    $ff = Find-Ffmpeg
    if (-not $ff) { throw 'Falta ffmpeg; se usan los vídeos actuales.' }
    # Más de 1080 líneas no aporta nada (fuente de 320x240, o máster HD de 960): en pantallas mayores se
    # genera a 1080 de alto con la MISMA proporción y el renderizador lo estira sin deformar.
    if ($h -gt 1080) { $w = [int][Math]::Floor(($w * 1080 / $h + 1) / 2) * 2; $h = 1080 }
    Backup-Originals
    $tag = Get-SourceTag
    $q = 3; $rate = '15M'
    if ($tag -like 'hd-*') { $q = 2; $rate = '30M' }   # el máster tiene detalle real: más bitrate
    Write-Host "Generando los vídeos para $r (${w}x$h, fuente: $($tag.Split('-')[0]))…"
    # setsar=1: los originales declaran un pel aspect ratio erróneo (178:163); son 4:3 con píxeles cuadrados
    $vf = "setsar=1,scale=${w}:${h}:force_original_aspect_ratio=decrease:force_divisible_by=2:flags=lanczos," +
          "pad=${w}:${h}:(ow-iw)/2:(oh-ih)/2:black,setsar=1"
    Remove-Item -Force -ErrorAction SilentlyContinue $Stamp
    $procs = @()
    foreach ($f in $Sha.Keys) {
        $ffArgs = "-nostdin -v error -y -i `"$(Get-Source $f)`" -map 0:v:0 -map 0:a:0 -vf `"$vf`" " +
                "-c:v mpeg1video -q:v $q -maxrate $rate -bufsize 8M -g 12 -bf 2 " +
                "-c:a copy -f mpeg `"$(Join-Path $V ".$f.part")`""
        $p = Start-Process -FilePath $ff -ArgumentList $ffArgs -WindowStyle Hidden -PassThru
        $null = $p.Handle   # sin esto, ExitCode queda vacío en Windows PowerShell
        $procs += $p
    }
    $ok = $true
    foreach ($p in $procs) { $p.WaitForExit(); if ($p.ExitCode -ne 0) { $ok = $false } }
    foreach ($f in $Sha.Keys) {
        $part = Join-Path $V ".$f.part"
        if (-not (Test-Path $part) -or (Get-Item -Force $part).Length -eq 0) { $ok = $false }
    }
    if (-not $ok) { Restore-Originals; throw 'ffmpeg falló; se restauraron los vídeos originales.' }
    foreach ($f in $Sha.Keys) { Move-Item -Force (Join-Path $V ".$f.part") (Join-Path $V $f) }
    [System.IO.File]::WriteAllText($Stamp, "$r v$FitVersion $tag")
    Write-Host "Vídeos listos ($r)."
}

try {
    if (-not $Res -and $Mode -in 'check', 'ensure') { $Res = Get-ScreenRes }
    switch ($Mode) {
        'check'   { if (Test-Fit $Res) { exit 0 } else { exit 1 } }
        'ensure'  { Invoke-Ensure $Res }
        'restore' { Restore-Originals }
        'status'  { if (Test-Path $Stamp) { "adaptados: $([System.IO.File]::ReadAllText($Stamp))" } else { 'originales' } }
    }
    exit 0
} catch {
    Write-Host "VideosFit: $_" -ForegroundColor Yellow
    exit 1
}
'@

function Get-Ffmpeg {   # ffmpeg del PATH, o descarga de una versión fija con verificación de hash
    $local = Join-Path $InstallDir 'tools\ffmpeg.exe'
    if (Test-Path $local) { return $true }
    if (Get-Command ffmpeg.exe -ErrorAction SilentlyContinue) { Write-Ok 'ffmpeg encontrado en el PATH'; return $true }
    Write-Step 'Descargando ffmpeg (≈110 MB, solo para adaptar los vídeos)…'
    $zip = Join-Path $InstallDir 'ffmpeg.zip'
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    try { Invoke-WebRequest -UseBasicParsing -Uri $FfmpegUrl -OutFile $zip }
    catch { Write-Warn2 "No se pudo descargar ffmpeg ($FfmpegUrl)."; return $false }
    if ((Get-Sha256 $zip) -ne $FfmpegSha256) {
        Remove-Item -Force $zip; Write-Warn2 'El ffmpeg descargado no tiene el hash esperado; se descarta.'; return $false
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $local) | Out-Null
    $za = [System.IO.Compression.ZipFile]::OpenRead($zip)
    try {
        $entry = $za.Entries | Where-Object { $_.FullName -match '/bin/ffmpeg\.exe$' } | Select-Object -First 1
        if (-not $entry) { Write-Warn2 'El zip de ffmpeg no contiene bin/ffmpeg.exe.'; return $false }
        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $local, $true)
    } finally { $za.Dispose(); Remove-Item -Force $zip }
    Write-Ok "ffmpeg instalado en $local"
    return $true
}

function Find-Python {   # ruta de un Python con torch + spandrel, o $null
    $cands = @()
    if ($Python) { $cands += $Python }
    if (Get-Command py.exe -ErrorAction SilentlyContinue) {
        $exe = (& py.exe -3 -c 'import sys; print(sys.executable)' 2>$null)
        if ($LASTEXITCODE -eq 0 -and $exe) { $cands += "$exe".Trim() }
    }
    $c = Get-Command python.exe -ErrorAction SilentlyContinue
    if ($c) { $cands += $c.Path }
    foreach ($py in $cands) {
        & $py -c 'import torch, spandrel, numpy' 2>$null
        if ($LASTEXITCODE -eq 0) { return $py }
    }
    return $null
}

# Escalado con IA (opcional): genera el máster $InstallDir\videos-hd, que VideosFit.ps1 usa como fuente.
function Invoke-VideosAi {
    $tool = Join-Path $ScriptDir 'tools\upscale-videos.py'
    if ($VideosAi -eq 'Off' -or -not (Test-Path $tool)) { return }
    $model = @{ General = 'general'; GeneralSharp = 'general-sharp'; X4plus = 'x4plus' }[$VideosAi]
    $py = Find-Python
    if ($VideosAi -eq 'Ask') {
        if (Test-Path (Join-Path $InstallDir 'videos-hd\manifest.json')) { return }   # ya hecho
        if ([Console]::IsInputRedirected) { return }
        if (-not $py) {
            Write-Host '    Opcional: los vídeos se pueden escalar con IA (más nítidos). Requiere Python con PyTorch y'
            Write-Host '    spandrel; ver tools\upscale-videos.py --help'
            return
        }
        Write-Host '    Los vídeos (logos, intro y finales) se pueden escalar con IA: más nítidos y sin bloques.'
        Write-Host '    Tarda ≈10 min con una GPU NVIDIA (horas sin GPU) y se hace una sola vez.'
        if ((Read-Host '    ¿Escalar los vídeos con IA ahora? [s/N]') -notmatch '^[sSyY]') {
            Write-Host '    Sin escalar (se puede hacer después con tools\upscale-videos.py)'
            return
        }
        $model = 'general'
    } elseif (-not $py) {
        Write-Warn2 'Para -VideosAi hace falta Python con PyTorch y spandrel (pip install torch spandrel numpy). Se usan los vídeos normales.'
        return
    }
    Write-Step "Escalando los vídeos con IA (modelo $model; ≈10 min con GPU, una sola vez)…"
    & $py $tool --root $InstallDir --model $model
    if ($LASTEXITCODE -eq 0) { Write-Ok "Máster de vídeo escalado con IA en $InstallDir\videos-hd" }
    else { Write-Warn2 'Falló el escalado con IA: se usan los vídeos normales.' }
}

# -Videos Ask: al actualizar con install, lo elegido (VideosFit.ps1 solo queda en la carpeta con los vídeos
# adaptados); en una instalación nueva o con reinstall se pregunta. Sin consola interactiva, lo elegido
# antes o, si no hay, vídeos originales.
function Resolve-Videos {
    if ($Videos -ne 'Ask') { return }
    if ($Display -ne 'Scaled') { $script:Videos = 'Original'; return }
    if ((Test-Path $Launcher) -and -not ($script:Reinstall -and -not [Console]::IsInputRedirected)) {
        $script:Videos = $(if (Test-Path $VideoFit) { 'Fit' } else { 'Original' })
        return
    }
    if ([Console]::IsInputRedirected) {
        $script:Videos = 'Original'
        Write-Host '    Sin consola para preguntar: vídeos originales (para adaptarlos: -Videos Fit)'
        return
    }
    Write-Host '    El juego estira los vídeos (logos, intro y finales) a lo ancho de la pantalla. Se puede hacer'
    Write-Host '    una copia adaptada a tu monitor, en 4:3 con barras negras (1-2 min; los originales se'
    Write-Host '    conservan; si no tenés ffmpeg se descarga, unos 110 MB).'
    $a = Read-Host '    ¿Adaptar los vídeos a 4:3? [S/n]'
    $script:Videos = $(if ($a -match '^[nN]') { 'Original' } else { 'Fit' })
}

function Install-Videos {
    # UTF-8 con BOM: Windows PowerShell 5.1 lee los .ps1 sin BOM como ANSI
    [System.IO.File]::WriteAllText($VideoFit, $VideoFitCode.Replace('#<Get-ScreenRes>', $ScreenResCode), (New-Object System.Text.UTF8Encoding $true))
    if ($Display -ne 'Scaled' -or $Videos -ne 'Fit') {
        & $VideoFit -Mode restore
        Remove-Item -Force $VideoFit   # sin VideosFit.ps1 el lanzador no toca los vídeos
        Write-Ok 'Vídeos originales'
        return
    }
    if (-not (Get-Ffmpeg)) {
        Write-Warn2 'Sin ffmpeg no se pueden adaptar los vídeos; se usan los originales. Reintentá la instalación más tarde.'
        Remove-Item -Force $VideoFit
        return
    }
    Invoke-VideosAi
    if ($script:Reinstall) { Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $CdDir 'VIDEOS\.fit') }   # regenerarlos
    Write-Step 'Adaptando los vídeos a la resolución del monitor (4:3 centrado con barras negras; 1-2 min)…'
    & $VideoFit -Mode ensure
    if ($LASTEXITCODE -eq 0) { Write-Ok "Vídeos adaptados (originales en $CdDir\VIDEOS\ORIG)" }
    else { Write-Warn2 'No se pudieron adaptar los vídeos: se usan los originales.' }
}

# --------------------------------------------------------------------------- #
#  6. Lanzador y accesos directos
# --------------------------------------------------------------------------- #
#  SC.EXE (lanzador original) exige una unidad de tipo CD-ROM, y montar la imagen puede requerir
#  administrador. En su lugar, el lanzador asigna una letra a la carpeta CD con SUBST (no requiere
#  administrador), escribe CDSC.INS con esa letra (lo que haría SC.EXE) y ejecuta CLASH.EXE
#  directamente; el parche P1 permite arrancar sin SC.EXE. La música (\Musicas) y los vídeos (\Videos)
#  se leen de esa letra.
$LauncherCode = @'
# Lanzador de Space Clash para Windows (generado por install-spaceclash.ps1)
#   -SinVideos: directo al menú principal, sin los vídeos de inicio (logos e intro)
param([switch]$SinVideos)
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Cd = Join-Path $Root 'CD'; $Game = Join-Path $Root 'SCLASH'
$NoVid = Join-Path $Root 'CD-sin-videos'
New-Item -ItemType Directory -Force -Path (Join-Path $Root 'logs') | Out-Null
$Log = Join-Path $Root 'logs\launcher.log'
function L($m) { Add-Content -Path $Log -Value ("{0:yyyy-MM-dd HH:mm:ss} {1}" -f (Get-Date), $m) }
# Vista del CD sin LOGO, DINAMIC ni INTRO (el juego omite los vídeos que no existen). CLASH.EXE solo lee
# \Musicas y \Videos de la letra del CD; UNCLASH.EXE es la marca que comprueba este lanzador. Enlaces duros
# (sin administrador; sin junctions, que Remove-Item -Recurse de PowerShell 5.1 puede seguir) o copia.
function Build-NoVideoView {
    if (Test-Path $NoVid) { Remove-Item -Recurse -Force $NoVid }
    $items = @(Get-Item (Join-Path $Cd 'UNCLASH.EXE')) +
             @(Get-ChildItem -File (Join-Path $Cd 'MUSICAS')) +
             @(Get-ChildItem -File (Join-Path $Cd 'VIDEOS') -Filter 'FINAL*.MPG')
    foreach ($f in $items) {
        $dst = Join-Path $NoVid $f.FullName.Substring($Cd.Length + 1)
        New-Item -ItemType Directory -Force -Path (Split-Path $dst -Parent) | Out-Null
        try { New-Item -ItemType HardLink -Path $dst -Value $f.FullName -ErrorAction Stop | Out-Null }
        catch { Copy-Item $f.FullName $dst }
    }
}
try {
    if (Get-Process -Name CLASH, SPACE -ErrorAction SilentlyContinue) { throw 'El juego ya está en ejecución.' }
    $view = $Cd
    if ($SinVideos) { Build-NoVideoView; $view = $NoVid }
    # ¿Ya hay una letra apuntando a esa carpeta? (p.ej. de una ejecución anterior interrumpida)
    $letter = $null
    foreach ($line in (cmd /c subst)) {
        if ($line -match '^([A-Z]):\\: => (.+)$' -and $Matches[2].TrimEnd('\') -ieq $view) { $letter = $Matches[1] }
    }
    $created = $false
    if (-not $letter) {
        $used = @([System.IO.DriveInfo]::GetDrives() | ForEach-Object { $_.Name.Substring(0, 1).ToUpper() })
        $letter = 'RQPONMLKJIHGFZYXWVU'.ToCharArray() | ForEach-Object { [string]$_ } |
                  Where-Object { $used -notcontains $_ } | Select-Object -First 1
        if (-not $letter) { throw 'No hay letras de unidad libres para el CD virtual.' }
        cmd /c "subst ${letter}: `"$view`"" | Out-Null
        if (-not (Test-Path "${letter}:\UNCLASH.EXE")) { throw "No se pudo asignar ${letter}: a $view" }
        $created = $true
    }
    [System.IO.File]::WriteAllText((Join-Path $Game 'CDSC.INS'), "${letter}:\", [System.Text.Encoding]::ASCII)
    # Vídeos 4:3 con barras (-Videos Fit): regenerarlos si cambió la resolución del monitor (1-2 min)
    $fit = Join-Path $Root 'VideosFit.ps1'
    if ((Test-Path $fit) -and -not $SinVideos) {
        & $fit -Mode check
        if ($LASTEXITCODE -ne 0) {
            L 'Adaptando los vídeos a la resolución del monitor…'
            Add-Type -AssemblyName System.Windows.Forms, System.Drawing
            $tip = New-Object System.Windows.Forms.NotifyIcon
            $tip.Icon = [System.Drawing.SystemIcons]::Information; $tip.Visible = $true
            $tip.ShowBalloonTip(5000, 'Space Clash', 'Adaptando los vídeos a la pantalla (1-2 min)…', 'Info')
            try { & $fit -Mode ensure 6>&1 | ForEach-Object { L "$_" } }
            finally { $tip.Dispose() }
        }
    }
    L "CD en ${letter}: ($view); iniciando CLASH.EXE"
    $p = Start-Process -FilePath (Join-Path $Game 'CLASH.EXE') -WorkingDirectory $Game -PassThru
    $p.WaitForExit()
    # CLASH.EXE espera a SPACE.EXE, pero por las dudas esperar a que no quede ninguno
    while (Get-Process -Name CLASH, SPACE -ErrorAction SilentlyContinue) { Start-Sleep -Seconds 2 }
    L "Juego terminado (código $($p.ExitCode))"
    if ($created) { cmd /c "subst ${letter}: /d" | Out-Null }
} catch {
    L "ERROR: $_"
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show("$_", 'Space Clash') | Out-Null
}
'@

function New-Launcher {
    Write-Step 'Creando lanzador…'
    New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
    # UTF-8 con BOM: Windows PowerShell 5.1 lee los .ps1 sin BOM como ANSI
    [System.IO.File]::WriteAllText($Launcher, $LauncherCode, (New-Object System.Text.UTF8Encoding $true))
    if ($NoShortcut -or -not $IsWin) { Write-Ok "Lanzador: $Launcher"; return }
    $shell = New-Object -ComObject WScript.Shell
    $targets = @( [Environment]::GetFolderPath('Desktop'), (Join-Path ([Environment]::GetFolderPath('Programs')) 'Space Clash') )
    foreach ($dir in $targets) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $lnk = $shell.CreateShortcut((Join-Path $dir 'Space Clash.lnk'))
        $lnk.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $lnk.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Launcher`""
        $lnk.WorkingDirectory = $GameDir
        $lnk.IconLocation = (Join-Path $GameDir 'ICON.ICO') + ',0'
        $lnk.Description = 'Space Clash: The Last Frontier'
        $lnk.Save()
        $lnk = $shell.CreateShortcut((Join-Path $dir 'Space Clash (sin vídeos).lnk'))
        $lnk.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $lnk.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Launcher`" -SinVideos"
        $lnk.WorkingDirectory = $GameDir
        $lnk.IconLocation = (Join-Path $GameDir 'ICON.ICO') + ',0'
        $lnk.Description = 'Space Clash directo al menú principal, sin los vídeos de inicio'
        $lnk.Save()
    }
    Write-Ok 'Accesos directos en el Escritorio y en el menú Inicio (Space Clash, y Space Clash (sin vídeos))'
}

# --------------------------------------------------------------------------- #
#  Comandos
# --------------------------------------------------------------------------- #
function Invoke-Install {
    if ($IsWin -and (Get-Process -Name CLASH, SPACE -ErrorAction SilentlyContinue)) {
        Fail 'El juego está abierto. Cerralo antes de instalar/actualizar.'
    }
    Write-Step "Instalando Space Clash en $InstallDir"
    Test-Res | Out-Null
    Resolve-Videos
    Test-Requirements
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    Expand-GameImage
    Install-GameFiles
    Set-ImportName 'GDI32.dll' | Out-Null   # P1-P4 se verifican sobre el EXE sin el runtime
    Install-Patches
    Install-Runtime
    Install-Display
    Set-GameRes
    Install-Videos
    New-Launcher
    Enable-DirectPlay
    Write-Host ''
    Write-Ok 'Instalación completa. Ejecutá el juego con el acceso directo "Space Clash".'
    Write-Host "    Partidas guardadas: $GameDir\*.sav"
    Write-Host "    Ajustes de pantalla: $GameDir\ddraw.ini (sección [ddraw])"
}

# Reinstalación completa: extrae el CD de nuevo (si está la imagen), recopia el juego, reaplica parches,
# runtime, cnc-ddraw (descargado otra vez) y vídeos, y configura como una instalación nueva: scenh.ini de
# cero con la resolución del monitor detectada otra vez, el juego en 1024x768 y la pregunta de los vídeos.
# Se conservan las partidas (*.sav, *.nfo), CLASH.CFG (salvo la resolución) y el máster de vídeo con IA.
function Invoke-Reinstall {
    if (-not (Test-Path $InstallDir)) {
        Write-Step "No hay una instalación en ${InstallDir}: se hace una instalación nueva"
        Invoke-Install; return
    }
    Write-Step "Reinstalación completa en $InstallDir (se conservan las partidas)"
    $script:Reinstall = $true
    Invoke-Install
}

function Invoke-Doctor {
    $script:DoctorRc = 0
    function Report([string]$Name, [bool]$Ok) {
        if ($Ok) { Write-Ok $Name } else { Write-Warn2 $Name; $script:DoctorRc = 1 }
    }
    Write-Host "InstallDir = $InstallDir"
    Report 'CD extraído (UNCLASH.EXE, MUSICAS, VIDEOS)' ((Test-Path "$CdDir\UNCLASH.EXE") -and (Test-Path "$CdDir\MUSICAS\M0.WAV") -and (Test-Path "$CdDir\VIDEOS\INTRO.MPG"))
    Report 'Juego copiado (CLASH.EXE, SPACE.EXE, ANI\)' ((Test-Path "$GameDir\CLASH.EXE") -and (Test-Path "$GameDir\SPACE.EXE") -and (@(Get-ChildItem -ErrorAction SilentlyContinue "$GameDir\ANI").Count -gt 300))
    $rt = (Test-Path "$GameDir\scenh.dll") -and (Test-Path "$GameDir\CLASH.EXE") -and
          ((Get-ImportName (Join-Path $GameDir 'CLASH.EXE') 0x806d4) -eq 'SCENH.dll')
    foreach ($p in $Patches) {
        $f = Join-Path $GameDir $p.File
        $final = $p.Final
        if ($rt) { $final = ($RuntimeImports | Where-Object { $_.File -eq $p.File }).Final }
        Report ("$($p.File) parcheado" + $(if ($rt) { ' (con runtime)' } else { '' })) ((Test-Path $f) -and ((Get-Sha256 $f) -eq $final))
    }
    if ($rt) {
        $logNote = $(if (Test-Path "$GameDir\scenh.log") { '; registro en scenh.log' } else { '' })
        Write-Ok "Runtime de mejoras activo (opciones en $GameDir\scenh.ini$logNote)"
        $sec = ''; $on = $false; $w = ''; $h = ''
        foreach ($l in [System.IO.File]::ReadAllLines((Join-Path $GameDir 'scenh.ini'))) {
            if ($l -match '^\[(.+)\]') { $sec = $Matches[1] }
            elseif ($sec -eq 'resolucion' -and $l -match '^(activar|ancho|alto)=(\d+)') {
                switch ($Matches[1]) { 'activar' { $on = ($Matches[2] -eq '1') } 'ancho' { $w = $Matches[2] } 'alto' { $h = $Matches[2] } }
            }
        }
        if ($on) { Write-Host "    Resolución panorámica (experimental): ${w}x$h en lugar de 1024x768" }
    }
    else { Write-Host '    Runtime de mejoras: no instalado' }
    Report 'Lanzador' (Test-Path $Launcher)
    if (Test-Path "$GameDir\ddraw.dll") {
        $dd = @(Get-Content "$GameDir\ddraw.ini" | Where-Object { $_ -match '^(renderer|boxing|shader)=' } | Select-Object -First 3) -join '; '
        Write-Host "    Modo de pantalla: Scaled ($dd)"
        if ($IsWin -and -not $NoVideoFix) { Report 'Vídeo: renderer GDI preferido (HKCU)' (Test-Path $VmrKey) }
        $stamp = Join-Path $CdDir 'VIDEOS\.fit'
        if (Test-Path $stamp) { Write-Ok "Vídeos adaptados a la pantalla ($([System.IO.File]::ReadAllText($stamp)))" }
        else { Write-Host '    Vídeos: originales (ver -Videos Fit)' }
        if (Test-Path (Join-Path $InstallDir 'videos-hd\manifest.json')) {
            Write-Host "    Máster de vídeo escalado con IA: $InstallDir\videos-hd (tools\upscale-videos.py)"
        }
        $cfgPath = Join-Path $GameDir 'CLASH.CFG'
        if (Test-Path $cfgPath) {
            $m = ([System.IO.File]::ReadAllBytes($cfgPath))[16]
            Write-Host ("    Resolución del juego: {0}" -f (@{ 0 = '640x400'; 1 = '640x480'; 2 = '800x600'; 3 = '1024x768' }[[int]$m]))
        }
    } else {
        Write-Host '    Modo de pantalla: Native'
        if ($IsWin) {
            $layer = $null; try { $layer = (Get-ItemProperty $CompatKey -ErrorAction Stop).("$GameDir\CLASH.EXE") } catch { }
            Report 'Capas de compatibilidad (XP, 256 colores)' ([bool]$layer)
        }
    }
    if ($IsWin) {
        $dp = $null; try { $dp = (Get-CimInstance Win32_OptionalFeature -Filter "Name='DirectPlay'" -ErrorAction Stop).InstallState } catch { }
        Report 'DirectPlay activado' ($dp -eq 1)
    }
    exit $script:DoctorRc
}

function Invoke-Uninstall {
    if (-not (Test-Path $InstallDir)) { Write-Ok "Nada que desinstalar en $InstallDir"; return }
    # Partidas (*.sav), su índice (*.nfo) y las opciones del juego (CLASH.CFG)
    $saves = @(Get-ChildItem -File -ErrorAction SilentlyContinue -Path "$GameDir\*" -Include '*.sav', '*.nfo', 'CLASH.CFG')
    $backup = $null
    if ($saves.Count -and -not $NoBackup) {
        $backup = Join-Path (Split-Path $InstallDir -Parent) ('SpaceClash-partidas-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    }
    if (-not $Force) {
        if ($backup) { Write-Host "Se eliminará $InstallDir. Las partidas se copian antes a $backup" }
        else { Write-Host "Se eliminará $InstallDir (incluye $($saves.Count) archivo(s) de partidas guardadas)." }
        if ((Read-Host '¿Continuar? [s/N]') -notmatch '^[sSyY]') { Write-Host 'Cancelado.'; return }
    }
    if ($backup) {
        try {
            New-Item -ItemType Directory -Force $backup | Out-Null
            $saves | Copy-Item -Destination $backup
        } catch { throw "No pude copiar las partidas a ${backup}: $_. No se borró nada." }
        Write-Ok "Partidas copiadas a $backup (para recuperarlas, copialas a $GameDir después de instalar)"
    }
    if ($IsWin) {
        foreach ($line in (cmd /c subst)) {
            if ($line -match '^([A-Z]):\\: => (.+)$' -and ($Matches[2].TrimEnd('\') -ieq $CdDir -or
                $Matches[2].TrimEnd('\') -ieq (Join-Path $InstallDir 'CD-sin-videos'))) { cmd /c "subst $($Matches[1]): /d" | Out-Null }
        }
        Set-VmrMerit $false
        Set-CompatLayers $false
        Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Space Clash.lnk')
        Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Space Clash (sin vídeos).lnk')
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue (Join-Path ([Environment]::GetFolderPath('Programs')) 'Space Clash')
    }
    Remove-Item -Recurse -Force $InstallDir
    Write-Ok 'Desinstalado.'
}

# No ejecutar nada si el script se carga con ". .\install-spaceclash.ps1" (pruebas)
if ($MyInvocation.InvocationName -ne '.') {
    try {
        switch ($Command) {
            'install'   { Invoke-Install }
            'reinstall' { Invoke-Reinstall }
            'run'       { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Launcher }
            'doctor'    { Invoke-Doctor }
            'uninstall' { Invoke-Uninstall }
        }
    } catch {
        Write-Host "$_" -ForegroundColor Red
        exit 1
    }
}
