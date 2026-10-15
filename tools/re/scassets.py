#!/usr/bin/env python3
"""scassets.py — exporta y valida los assets de TU copia de Space Clash (etapa 2 de docs/PLAN.md).

Subcomandos:
    spc   ARCHIVO.SPC…  → hoja PNG con transparencia + índice JSON (y, con --frames, un PNG por sprite)
    spr   ARCHIVO.SPR…  → hoja PNG + índice JSON (tiles de suelo, iconos del universo…)
    map   ARCHIVO.MAP…  → PNG del terreno (con SUELOS<nn>.SPR) + JSON con las celdas (map2json)
    flc   ARCHIVO.FLC…  → hoja PNG con todos los fotogramas (o GIF con --gif)
    pcx   ARCHIVO.PCX…  → PNG
    all   CARPETA_DEL_JUEGO  → todo lo anterior y un informe; código de salida ≠ 0 si algo no se pudo leer

CARPETA_DEL_JUEGO puede ser el CD extraído (tools/re/iso9660.py --extract) o la instalación (SCLASH/).
Los FLC se leen de ANI.ZIP o de la carpeta ANI/. La paleta por defecto es IMG/PALETA.PCX (la del juego).

Requisitos: Python 3.10+ y Pillow (pip install pillow).
Ejemplo:
    python3 tools/re/iso9660.py disk/ --extract /tmp/sc-cd
    python3 tools/re/scassets.py all /tmp/sc-cd --out /tmp/sc-export
Lo exportado sale de tu CD: no lo subas a ningún sitio (ver PLAN §13).
"""
import argparse
import hashlib
import json
import sys
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import scformats as sf  # noqa: E402
from flc import Flic  # noqa: E402

try:
    from PIL import Image
except ImportError:
    sys.exit("Falta Pillow: pip install pillow")

PAD = 2  # separación entre sprites en las hojas

# Archivos dañados en el CD original (edición española), por SHA-256: se informan pero no cuentan como fallo.
# En ambos el slot 26 trae 2 bytes de más en la fila 13 y desde ahí el resto del archivo queda desalineado;
# el juego (SPACE:0x431340) los lee igual de mal. Ver docs/formats/spc.md §Defectos.
KNOWN_DEFECTS = {
    "3d37d69c330eb6148f9c2ab3f0ea72c45b20c9f06b9dbeee34f01a63dfb3801c": "N031.SPC",
    "7466ea513216cccdf99ad66461440fd2d33b25c7ce1638e88136386e98af0821": "N032.SPC",
}


def sheet(images, max_w=2048, bg=(0, 0, 0, 0)):
    """Empaqueta imágenes en filas. Devuelve (hoja, [(x, y)])."""
    pos, x, y, row_h, width = [], 0, 0, 0, 1
    for im in images:
        if x and x + im.width > max_w:
            x, y, row_h = 0, y + row_h + PAD, 0
        pos.append((x, y))
        x += im.width + PAD
        row_h = max(row_h, im.height)
        width = max(width, x)
    out = Image.new("RGBA", (width, max(1, y + row_h)), bg)
    for im, p in zip(images, pos):
        out.paste(im, p)
    return out, pos


def export_sprites(path, out_dir, palette, frames=False):
    data = Path(path).read_bytes()
    kind = Path(path).suffix.upper()[1:]
    sfile = sf.read_spc(data) if kind == "SPC" else sf.read_spr(data)
    ok = [s for s in sfile.sprites if not s.error]
    images = [sf.sprite_rgba(Image, s, kind, palette) for s in ok]
    stem = Path(path).stem.lower()
    out_dir.mkdir(parents=True, exist_ok=True)
    index = {"file": Path(path).name, "format": kind, "slots": sfile.count, "error": sfile.error, "sprites": []}
    if images:
        im, pos = sheet(images)
        im.save(out_dir / f"{stem}.png")
        for s, (x, y) in zip(ok, pos):
            index["sprites"].append({"slot": s.slot, "w": s.width, "h": s.height, "x": x, "y": y})
    for s in sfile.sprites:
        if s.error:
            index["sprites"].append({"slot": s.slot, "w": s.width, "h": s.height, "error": s.error})
    if frames:
        fdir = out_dir / stem
        fdir.mkdir(exist_ok=True)
        for s, im in zip(ok, images):
            im.save(fdir / f"{s.slot:03d}.png")
    (out_dir / f"{stem}.json").write_text(json.dumps(index, ensure_ascii=False, indent=1) + "\n")
    errors = ([sfile.error] if sfile.error else []) + [f"slot {s.slot}: {s.error}" for s in sfile.sprites if s.error]
    return len(ok), errors


def export_map(path, out_dir, palette, game_dir):
    gmap = sf.read_map(Path(path).read_bytes(), Path(path).name)
    stem = Path(path).stem.lower()
    out_dir.mkdir(parents=True, exist_ok=True)
    cells = [{"x": i % gmap.width, "y": i // gmap.width, "tile": c.tile, "kind": c.kind,
              "raw": c.raw.hex(), **({"units": c.units} if c.units else {})}
             for i, c in enumerate(gmap.cells)]
    doc = {"file": gmap.name, "width": gmap.width, "height": gmap.height, "terrain_set": gmap.terrain_set,
           "cell_px": sf.CELL_PX, "cells": cells}
    (out_dir / f"{stem}.json").write_text(json.dumps(doc, ensure_ascii=False) + "\n")
    errors = []
    if gmap.terrain_set is not None and game_dir:
        try:
            tiles = sf.read_spr(sf.find_ci(game_dir, "SPR", f"SUELOS{gmap.terrain_set:02d}.SPR").read_bytes())
            have = {s.slot for s in tiles.sprites}
            missing = sorted({c.tile for c in gmap.cells} - have)
            if missing:
                errors.append(f"tiles inexistentes en SUELOS{gmap.terrain_set:02d}: {missing[:10]}")
            sf.render_map(Image, gmap, tiles, palette).save(out_dir / f"{stem}.png")
        except FileNotFoundError as e:
            errors.append(f"sin tiles para dibujar: {e}")
    return 1, errors


def export_flc(name, data, out_dir, gif=False):
    fl = Flic(data)
    frames = []
    for pix, pal in fl:
        im = Image.frombytes("P", (fl.width, fl.height), pix)
        im.putpalette(pal)
        frames.append(im)
    stem = Path(name).stem.lower()
    out_dir.mkdir(parents=True, exist_ok=True)
    if gif and frames:
        frames[0].save(out_dir / f"{stem}.gif", save_all=True, append_images=frames[1:],
                       duration=max(20, fl.delay_ms), loop=0, disposal=1)
    elif frames:
        sheet([f.convert("RGBA") for f in frames], max_w=max(2048, fl.width))[0].save(out_dir / f"{stem}.png")
    errors = [f"chunks desconocidos: {sorted(fl.unknown_chunks)}"] if fl.unknown_chunks else []
    if len(frames) != fl.frames:
        errors.append(f"{len(frames)} fotogramas de {fl.frames}")
    return len(frames), errors


def flc_sources(game_dir):
    """(nombre, bytes) de cada FLC: de ANI/ si existe, si no de ANI.ZIP."""
    try:
        ani = sf.find_ci(game_dir, "ANI")
        if ani.is_dir():
            for p in sorted(ani.iterdir()):
                if p.suffix.upper() == ".FLC":
                    yield p.name, p.read_bytes()
            return
    except FileNotFoundError:
        pass
    with zipfile.ZipFile(sf.find_ci(game_dir, "ANI.ZIP")) as z:
        for n in sorted(z.namelist()):
            if n.upper().endswith(".FLC"):
                yield Path(n).name, z.read(n)


def run_all(game_dir, out, palette, frames):
    report = {}

    def record(group, name, fn, path=None):
        try:
            n, errs = fn()
        except Exception as e:  # un archivo dañado no debe frenar el resto
            n, errs = 0, [f"{type(e).__name__}: {e}"]
        report.setdefault(group, {"files": 0, "items": 0, "errors": {}})
        g = report[group]
        g["files"] += 1
        g["items"] += n
        if errs and path and hashlib.sha256(Path(path).read_bytes()).hexdigest() in KNOWN_DEFECTS:
            g.setdefault("known_defects", {})[name] = errs
        elif errs:
            g["errors"][name] = errs

    for sub, ext in (("SPC", "SPC"), ("SPR", "SPR")):
        for p in sorted(sf.find_ci(game_dir, sub).iterdir()):
            if p.suffix.upper() == "." + ext:
                record(sub.lower(), p.name, lambda p=p, sub=sub: export_sprites(p, out / sub.lower(), palette, frames), p)
    for p in sorted(sf.find_ci(game_dir, "MAPAS").iterdir()):
        if p.suffix.upper() == ".MAP":
            record("map", p.name, lambda p=p: export_map(p, out / "map", palette, game_dir))
    for name, data in flc_sources(game_dir):
        record("flc", name, lambda name=name, data=data: export_flc(name, data, out / "flc"))
    for p in sorted(sf.find_ci(game_dir, "IMG").iterdir()):
        if p.suffix.upper() == ".PCX":
            def conv(p=p):
                (out / "pcx").mkdir(parents=True, exist_ok=True)
                Image.open(p).save(out / "pcx" / f"{p.stem.lower()}.png")
                return 1, []
            record("pcx", p.name, conv)
    (out / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=1) + "\n")
    bad = 0
    for group, g in report.items():
        print(f"{group:4} {g['files']:4} archivos, {g['items']:6} elementos, {len(g['errors'])} con errores")
        for name, errs in g["errors"].items():
            print(f"       {name}: {'; '.join(errs)[:160]}")
            bad += 1
        for name, errs in g.get("known_defects", {}).items():
            print(f"       {name}: defecto conocido del CD original ({errs[0][:100]})")
    return bad


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("command", choices=["spc", "spr", "map", "flc", "pcx", "all"])
    ap.add_argument("paths", nargs="+")
    ap.add_argument("--out", default="export", help="carpeta de salida (por defecto ./export)")
    ap.add_argument("--palette", help="PCX con la paleta (por defecto IMG/PALETA.PCX de la carpeta del juego)")
    ap.add_argument("--game-dir", help="carpeta del juego (para la paleta y los tiles de los mapas)")
    ap.add_argument("--frames", action="store_true", help="spc/spr: además, un PNG por sprite")
    ap.add_argument("--gif", action="store_true", help="flc: GIF animado en lugar de hoja PNG")
    a = ap.parse_args()
    out = Path(a.out)

    game_dir = a.game_dir or (a.paths[0] if a.command == "all" else None)
    if game_dir is None:  # deducirla: ARCHIVO está en <juego>/SPC, <juego>/MAPAS…
        game_dir = str(Path(a.paths[0]).resolve().parent.parent)
    pal_path = a.palette
    if not pal_path:
        try:
            pal_path = sf.find_ci(game_dir, "IMG", "PALETA.PCX")
        except FileNotFoundError:
            if a.command not in ("flc", "pcx"):
                sys.exit("No encuentro IMG/PALETA.PCX: indicá --palette o --game-dir")
    palette = sf.load_palette(pal_path) if pal_path else None

    if a.command == "all":
        sys.exit(1 if run_all(Path(a.paths[0]), out, palette, a.frames) else 0)
    failed = 0
    for p in a.paths:
        try:
            if a.command in ("spc", "spr"):
                n, errs = export_sprites(p, out, palette, a.frames)
            elif a.command == "map":
                n, errs = export_map(p, out, palette, game_dir)
            elif a.command == "flc":
                n, errs = export_flc(p, Path(p).read_bytes(), out, a.gif)
            else:
                out.mkdir(parents=True, exist_ok=True)
                Image.open(p).save(out / f"{Path(p).stem.lower()}.png")
                n, errs = 1, []
        except Exception as e:
            n, errs = 0, [f"{type(e).__name__}: {e}"]
        failed += bool(errs)
        print(f"{Path(p).name}: {n} elementos" + (f" — {'; '.join(errs)}" if errs else ""))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
