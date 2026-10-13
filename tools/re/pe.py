"""pe.py — lectura mínima de ejecutables PE de 32 bits (secciones, conversión offset↔VA)."""
import struct
from dataclasses import dataclass


@dataclass
class Section:
    name: str
    va: int          # dirección virtual absoluta (ImageBase + RVA)
    vsize: int
    raw: int         # offset en el archivo
    rawsize: int


class PE:
    def __init__(self, data):
        self.data = data
        if data[:2] != b"MZ":
            raise ValueError("no es un ejecutable MZ/PE")
        pe = struct.unpack_from("<I", data, 0x3C)[0]
        if data[pe:pe + 4] != b"PE\0\0":
            raise ValueError("falta la firma PE")
        nsec = struct.unpack_from("<H", data, pe + 6)[0]
        optsize = struct.unpack_from("<H", data, pe + 20)[0]
        self.image_base = struct.unpack_from("<I", data, pe + 24 + 28)[0]
        so = pe + 24 + optsize
        self.sections = []
        for i in range(nsec):
            name, vsize, rva, rawsize, raw = struct.unpack_from("<8sIIII", data, so + 40 * i)
            self.sections.append(Section(name.rstrip(b"\0").decode("latin-1"), self.image_base + rva,
                                         vsize, raw, rawsize))

    def section(self, name):
        return next(s for s in self.sections if s.name == name)

    def va_to_off(self, va):
        for s in self.sections:
            if s.va <= va < s.va + min(s.vsize, s.rawsize):
                return s.raw + va - s.va
        return None

    def off_to_va(self, off):
        for s in self.sections:
            if s.raw <= off < s.raw + s.rawsize:
                return s.va + off - s.raw
        return None

    def section_of_va(self, va):
        for s in self.sections:
            if s.va <= va < s.va + max(s.vsize, s.rawsize):
                return s.name
        return None
