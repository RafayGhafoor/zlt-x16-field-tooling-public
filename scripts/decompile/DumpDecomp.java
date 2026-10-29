// Dump decompiled C for every function in the current program, plus the string
// literals the ARM PIC code reaches through its literal pools.
//
// Invoked by decompile.sh, not by hand:
//   analyzeHeadless <proj> <name> -import <binary> -postScript DumpDecomp.java
//
// Environment:
//   DECOMP_OUT    output file (default /tmp/decomp.txt)
//   EXTRA_FUNCS   comma-separated hex entry points to force-create, for functions
//                 the auto-analyser refuses to make (ARM PIC tail literal pools
//                 look like data, so the tail of a function can be left undefined)
//
// @category ZLT
import java.io.PrintWriter;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;

import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionIterator;
import ghidra.util.task.ConsoleTaskMonitor;

public class DumpDecomp extends GhidraScript {
    @Override
    public void run() throws Exception {
        String out = System.getenv("DECOMP_OUT");
        if (out == null) {
            out = "/tmp/decomp.txt";
        }

        String extra = System.getenv("EXTRA_FUNCS");
        if (extra != null) {
            for (String s : extra.split(",")) {
                s = s.trim();
                if (s.isEmpty()) {
                    continue;
                }
                Address addr = currentProgram.getAddressFactory().getDefaultAddressSpace()
                        .getAddress(Long.parseLong(s, 16));
                if (currentProgram.getFunctionManager().getFunctionAt(addr) == null) {
                    try {
                        createFunction(addr, "FUN_extra_" + s);
                        println("created function at " + s);
                    } catch (Exception e) {
                        println("could not create function at " + s + ": " + e);
                    }
                }
            }
        }

        DecompInterface ifc = new DecompInterface();
        ifc.openProgram(currentProgram);
        ConsoleTaskMonitor mon = new ConsoleTaskMonitor();

        List<Function> fns = new ArrayList<>();
        FunctionIterator it = currentProgram.getFunctionManager().getFunctions(true);
        while (it.hasNext()) {
            fns.add(it.next());
        }
        fns.sort(Comparator.comparingLong(f -> f.getEntryPoint().getOffset()));

        try (PrintWriter w = new PrintWriter(out)) {
            w.println("// program: " + currentProgram.getName());
            w.println("// image base: " + currentProgram.getImageBase());
            w.println("// functions: " + fns.size());
            for (Function f : fns) {
                w.println();
                w.println("/* ===== " + f.getName() + " @ " + f.getEntryPoint() + " (size "
                        + f.getBody().getNumAddresses() + ") ===== */");
                DecompileResults res = ifc.decompileFunction(f, 90, mon);
                if (res != null && res.decompileCompleted()) {
                    w.println(res.getDecompiledFunction().getC());
                } else {
                    w.println("/* DECOMPILE FAILED: "
                            + (res == null ? "null" : res.getErrorMessage()) + " */");
                }
            }
        }
        println("wrote " + out);
    }
}
