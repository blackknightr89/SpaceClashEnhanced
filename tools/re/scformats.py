"""scformats.py — lectores de los formatos propios de Space Clash (SPC, SPR, MAP) y utilidades comunes.

Todo lo de aquí está descrito, con su evidencia (direcciones en los EXE), en docs/formats/*.md.
Solo depende de la biblioteca estándar; las funciones que generan imágenes reciben Pillow como argumento
opcional para que el módulo se pueda importar sin él.
"""
import struct
from dataclasses import dataclass, field
from pathlib import Path

HEADER_SIZE = 64          # SPC y SPR: fread(hdr, 1, 0x40) en CLASH:0x447760 / CLASH:0x402320
PALETTE_SIZE = 768        # fread(pal, 3, 0x100) al final de SPC y SPR
CELL_PX = 40              # lado de una celda del mapa en píxeles (tiles de 40×40; los de 80×80 ocupan 2×2)
MAP_CELL_SIZE = 32        # bytes por celda en *.MAP (CLASH:0x418950)


class FormatError(ValueError):
    pass


# --------------------------------------------------------------------------- utilidades

def find_ci(base, *parts):
    """Resuelve una ruta sin distinguir mayúsculas (el CD y los EXE mezclan `.\\ani` y `.\\Ani`)."""
    p = Path(base)
    for part in parts:
        if (p / part).exists():
            p = p / part
            continue
        low = part.lower()
        match = [c for c in p.iterdir() if c.name.lower() == low] if p.is_dir() else []
        if not match:
            raise FileNotFoundError(str(Path(base, *parts)))
        p = match[0]
    return p


def load_palette(path):
    """Paleta de 256 colores (lista plana RGB de 768 enteros) desde un PCX 8 bpp: los últimos 769 bytes
    son 0x0C + 256×RGB (formato PCX estándar). El juego usa IMG/PALETA.PCX."""
    data = Path(path).read_bytes()
    if len(data) < 769 or data[-769] != 0x0C:
        raise FormatError(f"{path}: el PCX no trae paleta de 256 colores al final")
    return list(data[-768:])


# --------------------------------------------------------------------------- SPC

@dataclass
class Sprite:
    slot: int
    width: int
    height: int
    data: bytes                 # flujo RLE tal como está en el archivo (SPC) o píxeles crudos (SPR)
    error: str = ""             # si el RLE no se pudo decodificar (archivo dañado)


@dataclass
class SpriteFile:
    kind: str                   # "SPC" o "SPR"
    count: int
    sprites: list = field(default_factory=list)
    palette: bytes = b""        # 768 B leídos por el juego; ver docs/formats/spc.md §Paleta
    error: str = ""             # error estructural (lectura cortada)


def _read_slots(data, kind, read_entry):
    if data[:6] != b"EFS" + kind.encode():
        raise FormatError(f"falta la firma EFS{kind}")
    count = struct.unpack_from("<H", data, 6)[0]
    out = SpriteFile(kind, count)
    p = HEADER_SIZE
    for slot in range(count):
        if p >= len(data):
            out.error = f"fin de archivo en el slot {slot}"
            return out
        present = data[p]
        p += 1
        if not present:
            continue
        if present != 1:  # el juego trata cualquier valor ≠ 0 como "presente": aquí ya está desalineado
            out.error = f"byte de presencia 0x{present:02x} en el slot {slot} (offset 0x{p - 1:x})"
            return out
        sprite, p = read_entry(data, p, slot)
        out.sprites.append(sprite)
    out.palette = data[p:p + PALETTE_SIZE]
    if len(data) - p != PALETTE_SIZE:
        out.error = f"quedan {len(data) - p} bytes tras los sprites (se esperaban {PALETTE_SIZE})"
    return out


def read_spc(data):
    """SPC: slot = u8 presente, u32 ancho, u32 alto, u32 tamaño, RLE[tamaño]."""
    def entry(d, p, slot):
        w, h, size = struct.unpack_from("<III", d, p)
        p += 12
        sp = Sprite(slot, w, h, d[p:p + size])
        try:
            decode_rle(sp.data, w, h)
        except FormatError as e:
            sp.error = str(e)
        return sp, p + size
    return _read_slots(data, "SPC", entry)


def read_spr(data):
    """SPR: slot = u8 presente, u16 ancho, u16 alto, u32 tamaño (= ancho×alto), píxeles sin comprimir."""
    def entry(d, p, slot):
        w, h, size = struct.unpack_from("<HHI", d, p)
        p += 8
        sp = Sprite(slot, w, h, d[p:p + size])
        if size != w * h:
            sp.error = f"tamaño {size} ≠ {w}×{h}"
        return sp, p + size
    return _read_slots(data, "SPR", entry)


def decode_rle(rle, w, h):
    """Decodifica el RLE por filas de los SPC. Devuelve (índices, máscara) de w×h bytes; máscara 1 = opaco.

    Códigos: 00 n → saltar n píxeles (transparentes); 01 n b₁…bₙ → n píxeles literales;
    00 FF con la fila ya completa → fin de fila. (Con la fila incompleta, 00 FF es un salto de 255:
    así se codifican las filas de más de 255 píxeles, p. ej. EXPL3.SPC.)
    """
    pix = bytearray(w * h)
    mask = bytearray(w * h)
    i = x = y = 0
    n = len(rle)
    while i < n:
        op = rle[i]
        if i + 1 >= n:
            raise FormatError(f"RLE cortado en el byte {i}")
        k = rle[i + 1]
        if op == 0:
            i += 2
            if k == 0xFF and x == w:
                y += 1
                x = 0
                continue
            x += k
        elif op == 1:
            if y >= h or x + k > w or i + 2 + k > n:
                raise FormatError(f"literal fuera de rango en la fila {y} (x={x}, n={k})")
            o = y * w + x
            pix[o:o + k] = rle[i + 2:i + 2 + k]
            mask[o:o + k] = b"\x01" * k
            i += 2 + k
            x += k
        else:
            raise FormatError(f"código RLE 0x{op:02x} desconocido en el byte {i} (fila {y}, x={x})")
        if x > w:
            raise FormatError(f"la fila {y} se pasa del ancho ({x} > {w})")
    if y != h or x != 0:
        raise FormatError(f"{y} filas decodificadas de {h}")
    return bytes(pix), bytes(mask)


# --------------------------------------------------------------------------- MAP

@dataclass
class Cell:
    raw: bytes

    @property
    def tile(self):             # u16 @0 → slot de SUELOS<tt>.SPR
        return self.raw[0] | self.raw[1] << 8

    @property
    def kind(self):             # u8 @2: 1, 2 o 3 (tipo de terreno; ver docs/formats/map.md)
        return self.raw[2]

    @property
    def units(self):
        """Ocupantes iniciales: lista de (campo, tipo, jugador[, extra]) con tipo ≠ 0xFF."""
        r = self.raw
        out = []
        if r[21] != 0xFF:
            out.append(("unidad", r[21], r[22]))
        if r[23] != 0xFF:
            out.append(("unidad2", r[23], r[24]))
        if r[25] != 0xFF:
            out.append(("objeto", r[25], r[26], r[27]))
        return out


@dataclass
class GameMap:
    name: str
    width: int
    height: int
    cells: list                  # fila a fila: cells[y * width + x]

    @property
    def terrain_set(self):
        """Sufijo T<nn> del nombre (01M00T02.MAP → 2) = SUELOS<nn>.SPR."""
        stem = Path(self.name).stem.upper()
        i = stem.rfind("T")
        return int(stem[i + 1:i + 3]) if i >= 0 and stem[i + 1:i + 3].isdigit() else None

    def cell(self, x, y):
        return self.cells[y * self.width + x]


def read_map(data, name=""):
    """MAP: u8 ancho, u8 alto, ancho×alto celdas de 32 B, fila a fila (CLASH:0x418950)."""
    if len(data) < 2:
        raise FormatError("archivo vacío")
    w, h = data[0], data[1]
    if len(data) != 2 + w * h * MAP_CELL_SIZE:
        raise FormatError(f"tamaño {len(data)} ≠ 2 + {w}×{h}×{MAP_CELL_SIZE}")
    cells = [Cell(data[2 + i * MAP_CELL_SIZE:2 + (i + 1) * MAP_CELL_SIZE]) for i in range(w * h)]
    return GameMap(name, w, h, cells)


# --------------------------------------------------------------------------- imágenes (Pillow)

def sprite_image(Image, sp, kind, palette, transparent=0):
    """Imagen "P" de un sprite. En los SPC los píxeles saltados quedan con el índice `transparent`."""
    if kind == "SPR":
        im = Image.frombytes("P", (sp.width, sp.height), sp.data)
        im.putpalette(palette)
        return im, None
    pix, mask = decode_rle(sp.data, sp.width, sp.height)
    if transparent:
        pix = bytes(p if m else transparent for p, m in zip(pix, mask))
    im = Image.frombytes("P", (sp.width, sp.height), pix)
    im.putpalette(palette)
    return im, Image.frombytes("L", (sp.width, sp.height), bytes(255 if m else 0 for m in mask))


def sprite_rgba(Image, sp, kind, palette):
    im, alpha = sprite_image(Image, sp, kind, palette)
    im = im.convert("RGBA")
    if alpha is not None:
        im.putalpha(alpha)
    return im


def render_map(Image, gmap, tiles, palette):
    """Dibuja el terreno: primero los tiles de 40×40 y después los de 80×80 (que cubren 2×2 celdas).
    Ese orden reproduce las costas y montañas sin cortes; ver docs/formats/map.md §Render."""
    by_slot = {s.slot: s for s in tiles.sprites}
    im = Image.new("P", (gmap.width * CELL_PX, gmap.height * CELL_PX), 0)
    im.putpalette(palette)
    for big in (False, True):
        for y in range(gmap.height):
            for x in range(gmap.width):
                sp = by_slot.get(gmap.cell(x, y).tile)
                if sp is None or (sp.width > CELL_PX) != big:
                    continue
                im.paste(Image.frombytes("P", (sp.width, sp.height), sp.data), (x * CELL_PX, y * CELL_PX))
    return im
