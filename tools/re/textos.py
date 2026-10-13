#!/usr/bin/env python3
"""textos.py — extrae los textos del juego (CLASH.EXE y SPACE.EXE) a JSON en UTF-8 (mejora L1).

Para cada cadena guarda el EXE, su dirección virtual, el texto con el marcado original (|n salto de línea,
|tN tabulación/sangría, |cNNN color; los %s/%d/%ld son de printf) y quién la referencia: instrucciones de
.text (push/mov con la dirección) o tablas de punteros en .data. Esas referencias son las que la etapa 3
redirige para la traducción (L2).

Uso:
    python3 tools/re/textos.py CARPETA_CON_LOS_EXE -o text/es.json
    python3 tools/re/textos.py ~/Games/space-clash/cd --all      # incluye rutas, formatos y nombres internos

Por defecto filtra lo que no es texto para el jugador (rutas de archivos, nombres de API, cadenas de la
CRT). Nunca escribe en los EXE.
"""
import argparse
import json
import re
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from pe import PE  # noqa: E402
from scformats import find_ci  # noqa: E402

PRINTABLE = set(range(0x20, 0x7F)) | set(range(0xA0, 0x100)) | {0x09, 0x0A, 0x0D}
# Caracteres de Windows-1252 en 0x80–0x9F que aparecen en textos (comillas, guiones, …)
PRINTABLE |= {0x85, 0x91, 0x92, 0x93, 0x94, 0x96, 0x97}
MARKUP = re.compile(r"\|(?:c\d{3}|c%03d|n|t\d)")
TECH = re.compile(
    r"(\\|\.(?:pcx|spc|spr|flc|map|dat|sav|wav|mpg|cfg|nfo|ins|exe|dll)\b|^[A-Z][a-z]+[A-Z]\w+$|"
    r"^_|^\W*$|^\.\w+$|^%[-\d.]*[sdlxXcfu]$|^[a-z0-9_]+$|runtime|R60\d\d|Microsoft|MSVCRT|\bDOMAIN\b|"
    r"\bSING\b|\bTLOSS\b|^GetLast|^Kernel|^user32|^Wine|^\s*\w+\.\w{3}\s*$)", re.I)


def scan(pe, data, min_len):
    """Cadenas C terminadas en NUL dentro de .rdata y .data."""
    for name in (".rdata", ".data"):
        try:
            sec = pe.section(name)
        except StopIteration:
            continue
        end = sec.raw + min(sec.rawsize, sec.vsize or sec.rawsize)
        i = sec.raw
        while i < end:
            if data[i] in PRINTABLE:
                j = i
                while j < end and data[j] in PRINTABLE:
                    j += 1
                if j < end and data[j] == 0 and j - i >= min_len:
                    yield name, i, data[i:j]
                i = j + 1
            else:
                i += 1


def references(pe, data, va):
    """Lugares donde aparece la dirección `va` como dword: código (.text) o tablas (.data/.rdata)."""
    needle = struct.pack("<I", va)
    out = []
    start = 0
    while True:
        k = data.find(needle, start)
        if k < 0:
            break
        start = k + 1
        rva = pe.off_to_va(k)
        sec = pe.section_of_va(rva) if rva else None
        if sec == ".text":
            op = data[k - 1] if k else 0
            # 68 = push imm32; B8–BF = mov reg, imm32; C7 = mov r/m32, imm32 (el imm va al final)
            kind = {0x68: "push"}.get(op, "mov" if 0xB8 <= op <= 0xBF else "code")
            out.append({"at": f"0x{rva - (1 if kind != 'code' else 0):06X}", "kind": kind})
        elif sec in (".data", ".rdata"):
            out.append({"at": f"0x{rva:06X}", "kind": "table"})
    return out


def is_player_text(s):
    if TECH.search(s):
        return False
    letters = sum(c.isalpha() for c in s)
    return letters >= 2 and letters >= len(MARKUP.sub("", s)) * 0.4


def extract(exe_path, keep_all, min_len):
    data = Path(exe_path).read_bytes()
    pe = PE(data)
    out = []
    for sec, off, raw in scan(pe, data, min_len):
        text = raw.decode("cp1252", errors="replace")
        if not keep_all and not is_player_text(text):
            continue
        va = pe.off_to_va(off)
        refs = references(pe, data, va)
        if not refs and not keep_all and not MARKUP.search(text) and len(text) < 12:
            continue  # cadenas cortas sin referencias: casi siempre restos de datos binarios
        out.append({"exe": Path(exe_path).name.upper(), "va": f"0x{va:06X}", "section": sec,
                    "bytes": len(raw), "text": text, "refs": refs})
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("folder", help="carpeta con CLASH.EXE y SPACE.EXE (CD o instalación)")
    ap.add_argument("-o", "--output", help="archivo JSON (por defecto, a la salida estándar)")
    ap.add_argument("--all", action="store_true", help="no filtrar rutas, nombres internos ni cadenas de la CRT")
    ap.add_argument("--min-len", type=int, default=3)
    a = ap.parse_args()

    entries = []
    for exe in ("CLASH.EXE", "SPACE.EXE"):
        entries += extract(find_ci(a.folder, exe), a.all, a.min_len)
    doc = {"lang": "es", "encoding_in_exe": "cp1252",
           "markup": {"|n": "salto de línea", "|tN": "sangría/tabulación", "|cNNN": "color (índice de paleta)",
                      "%s %d %ld": "argumentos de printf: conservar en el mismo orden"},
           "strings": entries}
    js = json.dumps(doc, ensure_ascii=False, indent=1)
    if a.output:
        Path(a.output).parent.mkdir(parents=True, exist_ok=True)
        Path(a.output).write_text(js + "\n", encoding="utf-8")
    else:
        print(js)
    n = {e: sum(1 for s in entries if s["exe"] == e) for e in ("CLASH.EXE", "SPACE.EXE")}
    unref = sum(1 for s in entries if not s["refs"])
    print(f"{len(entries)} cadenas ({n['CLASH.EXE']} CLASH, {n['SPACE.EXE']} SPACE); {unref} sin referencia directa",
          file=sys.stderr)


if __name__ == "__main__":
    main()
