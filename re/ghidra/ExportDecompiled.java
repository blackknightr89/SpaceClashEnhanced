// Exporta el pseudo-C de todas las funciones (o de las direcciones indicadas) a un archivo .c, con la
// dirección y el nombre de cada función como cabecera. Sirve para buscar con grep fuera de Ghidra.
// Argumentos (headless): ARCHIVO_SALIDA [va1 va2 …]
// El resultado deriva del EXE original: no se sube al repositorio (PLAN §13).
//@category SpaceClash
import java.io.File;
import java.io.PrintWriter;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;

import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileOptions;
import ghidra.app.decompiler.DecompileResults;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.listing.Function;

public class ExportDecompiled extends GhidraScript {
    @Override
    protected void run() throws Exception {
        String[] args = getScriptArgs();
        File out = args.length > 0 ? new File(args[0])
                : askFile("Archivo de salida", "Exportar");
        List<Function> fns = new ArrayList<>();
        if (args.length > 1) {
            for (int i = 1; i < args.length; i++) {
                Function f = getFunctionContaining(toAddr(Long.decode(args[i])));
                if (f != null) {
                    fns.add(f);
                }
            }
        }
        else {
            currentProgram.getFunctionManager().getFunctions(true).forEach(fns::add);
        }
        DecompInterface di = new DecompInterface();
        di.setOptions(new DecompileOptions());
        di.openProgram(currentProgram);
        out.getParentFile().mkdirs();
        int ok = 0;
        try (PrintWriter w = new PrintWriter(out, StandardCharsets.UTF_8)) {
            for (Function f : fns) {
                if (monitor.isCancelled()) {
                    break;
                }
                DecompileResults r = di.decompileFunction(f, 60, monitor);
                w.printf("// ==== %s %s%n", f.getEntryPoint(), f.getName());
                if (r.decompileCompleted()) {
                    w.println(r.getDecompiledFunction().getC());
                    ok++;
                }
                else {
                    w.println("// error: " + r.getErrorMessage());
                }
            }
        }
        di.dispose();
        println(ok + "/" + fns.size() + " funciones exportadas a " + out);
    }
}
