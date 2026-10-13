#!/usr/bin/env python3
"""savdump.py -- volcado de partidas y ficheros de intercambio de Space Clash (1999).

Solo biblioteca estándar. Uso:
    python3 tools/re/savdump.py FICHERO [FICHERO ...] [-v] [--exe-dir CARPETA_CON_LOS_EXE]
Ejemplo (instalación de Linux):  python3 tools/re/savdump.py ~/Games/space-clash/prefix/drive_c/SCLASH/s0.sav
Los nombres de unidades, edificios y naves se leen de los EXE (por defecto, de la carpeta de la partida).

Formatos reconocidos por la cabecera (ver docs/formats/sav.md):
  EFSCLANSSAV      s%d.sav escrito por CLASH.EXE (parte planetaria)   0x417C80 / 0x417040
  EFSCLANSESPTEMP  esp.sav / esp%d.sav (estado del mapa estelar)       SPACE 0x410B90 / 0x4104A0
  EFSCLANSESP      s%d.sav escrito por SPACE.EXE (11 B + descripcion)  SPACE 0x40F650 / 0x40FC20
                   esp.nfo (SPACE -> CLASH, 11 B + comando)            SPACE 0x40F2B0 / CLASH 0x4168D0
  EFSCLANSPLANETA  conf.nfo / planeta.nfo / planeta%d.sav (CLASH -> SPACE)  CLASH 0x4163C0 / 0x4164B0
  EFSCLANSRECOM    recom.nfo (recompensa de mision especial)          CLASH 0x4161D0 / SPACE 0x411CD0
  CLASH.CFG        18 bytes de opciones                               CLASH 0x41FCA0 / 0x41FD60
"""
import struct
import sys

# ---------------------------------------------------------------- tablas
RANKS = ["Capitan", "Comandante", "Coronel", "General", "Gobernador"]          # CLASH 0x4276D0
MODES = ["Campana Espacial", "Campana Lineal", "Modo Escenarios",
         "Modo Misiones", "Multijugador"]                                      # CLASH 0x427790
EMPIRES = ["KRAKEDER", "CORIANT", "SELIANI", "CIBERNIA"]
MATERIALS = ["Mercurio", "Gas Radon", "Rutenio", "Mithril",
             "Maquinaria", "Prod. Quimicos", "Alta Tecnologia"]                # CLASH 0x47BF1E (stride 0x14)
BONUS = ["Ataque", "Defensa", "Comercio", "Politica", "Opresion"]              # SPACE 0x429F..
# Los nombres de unidades, edificios y naves se leen del CLASH.EXE/SPACE.EXE del usuario (no se copian
# textos del juego en este archivo; REMASTER §13). Se buscan junto a la partida o en --exe-dir.
UNIT_TYPES = []       # CLASH 0x478448, entradas de 0x58 B, código en +0x1D
BUILDING_TYPES = []   # CLASH 0x479360, entradas de 0xA0 B, nombre en +0x24
SHIP_TYPES = []       # SPACE 0x43E9F8, entradas de 0x50 B, id en +0x10, código en +0x12, nombre en +0x26
TABLES = (("CLASH.EXE", 0x478448, 0x58, (0x1D,), 42, UNIT_TYPES),
          ("CLASH.EXE", 0x479360, 0xA0, (0x24,), 29, BUILDING_TYPES),
          ("SPACE.EXE", 0x43E9F8, 0x50, (0x12, 0x26), 11, SHIP_TYPES))


def load_names(folder):
    """Rellena las tablas de nombres desde los EXE de `folder` (sin distinguir mayúsculas)."""
    import os
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from pe import PE
    try:
        entries = {e.upper(): os.path.join(folder, e) for e in os.listdir(folder)}
    except OSError:
        return False
    loaded = False
    for exe, base, stride, offs, count, out in TABLES:
        path = entries.get(exe)
        if not path or out:
            continue
        data = open(path, "rb").read()
        pe = PE(data)
        for i in range(count):
            parts = []
            for off in offs:
                o = pe.va_to_off(base + i * stride + off)
                parts.append(data[o:data.index(b"\0", o)].decode("cp1252").strip())
            name = " ".join(x for x in parts if x)
            out.append(name or "(%d)" % i)
        loaded = True
    return loaded


def tname(tab, i):
    return tab[i] if 0 <= i < len(tab) else "tipo %d" % i


DIPLO = {0: "guerra", 1: "paz", 2: "alianza"}                                  # CLASH 0x404D00/0x404FA0/0x4051C0


def emp(i):
    return EMPIRES[i] if 0 <= i < 4 else "jugador %d (no imperio)" % i


class Trunc(Exception):
    pass


class R:
    def __init__(self, d):
        self.d, self.o = d, 0

    def b(self, n):
        if self.o + n > len(self.d):
            raise Trunc("fin de fichero en 0x%X (se pedian %d B)" % (self.o, n))
        v = self.d[self.o:self.o + n]
        self.o += n
        return v

    def _u(self, fmt):
        n = struct.calcsize(fmt)
        return struct.unpack(fmt, self.b(n))[0]

    def u8(self): return self._u("<B")
    def i8(self): return self._u("<b")
    def i16(self): return self._u("<h")
    def i32(self): return self._u("<i")
    def f64(self): return self._u("<d")

    def cstr(self, n):
        return self.b(n).split(b"\0")[0].decode("latin-1")


def cstr(buf, off, n=32):
    return buf[off:off + n].split(b"\0")[0].decode("latin-1")


# ---------------------------------------------------------------- bloques comunes
OPT_NAMES = ["opt0", "opt1", "opt2", "opt3", "opt4(musica)", "opt5", "vol_fx", "vol_musica"]


def read_conf_block(r):
    """Bloque comun de conf.nfo/planeta.nfo/recom.nfo: u16 resolucion, u8 jugador, 8 x i32 opciones."""
    res = r.i16()
    player = r.i8()
    opts = [r.i32() for _ in range(8)]
    return res, player, opts


def read_diplo4(r, with_credits=True, credits_first=False):
    """4 x {[f64 creditos], 4 x (u8 alianza, f64 relacion), 5 x i16 bonificaciones}"""
    out = []
    for _ in range(4):
        cred = r.f64() if credits_first else None
        rel = [(r.u8(), r.f64()) for _ in range(4)]
        if with_credits and not credits_first:
            cred = r.f64()
        bon = [r.i16() for _ in range(5)]
        out.append((cred, rel, bon))
    return out


def print_diplo(rows, me=None):
    for p, (cred, rel, bon) in enumerate(rows):
        mark = " <- jugador" if p == me else ""
        print("  %-9s creditos=%s%s" % (emp(p), "%.0f" % cred if cred is not None else "-", mark))
        print("            relaciones: " + ", ".join(
            "%s=%.0f/%s" % (emp(j)[:4], v, DIPLO.get(a, a)) for j, (a, v) in enumerate(rel) if j != p))
        print("            bonif.: " + ", ".join("%s %+d%%" % (BONUS[k], v) for k, v in enumerate(bon)))


# ---------------------------------------------------------------- CLASH s%d.sav
PLAYER_REC = 0x260  # CLASH 0x881F60, 6 registros


def clash_player(rec):
    return {
        "activo": struct.unpack_from("<i", rec, 0x04)[0],
        "alianza": list(rec[0x08:0x0C]),
        "relacion": struct.unpack_from("<4d", rec, 0x10),
        "creditos": struct.unpack_from("<d", rec, 0x78)[0],
        "n_unidades": struct.unpack_from("<i", rec, 0x80)[0],
        "n_edificios": struct.unpack_from("<i", rec, 0x84)[0],
        "materiales": struct.unpack_from("<7d", rec, 0x178),
        "precios": struct.unpack_from("<7h", rec, 0x1BE),
        "nombre": cstr(rec, 0x1E0, 16),
        "bonif": struct.unpack_from("<5h", rec, 0x214),
    }


def dump_clash_sav(r, verbose):
    r.b(11)
    desc = r.cstr(0x96)
    mode, rank, terrain, b7287f0 = r.u8(), r.u8(), r.u8(), r.u8()
    dw = [r.i32() for _ in range(16)]
    gtime = dw[15]
    players = [clash_player(r.b(PLAYER_REC)) for _ in range(6)]
    me = r.i8()
    print("Partida planetaria (CLASH.EXE)")
    print("  descripcion : %s" % desc)
    print("  modo        : %d (%s)   rango: %d (%s)   terreno: suelos%02d   jugador: %d (%s)" % (
        mode, tname(MODES, mode), rank, tname(RANKS, rank), terrain, me, emp(me)))
    print("  tiempo      : %d:%02d:%02d (h:m:s, 0x693EF4)" % (
        (gtime >> 16) & 0xFFFF, (gtime >> 8) & 0xFF, gtime & 0xFF))
    if verbose:
        print("  opciones    : %s  (byte 0x7287F0=%d)" % (dw[:15], b7287f0))
    r.b(0x0C * 4)
    r.b(4 * 5)
    r.b(0x4C8 * 4)
    r.b(8 * 6)
    r.i32()
    # unidades
    nu = r.i32()
    units = []
    for _ in range(nu):
        p, slot = r.i32(), r.i32()
        rec = r.b(0x4C8)
        t = r.i16()
        r.i16()
        [r.i16() for _ in range(10)]
        units.append((p, slot, t, rec))
    nb = r.i32()
    blds = []
    for _ in range(nb):
        p, slot = r.i32(), r.i32()
        rec = r.b(0x3C)
        t = r.i8()
        blds.append((p, slot, t, rec))
    r.u8()
    r.i32()
    nfx = r.i32()
    for _ in range(nfx):
        r.i32(); r.b(0x48); r.i8()
        for _k in range(2):
            if r.i8() != -1:
                r.i16()
    w, h = r.i16(), r.i16()
    r.b(4 * 5)
    for _ in range(max(0, w) * max(0, h)):
        r.b(0x3C)
        for _k in range(4):
            if r.i8() != -1:
                r.i16()
    r.b(0x1000); r.b(40000); r.b(40000); r.i16(); r.i16(); r.b(0x14 * 0x14)
    mission = r.u8()
    result = r.u8()
    r.i16(); r.b(0x2A); r.b(0x22); r.b(0x38 * 6); r.i32()
    reserve = [r.f64() for _ in range(4)]
    print("  mapa        : %dx%d   mision: %d   resultado(0x483BB0): %d" % (w, h, mission, result))
    print("Recursos por imperio:")
    for i, pl in enumerate(players[:4]):
        mark = " <- jugador" if i == me else ""
        print("  %-9s activo=%d creditos=%.0f reserva_espacial=%.0f%s" % (
            pl["nombre"] or emp(i), pl["activo"], pl["creditos"], reserve[i], mark))
        print("            " + ", ".join("%s=%.0f" % (MATERIALS[k], v) for k, v in enumerate(pl["materiales"])))
        if verbose:
            print("            relaciones=%s estado=%s bonif=%s" % (
                ["%.0f" % x for x in pl["relacion"]], [DIPLO.get(a, a) for a in pl["alianza"]], pl["bonif"]))
    print("Unidades: %d" % nu)
    by = {}
    for p, slot, t, rec in units:
        by.setdefault(p, []).append((slot, t, rec))
    for p in sorted(by):
        print("  %s (%d):" % (emp(p), len(by[p])))
        for slot, t, rec in by[p]:
            hp = struct.unpack_from("<h", rec, 0x48)[0]
            x, y = struct.unpack_from("<hh", rec, 0x70)
            exp_ = struct.unpack_from("<i", rec, 0x50)[0]
            print("    #%-3d %-12s celda=(%d,%d) vida=%d experiencia?=%d" % (slot, tname(UNIT_TYPES, t), x, y, hp, exp_))
    print("Edificios: %d" % nb)
    for p, slot, t, rec in blds:
        x, y = struct.unpack_from("<hh", rec, 0x10)
        hp = struct.unpack_from("<h", rec, 0x24)[0]
        print("    %-9s #%-3d %-40s celda=(%d,%d) vida=%d" % (emp(p), slot, tname(BUILDING_TYPES, t), x, y, hp))
    print("Proyectiles/efectos: %d" % nfx)
    return r.o


# ---------------------------------------------------------------- estado espacial
def dump_space_tail(r, verbose, me):
    print("Imperios:")
    for p in range(4):
        rec = r.b(0xF0)
        n = struct.unpack_from("<h", rec, 0x3A)[0]
        name = cstr(rec, 0xC8, 16)
        cred = struct.unpack_from("<d", rec, 0x28)[0]
        planets, total, cargo, war, other = struct.unpack_from("<5h", rec, 0x38)
        bon = struct.unpack_from("<5h", rec, 0xE0)
        mark = " <- jugador" if p == me else ""
        print("  %-9s creditos=%.0f planetas=%d naves=%d (guerra %d, carga %d, otras %d)%s" % (
            name, cred, planets, total, war, cargo, other, mark))
        print("            bonif.: " + ", ".join("%s %+d%%" % (BONUS[k], v) for k, v in enumerate(bon)))
        if verbose:
            rel = struct.unpack_from("<4d", rec, 0x08)
            print("            relaciones=%s estado=%s" % (["%.0f" % x for x in rel],
                                                         [DIPLO.get(a, a) for a in rec[4:8]]))
        for _ in range(n):
            slot = r.i16()
            srec = r.b(0x388)
            t = r.i16()
            hp = struct.unpack_from("<i", srec, 8)[0]
            print("    nave #%-3d %-28s vida?=%d" % (slot, tname(SHIP_TYPES, t), hp))
    r.i16(); r.i16()
    w, h = r.i16(), r.i16()
    r.i32(); r.i32()
    r.b(12 * w * h)
    npl = r.i16()
    print("Mapa estelar %dx%d; planetas guardados: %d" % (w, h, npl))
    for _ in range(npl):
        idx = r.i16()
        prec = r.b(0x1108)
        owner = struct.unpack_from("<h", prec, 0x0E)[0]
        minrank = struct.unpack_from("<h", prec, 0x14)[0]
        print("    planeta %2d %-12s mapa=%-14s dueno=%s rango_min=%d sector=(%d,%d)" % (
            idx, cstr(prec, 0x2A, 16), cstr(prec, 0x1C, 14), emp(owner) if 0 <= owner < 4 else "-",
            minrank, prec[0x0B], prec[0x0C]))
    for _ in range(3):
        a, b = r.i16(), r.i16()
        r.i32(); r.i32()
        r.b(8 * max(0, a) * max(0, b))
    r.b(16 * 5000)
    t = [r.i32() for _ in range(5)]
    r.b(0x330 * 4)
    r.u8(); r.u8()
    if verbose:
        print("  dwords finales (0x8071F4, 0x69A600, 0x485CF0, 0x487D10, 0x76E8A4): %s" % t)
    return r.o


def dump_esptemp(r, verbose):
    r.b(15)
    rank, me, galaxy, planet, fleet = r.i8(), r.i8(), r.u8(), r.u8(), r.i32()
    print("Estado del mapa estelar (esp.sav, SPACE.EXE)")
    print("  rango: %d (%s)  jugador: %d (%s)  variante galaxia: %d  planeta destino: %d  flota/param: %d" % (
        rank, tname(RANKS, rank), me, emp(me), galaxy, planet, fleet))
    return dump_space_tail(r, verbose, me)


def dump_space_sav(r, verbose):
    r.b(11)
    desc = r.cstr(0x96)
    me, galaxy, rank = r.i8(), r.u8(), r.i8()
    opts = [r.i32() for _ in range(8)]
    print("Partida espacial (SPACE.EXE)")
    print("  descripcion : %s" % desc)
    print("  rango: %d (%s)  jugador: %d (%s)  variante galaxia: %d" % (
        rank, tname(RANKS, rank), me, emp(me), galaxy))
    if verbose:
        print("  opciones: %s" % opts)
    return dump_space_tail(r, verbose, me)


# ---------------------------------------------------------------- .nfo
def dump_esp_nfo(r, verbose):
    r.b(11)
    cmd = r.i8()
    names = {0: "ir a mision planetaria", 1: "volver al menu / salir",
             2: "cargar partida planetaria", 3: "mision final"}
    print("esp.nfo (SPACE -> CLASH): comando %d (%s)" % (cmd, names.get(cmd, "?")))
    if cmd == 1:
        return r.o
    if cmd == 2:
        print("  ranura: %d" % r.i16())
        return r.o
    me = r.i8()
    opts = [r.i32() for _ in range(8)]
    rank, mission = r.i8(), r.i8()
    print("  jugador %d (%s) rango %d (%s) mision %d  opciones=%s" % (
        me, emp(me), rank, tname(RANKS, rank), mission, opts))
    rows = []
    for _ in range(4):
        rel = [(r.u8(), r.f64()) for _ in range(4)]
        cred = r.f64()
        bon = [r.i16() for _ in range(5)]
        rows.append((cred, rel, bon))
    print_diplo(rows, me)
    n = r.i16()
    print("  unidades que bajan al planeta: %d" % n)
    for _ in range(n):
        t, v = r.i8(), r.i32()
        print("    tipo %d valor %d" % (t, v))
    print("  planetas colonizados (0x455C38 -> 0x728C90): %d" % r.i16())
    return r.o


def dump_planeta(r, verbose, fname):
    r.b(15)
    res, me, opts = read_conf_block(r)
    print("%s (CLASH -> SPACE): resolucion=%d jugador=%d (%s) opciones=%s" % (fname, res, me, emp(me), opts))
    if r.o >= len(r.d):
        return r.o  # conf.nfo
    code = r.i8()
    if code == -1:
        print("  codigo -1: empezar campana nueva")
        return r.o
    if code == -2:
        print("  codigo -2: cargar partida espacial de la ranura %d" % r.i8())
        return r.o
    if code == -3:
        n = r.i32()
        print("  codigo -3: retirada; %d unidades vuelven a las naves" % n)
        for _ in range(n):
            t, v = r.i16(), r.i32()
            print("    %s valor=%d" % (tname(UNIT_TYPES, t), v))
    else:
        print("  codigo %d: fin de mision, rango %s" % (code, tname(RANKS, code)))
    mission, won = r.i8(), r.i32()
    print("  mision=%d victoria=%d" % (mission, won))
    rows = []
    for _ in range(4):
        cred = r.f64()
        rel = [(r.u8(), r.f64()) for _ in range(4)]
        bon = [r.i16() for _ in range(5)]
        rows.append((cred, rel, bon))
    print_diplo(rows, me)
    if won:
        n = r.i32()
        print("  unidades supervivientes: %d" % n)
        for _ in range(n):
            t, v = r.i16(), r.i32()
            print("    %-12s valor=%d" % (tname(UNIT_TYPES, t), v))
        nb = r.i32()
        bl = [r.i8() for _ in range(nb)]
        print("  edificios: %d -> %s" % (nb, ", ".join(tname(BUILDING_TYPES, t) for t in bl)))
        mats = [r.f64() for _ in range(7)]
        print("  materiales: " + ", ".join("%s=%.0f" % (MATERIALS[k], v) for k, v in enumerate(mats)))
    return r.o


def dump_recom(r, verbose):
    r.b(13)
    res, me, opts = read_conf_block(r)
    print("recom.nfo: resolucion=%d jugador=%d (%s) opciones=%s" % (res, me, emp(me), opts))
    rows = []
    for _ in range(4):
        cred = r.f64()
        rel = [(r.u8(), r.f64()) for _ in range(4)]
        bon = [r.i16() for _ in range(5)]
        rows.append((cred, rel, bon))
    print_diplo(rows, me)
    return r.o


def dump_cfg(r, verbose):
    flags = list(r.b(7))
    vfx, vmus = r.i32(), r.i32()
    b, s = r.u8(), r.i16()
    print("CLASH.CFG: banderas=%s vol_fx=%d vol_musica=%d byte(0x693E61)=%d short(0x492108)=%d" % (
        flags, vfx, vmus, b, s))
    return r.o


# ---------------------------------------------------------------- main
def dump(path, verbose):
    with open(path, "rb") as f:
        d = f.read()
    r = R(d)
    base = path.replace("\\", "/").rsplit("/", 1)[-1].lower()
    print("=" * 72)
    print("%s (%d bytes)" % (path, len(d)))
    try:
        if d.startswith(b"EFSCLANSSAV"):
            end = dump_clash_sav(r, verbose)
        elif d.startswith(b"EFSCLANSESPTEMP"):
            end = dump_esptemp(r, verbose)
        elif d.startswith(b"EFSCLANSESP"):
            end = dump_esp_nfo(r, verbose) if len(d) < 200 else dump_space_sav(r, verbose)
        elif d.startswith(b"EFSCLANSPLANETA"):
            end = dump_planeta(r, verbose, base)
        elif d.startswith(b"EFSCLANSRECOM"):
            end = dump_recom(r, verbose)
        elif base == "clash.cfg" or len(d) == 18:
            end = dump_cfg(r, verbose)
        else:
            print("formato desconocido (cabecera %r)" % d[:16])
            return 1
    except Trunc as e:
        print("!! fichero truncado o formato distinto: %s" % e)
        return 1
    except (struct.error, IndexError, ValueError) as e:
        print("!! error de formato en 0x%X: %s" % (r.o, e))
        return 1
    if end != len(d):
        print("!! consumidos %d de %d bytes (layout incompleto)" % (end, len(d)))
    else:
        print("[layout completo: %d/%d bytes]" % (end, len(d)))
    return 0


def main(argv):
    verbose = "-v" in argv
    exe_dir = None
    if "--exe-dir" in argv:
        i = argv.index("--exe-dir")
        exe_dir = argv[i + 1] if i + 1 < len(argv) else None
        del argv[i:i + 2]
    files = [a for a in argv if a != "-v"]
    if not files:
        print(__doc__)
        return 2
    import os
    if not load_names(exe_dir or os.path.dirname(os.path.abspath(files[0]))):
        print("(sin CLASH.EXE/SPACE.EXE junto a la partida ni --exe-dir: se muestran números de tipo)\n")
    rc = 0
    for p in files:
        try:
            rc |= dump(p, verbose)
        except OSError as e:
            print("%s: %s" % (p, e))
            rc = 1
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
