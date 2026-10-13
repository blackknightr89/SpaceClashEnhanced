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
    - Crea un lanzador (accesos directos en Escritorio y menú Inicio) que asigna una letra de
      unidad a la carpeta del CD con SUBST y ejecuta el juego.
    Documentación para usuarios: README.md.

.EXAMPLE
    # Doble clic en install-spaceclash.cmd, o desde PowerShell:
    powershell -ExecutionPolicy Bypass -File .\install-spaceclash.ps1
    powershell -ExecutionPolicy Bypass -File .\install-spaceclash.ps1 -Display Native
    powershell -ExecutionPolicy Bypass -File .\install-spaceclash.ps1 -Command doctor
    powershell -ExecutionPolicy Bypass -File .\install-spaceclash.ps1 -Command uninstall
#>
[CmdletBinding()]
param(
    [ValidateSet('install', 'run', 'doctor', 'uninstall')]
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
    # No tocar el renderizador de vídeo de DirectShow (ver Set-VmrMerit más abajo)
    [switch]$NoVideoFix,
    [switch]$NoShortcut,
    [switch]$SkipHash,
    [switch]$SkipDirectPlay,
    # Para uninstall: no pedir confirmación
    [switch]$Force
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
$IsWin       = [System.Environment]::OSVersion.Platform -eq 'Win32NT'

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
    if ((Test-Path (Join-Path $CdDir 'UNCLASH.EXE')) -and (Test-Path (Join-Path $CdDir 'MUSICAS'))) {
        Write-Ok "CD ya extraído en $CdDir"; return
    }
    $img = Resolve-Image
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
function Install-GameFiles {
    Write-Step "Copiando el juego a $GameDir…"
    New-Item -ItemType Directory -Force -Path $GameDir | Out-Null
    foreach ($f in 'SC.EXE', 'CLASH.EXE', 'SPACE.EXE', 'UNCLASH.EXE', 'PALCF.DAT', 'PALCS.DAT', 'PALS.DAT',
                   'PALT020.DAT', 'PALT030.DAT', 'PALT040.DAT', 'ICON.ICO') {
        Copy-Item -Force (Join-Path $CdDir $f) (Join-Path $GameDir $f)
    }
    # Opciones del juego: solo la primera vez. Las partidas (*.sav) nunca se tocan.
    if (-not (Test-Path (Join-Path $GameDir 'CLASH.CFG'))) { Copy-Item (Join-Path $CdDir 'CLASH.CFG') $GameDir }
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
    Remove-Item -Recurse -Force $tmp
    $settings = [ordered]@{ fullscreen = 'true'; windowed = 'false'; maintas = 'true'; boxing = 'false'
                           width = '0'; height = '0'; renderer = $Renderer; adjmouse = 'true'
                           vsync = 'false'; devmode = 'false'; savesettings = '0' }
    foreach ($k in $settings.Keys) { Set-IniKey $ini $k $settings[$k] }
    Set-CompatLayers $false          # las capas de compatibilidad interfieren con cnc-ddraw
    Set-VmrMerit (-not $NoVideoFix)
    Write-Ok "cnc-ddraw configurado (renderer=$Renderer; ajustes en $ini, sección [ddraw])"
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
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Cd = Join-Path $Root 'CD'; $Game = Join-Path $Root 'SCLASH'
New-Item -ItemType Directory -Force -Path (Join-Path $Root 'logs') | Out-Null
$Log = Join-Path $Root 'logs\launcher.log'
function L($m) { Add-Content -Path $Log -Value ("{0:yyyy-MM-dd HH:mm:ss} {1}" -f (Get-Date), $m) }
try {
    if (Get-Process -Name CLASH, SPACE -ErrorAction SilentlyContinue) { throw 'El juego ya está en ejecución.' }
    # ¿Ya hay una letra apuntando a la carpeta CD? (p.ej. de una ejecución anterior interrumpida)
    $letter = $null
    foreach ($line in (cmd /c subst)) {
        if ($line -match '^([A-Z]):\\: => (.+)$' -and $Matches[2].TrimEnd('\') -ieq $Cd) { $letter = $Matches[1] }
    }
    $created = $false
    if (-not $letter) {
        $used = @([System.IO.DriveInfo]::GetDrives() | ForEach-Object { $_.Name.Substring(0, 1).ToUpper() })
        $letter = 'RQPONMLKJIHGFZYXWVU'.ToCharArray() | ForEach-Object { [string]$_ } |
                  Where-Object { $used -notcontains $_ } | Select-Object -First 1
        if (-not $letter) { throw 'No hay letras de unidad libres para el CD virtual.' }
        cmd /c "subst ${letter}: `"$Cd`"" | Out-Null
        if (-not (Test-Path "${letter}:\UNCLASH.EXE")) { throw "No se pudo asignar ${letter}: a $Cd" }
        $created = $true
    }
    [System.IO.File]::WriteAllText((Join-Path $Game 'CDSC.INS'), "${letter}:\", [System.Text.Encoding]::ASCII)
    L "CD en ${letter}: ; iniciando CLASH.EXE"
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
    }
    Write-Ok 'Accesos directos en el Escritorio y en el menú Inicio (Space Clash)'
}

# --------------------------------------------------------------------------- #
#  Comandos
# --------------------------------------------------------------------------- #
function Invoke-Install {
    if ($IsWin -and (Get-Process -Name CLASH, SPACE -ErrorAction SilentlyContinue)) {
        Fail 'El juego está abierto. Cerralo antes de instalar/actualizar.'
    }
    Write-Step "Instalando Space Clash en $InstallDir"
    Test-Requirements
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    Expand-GameImage
    Install-GameFiles
    Install-Patches
    Install-Display
    New-Launcher
    Enable-DirectPlay
    Write-Host ''
    Write-Ok 'Instalación completa. Ejecutá el juego con el acceso directo "Space Clash".'
    Write-Host "    Partidas guardadas: $GameDir\*.sav"
    Write-Host "    Ajustes de pantalla: $GameDir\ddraw.ini (sección [ddraw])"
}

function Invoke-Doctor {
    $script:DoctorRc = 0
    function Report([string]$Name, [bool]$Ok) {
        if ($Ok) { Write-Ok $Name } else { Write-Warn2 $Name; $script:DoctorRc = 1 }
    }
    Write-Host "InstallDir = $InstallDir"
    Report 'CD extraído (UNCLASH.EXE, MUSICAS, VIDEOS)' ((Test-Path "$CdDir\UNCLASH.EXE") -and (Test-Path "$CdDir\MUSICAS\M0.WAV") -and (Test-Path "$CdDir\VIDEOS\INTRO.MPG"))
    Report 'Juego copiado (CLASH.EXE, SPACE.EXE, ANI\)' ((Test-Path "$GameDir\CLASH.EXE") -and (Test-Path "$GameDir\SPACE.EXE") -and (@(Get-ChildItem -ErrorAction SilentlyContinue "$GameDir\ANI").Count -gt 300))
    foreach ($p in $Patches) {
        $f = Join-Path $GameDir $p.File
        Report "$($p.File) parcheado" ((Test-Path $f) -and ((Get-Sha256 $f) -eq $p.Final))
    }
    Report 'Lanzador' (Test-Path $Launcher)
    if (Test-Path "$GameDir\ddraw.dll") {
        Write-Host '    Modo de pantalla: Scaled'
        if ($IsWin -and -not $NoVideoFix) { Report 'Vídeo: renderer GDI preferido (HKCU)' (Test-Path $VmrKey) }
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
    $saves = @(Get-ChildItem -ErrorAction SilentlyContinue "$GameDir\*.sav")
    if (-not $Force) {
        Write-Host "Se eliminará $InstallDir (incluye $($saves.Count) archivo(s) de partidas guardadas)."
        if ((Read-Host '¿Continuar? [s/N]') -notmatch '^[sSyY]') { Write-Host 'Cancelado.'; return }
    }
    if ($IsWin) {
        foreach ($line in (cmd /c subst)) {
            if ($line -match '^([A-Z]):\\: => (.+)$' -and $Matches[2].TrimEnd('\') -ieq $CdDir) { cmd /c "subst $($Matches[1]): /d" | Out-Null }
        }
        Set-VmrMerit $false
        Set-CompatLayers $false
        Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Space Clash.lnk')
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
            'run'       { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Launcher }
            'doctor'    { Invoke-Doctor }
            'uninstall' { Invoke-Uninstall }
        }
    } catch {
        Write-Host "$_" -ForegroundColor Red
        exit 1
    }
}
