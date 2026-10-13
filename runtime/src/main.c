/* Punto de entrada: identifica el EXE, lee scenh.ini y activa las mejoras. */
#include "scenh.h"
#include <stdarg.h>
#include <stdio.h>
#include <string.h>

static const GameInfo GAMES[] = {
    {EXE_CLASH, "CLASH.EXE", 0x37E207FF, 0x501000,
     0x42BEDB, 0x482A38, 0x728864, 0x875C44, 0x414C90, 0x483BA8, 0x483BA0, 0x481E14},
    {EXE_SPACE, "SPACE.EXE", 0x37E20574, 0x58F000,
     0x41CBE2, 0x467958, 0x69A1E4, 0, 0x40D670, 0x468438, 0x468430, 0x4676D4},
};

const GameInfo *g_game;
char g_dir[MAX_PATH];
static char g_ini[MAX_PATH], g_log[MAX_PATH];
static int g_log_on = 1;
static WNDPROC g_game_wndproc;

void log_printf(const char *fmt, ...)
{
    if (!g_log_on || !g_log[0])
        return;
    FILE *f = fopen(g_log, "a");
    if (!f)
        return;
    SYSTEMTIME t;
    GetLocalTime(&t);
    fprintf(f, "%02d:%02d:%02d %s ", t.wHour, t.wMinute, t.wSecond, g_game ? g_game->name : "?");
    va_list ap;
    va_start(ap, fmt);
    vfprintf(f, fmt, ap);
    va_end(ap);
    fputc('\n', f);
    fclose(f);
}

int cfg_int(const char *section, const char *key, int def)
{
    return (int)GetPrivateProfileIntA(section, key, def, g_ini);
}

void cfg_set_int(const char *section, const char *key, int value)
{
    char buf[16];
    wsprintfA(buf, "%d", value);
    WritePrivateProfileStringA(section, key, buf, g_ini);
}

static LRESULT CALLBACK hk_wndproc(HWND h, UINT msg, WPARAM wp, LPARAM lp)
{
    if (speed_on_key(h, msg, wp))
        return 0;
    return CallWindowProcA(g_game_wndproc, h, msg, wp, lp);
}

/* Las dos WndProc del juego se registran con RegisterClassExA: se intercala la nuestra. */
static ATOM WINAPI hk_RegisterClassExA(const WNDCLASSEXA *wc)
{
    WNDCLASSEXA c = *wc;
    if (!g_game_wndproc) {
        g_game_wndproc = c.lpfnWndProc;
        c.lpfnWndProc = hk_wndproc;
        log_printf("ok WndProc del juego (0x%08lx) envuelta", (unsigned long)(uintptr_t)g_game_wndproc);
    }
    return RegisterClassExA(&c);
}

static const GameInfo *detect(void)
{
    uint8_t *base = (uint8_t *)GetModuleHandleA(NULL);
    IMAGE_NT_HEADERS *nt = (IMAGE_NT_HEADERS *)(base + ((IMAGE_DOS_HEADER *)base)->e_lfanew);
    for (size_t i = 0; i < sizeof GAMES / sizeof *GAMES; i++)
        if (nt->FileHeader.TimeDateStamp == GAMES[i].timestamp &&
            nt->OptionalHeader.SizeOfImage == GAMES[i].size_of_image)
            return &GAMES[i];
    return NULL;
}

static void init(void)
{
    char exe[MAX_PATH];
    GetModuleFileNameA(NULL, exe, sizeof exe);
    lstrcpyA(g_dir, exe);
    char *slash = strrchr(g_dir, '\\');
    if (slash)
        slash[1] = 0;
    wsprintfA(g_ini, "%sscenh.ini", g_dir);
    wsprintfA(g_log, "%sscenh.log", g_dir);
    g_log_on = cfg_int("general", "log", 1);

    g_game = detect();
    if (!g_game) {
        log_printf("EXE no reconocido (%s): no se aplica ninguna mejora", exe);
        return;
    }
    log_printf("scenh " SCENH_VERSION " cargado");
    if (!cfg_int("general", "activar", 1)) {
        log_printf("mejoras desactivadas en scenh.ini ([general] activar=0)");
        return;
    }
    hook_import("USER32.dll", "RegisterClassExA", (void *)hk_RegisterClassExA);
    osd_init();
    speed_init();
}

BOOL WINAPI DllMain(HINSTANCE inst, DWORD reason, LPVOID reserved)
{
    (void)reserved;
    if (reason == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(inst);
        init();
    }
    return TRUE;
}
