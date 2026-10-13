/* Escritura de código con verificación de bytes y enganche de imports (IAT) del EXE. */
#include "scenh.h"
#include <string.h>

static int write_mem(uintptr_t addr, const void *src, size_t n)
{
    DWORD old;
    if (!VirtualProtect((void *)addr, n, PAGE_EXECUTE_READWRITE, &old))
        return 0;
    memcpy((void *)addr, src, n);
    VirtualProtect((void *)addr, n, old, &old);
    FlushInstructionCache(GetCurrentProcess(), (void *)addr, n);
    return 1;
}

/* Reemplaza n bytes en addr si coinciden con `expected` (o si ya valen `repl`). */
int patch_bytes(uintptr_t addr, const void *expected, const void *repl, size_t n, const char *what)
{
    if (memcmp((void *)addr, repl, n) == 0)
        return 1;
    if (memcmp((void *)addr, expected, n) != 0) {
        log_printf("RECHAZADO %s: bytes inesperados en 0x%08lx", what, (unsigned long)addr);
        return 0;
    }
    if (!write_mem(addr, repl, n)) {
        log_printf("ERROR %s: VirtualProtect en 0x%08lx", what, (unsigned long)addr);
        return 0;
    }
    log_printf("ok %s (0x%08lx, %u B)", what, (unsigned long)addr, (unsigned)n);
    return 1;
}

/* Sustituye una función entera: escribe "jmp target" al principio (los `n` bytes esperados >= 5). */
int patch_jmp(uintptr_t addr, const void *expected, size_t n, void *target, const char *what)
{
    uint8_t jmp[16];
    int32_t rel = (int32_t)((uintptr_t)target - (addr + 5));
    if (n < 5 || n > sizeof jmp)
        return 0;
    memset(jmp, 0x90, n);
    jmp[0] = 0xE9;
    memcpy(jmp + 1, &rel, 4);
    return patch_bytes(addr, expected, jmp, n, what);
}

/* Cambia la entrada de la IAT del EXE para dll!func. Devuelve la función original o NULL. */
void *hook_import(const char *dll, const char *func, void *replacement)
{
    uint8_t *base = (uint8_t *)GetModuleHandleA(NULL);
    IMAGE_NT_HEADERS *nt = (IMAGE_NT_HEADERS *)(base + ((IMAGE_DOS_HEADER *)base)->e_lfanew);
    IMAGE_DATA_DIRECTORY dir = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT];
    IMAGE_IMPORT_DESCRIPTOR *imp = (IMAGE_IMPORT_DESCRIPTOR *)(base + dir.VirtualAddress);
    for (; imp->Name; imp++) {
        if (lstrcmpiA((char *)(base + imp->Name), dll) != 0)
            continue;
        IMAGE_THUNK_DATA *names = (IMAGE_THUNK_DATA *)(base + (imp->OriginalFirstThunk ? imp->OriginalFirstThunk
                                                                                       : imp->FirstThunk));
        IMAGE_THUNK_DATA *iat = (IMAGE_THUNK_DATA *)(base + imp->FirstThunk);
        for (; names->u1.AddressOfData; names++, iat++) {
            if (IMAGE_SNAP_BY_ORDINAL(names->u1.Ordinal))
                continue;
            IMAGE_IMPORT_BY_NAME *ibn = (IMAGE_IMPORT_BY_NAME *)(base + names->u1.AddressOfData);
            if (strcmp((char *)ibn->Name, func) != 0)
                continue;
            void *orig = (void *)iat->u1.Function;
            void *real = (void *)GetProcAddress(GetModuleHandleA(dll), func);
            if (orig != real) {  /* IAT todavía sin resolver o ya enganchada por otro */
                log_printf("RECHAZADO import %s!%s: la IAT no apunta a la función real", dll, func);
                return NULL;
            }
            if (!write_mem((uintptr_t)&iat->u1.Function, &replacement, sizeof replacement))
                return NULL;
            log_printf("ok import %s!%s", dll, func);
            return orig;
        }
    }
    log_printf("RECHAZADO import %s!%s: no está en el EXE", dll, func);
    return NULL;
}
