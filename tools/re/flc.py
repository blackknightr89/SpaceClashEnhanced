"""flc.py — decodificador de animaciones Autodesk FLIC (FLI 0xAF11 y FLC 0xAF12), sin dependencias.

Soporta los chunks COLOR_256 (4), DELTA_FLC (7), COLOR_64 (11), DELTA_FLI (12), BLACK (13), BYTE_RUN (15),
FLI_COPY (16) y PSTAMP (18, se ignora); salta los chunks de prefijo (0xF100) y los desconocidos.
Referencia del formato: documentación de Autodesk Animator Pro (FLIC file format).
"""
import struct


class FlicError(ValueError):
    pass


class Flic:
    def __init__(self, data):
        if len(data) < 128:
            raise FlicError("archivo demasiado corto")
        (self.size, self.magic, self.frames, self.width, self.height,
         self.depth, self.flags, speed) = struct.unpack_from("<IHHHHHHI", data, 0)
        if self.magic not in (0xAF11, 0xAF12):
            raise FlicError(f"firma 0x{self.magic:04X} no es FLI/FLC")
        # FLI: velocidad en 1/70 s; FLC: en milisegundos
        self.delay_ms = speed * 1000 // 70 if self.magic == 0xAF11 else speed
        self.oframe1 = struct.unpack_from("<I", data, 80)[0] if self.magic == 0xAF12 else 0
        self.data = data
        self.unknown_chunks = set()

    def __iter__(self):
        """Genera (índices bytes w×h, paleta list[768]) para cada fotograma (sin el de bucle final)."""
        w, h = self.width, self.height
        pix = bytearray(w * h)
        pal = [0] * 768
        d = self.data
        p = self.oframe1 or 128
        shown = 0
        while p + 6 <= len(d) and shown < self.frames:
            csize, ctype = struct.unpack_from("<IH", d, p)
            if csize < 6 or p + csize > len(d):
                raise FlicError(f"chunk de tamaño {csize} inválido en 0x{p:x}")
            if ctype == 0xF1FA:
                nsub = struct.unpack_from("<H", d, p + 6)[0]
                q = p + 16
                for _ in range(nsub):
                    ssize, stype = struct.unpack_from("<IH", d, q)
                    if ssize < 6:
                        raise FlicError(f"subchunk de tamaño {ssize} en 0x{q:x}")
                    self._chunk(stype, d, q + 6, q + ssize, pix, pal)
                    q += ssize
                shown += 1
                yield bytes(pix), list(pal)
            p += csize

    def _chunk(self, t, d, s, e, pix, pal):
        w, h = self.width, self.height
        if t in (4, 11):                      # COLOR_256 / COLOR_64
            shift = 0 if t == 4 else 2
            npk = struct.unpack_from("<H", d, s)[0]
            i, idx = s + 2, 0
            for _ in range(npk):
                idx += d[i]
                n = d[i + 1] or 256
                i += 2
                for _ in range(n):
                    if idx < 256:
                        pal[idx * 3:idx * 3 + 3] = [min(255, c << shift | (c >> 4 if shift else 0))
                                                   for c in d[i:i + 3]]
                    idx += 1
                    i += 3
        elif t == 13:                         # BLACK
            pix[:] = bytes(w * h)
        elif t == 16:                         # FLI_COPY
            pix[:] = d[s:s + w * h]
        elif t == 15:                         # BYTE_RUN
            i = s
            for y in range(h):
                i += 1                        # contador de paquetes obsoleto: se ignora
                x = 0
                row = y * w
                while x < w:
                    c = struct.unpack_from("b", d, i)[0]
                    i += 1
                    if c < 0:
                        n = -c
                        pix[row + x:row + x + n] = d[i:i + n]
                        i += n
                    else:
                        pix[row + x:row + x + c] = bytes([d[i]]) * c
                        i += 1
                        n = c
                    x += n
        elif t == 12:                         # DELTA_FLI (líneas de 8 bits)
            y, nlines = struct.unpack_from("<HH", d, s)
            i = s + 4
            for _ in range(nlines):
                npk = d[i]
                i += 1
                x = 0
                for _ in range(npk):
                    x += d[i]
                    c = struct.unpack_from("b", d, i + 1)[0]
                    i += 2
                    o = y * w + x
                    if c > 0:
                        pix[o:o + c] = d[i:i + c]
                        i += c
                        x += c
                    else:
                        pix[o:o - c] = bytes([d[i]]) * -c
                        i += 1
                        x -= c
                y += 1
        elif t == 7:                          # DELTA_FLC (palabras de 16 bits)
            nlines = struct.unpack_from("<H", d, s)[0]
            i = s + 2
            y = 0
            for _ in range(nlines):
                while True:
                    op = struct.unpack_from("<H", d, i)[0]
                    i += 2
                    kind = op >> 14
                    if kind == 0:             # número de paquetes
                        npk = op
                        break
                    if kind == 3:             # saltar líneas
                        y += 0x10000 - op
                    elif kind == 2:           # último byte de la línea (ancho impar)
                        pix[y * w + w - 1] = op & 0xFF
                x = 0
                for _ in range(npk):
                    x += d[i]
                    c = struct.unpack_from("b", d, i + 1)[0]
                    i += 2
                    o = y * w + x
                    if c > 0:
                        n = c * 2
                        pix[o:o + n] = d[i:i + n]
                        i += n
                        x += n
                    else:
                        n = -c
                        pix[o:o + 2 * n] = d[i:i + 2] * n
                        i += 2
                        x += 2 * n
                y += 1
        elif t == 18:                         # PSTAMP (miniatura): sin uso
            pass
        else:
            self.unknown_chunks.add(t)
