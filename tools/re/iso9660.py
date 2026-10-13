#!/usr/bin/env python3
"""iso9660.py — lista y extrae archivos de la imagen del CD (BIN MODE1/2352 o ISO de 2048 B/sector).

Uso:
    python3 tools/re/iso9660.py disk/                      # lista (busca el .bin/.iso en la carpeta)
    python3 tools/re/iso9660.py IMAGEN.bin --extract DEST  # extrae todo
    python3 tools/re/iso9660.py IMAGEN.bin --extract DEST --only CLASH.EXE --only 'SCLASH/SPC/*'

Solo lee: no modifica la imagen. Los nombres se devuelven sin el sufijo ";1".
"""
import argparse
import fnmatch
import struct
import sys
from pathlib import Path

SYNC = b"\x00" + b"\xff" * 10 + b"\x00"


class Image:
    def __init__(self, path):
        self.f = open(path, "rb")
        head = self.f.read(16)
        # BIN crudo: cada sector empieza con el patrón de sincronismo y lleva 16 B de cabecera
        if head[:12] == SYNC:
            self.sector, self.offset = 2352, 16
        else:
            self.sector, self.offset = 2048, 0
        pvd = self.read(16, 2048)
        if pvd[1:6] != b"CD001" or pvd[0] != 1:
            raise ValueError(f"{path}: no es ISO 9660 (sin descriptor primario en el sector 16)")
        self.root = pvd[156:156 + 34]

    def read(self, lba, size):
        out = bytearray()
        while len(out) < size:
            self.f.seek(lba * self.sector + self.offset)
            out += self.f.read(min(2048, size - len(out)))
            lba += 1
        return bytes(out)

    def _records(self, lba, size):
        data = self.read(lba, size)
        pos = 0
        while pos < len(data):
            n = data[pos]
            if n == 0:  # relleno hasta el siguiente sector
                pos = (pos // 2048 + 1) * 2048
                continue
            yield data[pos:pos + n]
            pos += n

    def walk(self, rec=None, prefix=""):
        """Genera (ruta, lba, tamaño, es_dir) recorriendo el árbol."""
        rec = rec or self.root
        lba, size = struct.unpack_from("<I", rec, 2)[0], struct.unpack_from("<I", rec, 10)[0]
        for r in self._records(lba, size):
            nlen = r[32]
            name = r[33:33 + nlen]
            if name in (b"\x00", b"\x01"):
                continue
            name = name.decode("latin-1").split(";")[0].rstrip(".")
            path = f"{prefix}{name}"
            is_dir = bool(r[25] & 2)
            yield path, struct.unpack_from("<I", r, 2)[0], struct.unpack_from("<I", r, 10)[0], is_dir
            if is_dir:
                yield from self.walk(r, path + "/")

    def files(self):
        return [(p, l, s) for p, l, s, d in self.walk() if not d]


def find_image(arg):
    p = Path(arg)
    if p.is_dir():
        cands = sorted(list(p.glob("*.bin")) + list(p.glob("*.iso")) + list(p.glob("*.BIN")) + list(p.glob("*.ISO")))
        if not cands:
            sys.exit(f"No hay .bin ni .iso en {p}")
        return cands[0]
    return p


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("image", help="imagen .bin/.iso o carpeta que la contiene")
    ap.add_argument("--extract", metavar="DEST", help="carpeta destino")
    ap.add_argument("--only", action="append", default=[], help="patrón glob (insensible a mayúsculas); repetible")
    a = ap.parse_args()

    img = Image(find_image(a.image))
    files = img.files()
    if a.only:
        pats = [x.upper() for x in a.only]
        files = [f for f in files if any(fnmatch.fnmatch(f[0].upper(), x) for x in pats)]
    if not a.extract:
        for path, _, size in files:
            print(f"{size:>12}  {path}")
        print(f"{len(files)} archivos, {sum(s for _, _, s in files)} bytes", file=sys.stderr)
        return
    dest = Path(a.extract)
    for path, lba, size in files:
        out = dest / path
        out.parent.mkdir(parents=True, exist_ok=True)
        with open(out, "wb") as f:
            done = 0
            while done < size:  # por bloques: algunos archivos ocupan cientos de MB
                chunk = min(1 << 20, size - done)
                f.write(img.read(lba + done // 2048, chunk))
                done += chunk
    print(f"{len(files)} archivos extraídos en {dest}", file=sys.stderr)


if __name__ == "__main__":
    main()
