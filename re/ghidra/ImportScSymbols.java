// Importa re/symbols.csv en el programa abierto (CLASH.EXE o SPACE.EXE): nombra funciones y datos,
// pone la firma como comentario de la función y el estado/evidencia como comentario de cabecera.
// Es idempotente: volver a ejecutarlo actualiza los nombres.
//
// Uso: Script Manager → añadir la carpeta re/ghidra de este repositorio → ImportScSymbols.java
//      Headless: ver tools/re/ghidra.sh
//@category SpaceClash
import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.ArrayList;
import java.util.List;

import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.address.AddressSet;
import ghidra.program.model.symbol.Namespace;
import ghidra.program.model.listing.CodeUnit;
import ghidra.program.model.listing.Function;
import ghidra.program.model.symbol.SourceType;

public class ImportScSymbols extends GhidraScript {

    /** Divide una línea CSV respetando comillas dobles ("" = comilla literal). */
    static List<String> splitCsv(String line) {
        List<String> out = new ArrayList<>();
        StringBuilder cur = new StringBuilder();
        boolean quoted = false;
        for (int i = 0; i < line.length(); i++) {
            char c = line.charAt(i);
            if (quoted) {
                if (c == '"' && i + 1 < line.length() && line.charAt(i + 1) == '"') {
                    cur.append('"');
                    i++;
                }
                else if (c == '"') {
                    quoted = false;
                }
                else {
                    cur.append(c);
                }
            }
            else if (c == '"') {
                quoted = true;
            }
            else if (c == ',') {
                out.add(cur.toString());
                cur.setLength(0);
            }
            else {
                cur.append(c);
            }
        }
        out.add(cur.toString());
        return out;
    }

    @Override
    protected void run() throws Exception {
        String exe = currentProgram.getName().toUpperCase().replace(".EXE", "");
        File csv = new File(getSourceFile().getParentFile().getParentFile().getAbsolutePath(),
            "symbols.csv");
        List<String> lines = Files.readAllLines(csv.toPath(), StandardCharsets.UTF_8);
        List<String> header = splitCsv(lines.get(0));
        int n = 0;
        for (String line : lines.subList(1, lines.size())) {
            if (line.isBlank()) {
                continue;
            }
            List<String> f = splitCsv(line);
            java.util.function.Function<String, String> col = k -> {
                int i = header.indexOf(k);
                return i < f.size() ? f.get(i) : "";
            };
            if (!col.apply("exe").equals(exe)) {
                continue;
            }
            Address addr = toAddr(Long.decode(col.apply("va")));
            String name = col.apply("name");
            if (col.apply("kind").equals("range")) {
                // Todas las funciones de [va, end) pasan al namespace `name` (p. ej. CRT)
                Address end = toAddr(Long.decode(col.apply("signature").replace("end=", "")));
                Namespace ns = currentProgram.getSymbolTable().getOrCreateNameSpace(
                    currentProgram.getGlobalNamespace(), name, SourceType.USER_DEFINED);
                int moved = 0;
                for (Function fn : currentProgram.getFunctionManager().getFunctions(
                    new AddressSet(addr, end.subtract(1)), true)) {
                    fn.setParentNamespace(ns);
                    moved++;
                }
                println(moved + " funciones en " + name + " (" + addr + "–" + end + ")");
                continue;
            }
            if (col.apply("kind").equals("func")) {
                Function fn = getFunctionAt(addr);
                if (fn == null) {
                    disassemble(addr);
                    fn = createFunction(addr, name);
                }
                if (fn == null) {
                    printerr("No se pudo crear la función en " + col.apply("va"));
                    continue;
                }
                fn.setName(name, SourceType.USER_DEFINED);
                if (!col.apply("signature").isEmpty()) {
                    fn.setComment(col.apply("signature"));
                }
            }
            else {
                createLabel(addr, name, true, SourceType.USER_DEFINED);
            }
            String note = String.join("; ", List.of(col.apply("status"), col.apply("evidence"),
                col.apply("notes")).stream().filter(s -> !s.isEmpty()).toList());
            if (!note.isEmpty()) {
                currentProgram.getListing().setComment(addr, CodeUnit.PLATE_COMMENT, note);
            }
            n++;
        }
        println(n + " símbolos de " + exe + " importados desde " + csv);
    }
}
