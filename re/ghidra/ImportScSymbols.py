# -*- coding: utf-8 -*-
# Importa re/symbols.csv en el programa abierto en Ghidra (CLASH.EXE o SPACE.EXE).
# Nombra funciones y datos, aplica la firma como comentario de cabecera y añade la evidencia como
# comentario. Es idempotente: volver a ejecutarlo actualiza los nombres.
#
# Uso: Script Manager → carpeta re/ghidra de este repositorio → ImportScSymbols.py
#      (o headless: analyzeHeadless PROY sc -process CLASH.EXE -scriptPath re/ghidra -postScript ImportScSymbols.py)
# @category SpaceClash
# @runtime Jython
import csv
import os

from ghidra.program.model.symbol import SourceType
from ghidra.program.model.listing import CodeUnit

exe = currentProgram.getName().upper().replace(".EXE", "")
here = os.path.dirname(os.path.abspath(getSourceFile().getAbsolutePath()))
path = os.path.join(here, "..", "symbols.csv")

fm = currentProgram.getFunctionManager()
listing = currentProgram.getListing()
n = 0
with open(path) as f:
    for row in csv.DictReader(f):
        if row["exe"] != exe:
            continue
        addr = toAddr(int(row["va"], 16))
        name = row["name"]
        if row["kind"] == "func":
            fn = fm.getFunctionAt(addr) or createFunction(addr, name)
            if fn is None:
                print("No se pudo crear la función en %s" % row["va"])
                continue
            fn.setName(name, SourceType.USER_DEFINED)
            if row["signature"]:
                fn.setComment(row["signature"])
        else:
            createLabel(addr, name, True, SourceType.USER_DEFINED)
        note = "; ".join(x for x in (row["status"], row["evidence"], row["notes"]) if x)
        if note:
            listing.setComment(addr, CodeUnit.PLATE_COMMENT, note)
        n += 1
print("%d símbolos de %s importados desde %s" % (n, exe, path))
