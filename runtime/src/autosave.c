/* Q5: autoguardado al empezar cada misión (CLASH.EXE) y guardado/carga rápidos con tecla (CLASH y SPACE).
 *
 * Autoguardado:
 * Cada misión empieza en mission_start (0x40FBF0), llamada desde 4 sitios: el traspaso desde el mapa
 * estelar o la misión siguiente de la campaña lineal (0x411B1E, 0x411B2B), y volver a empezar tras una
 * derrota (0x412549, 0x42B78B). Se interceptan esas llamadas y, unos segundos después, desde el bucle
 * principal (PeekMessage) y sin ningún diálogo abierto (objetivos, "¿deseas intentar…?"), se guarda
 * con la misma función que el menú Guardar (save_game 0x417C80, que en la campaña espacial copia
 * también esp.sav y planeta.nfo) y se refresca la lista de partidas (0x416F30).
 *
 * Ranura: [autoguardado] ranura (0–9; por defecto 9, la décima de la lista). Solo se usa si está vacía o
 * ya es un autoguardado: a la descripción se le antepone "AUTO - " para reconocerla en Cargar partida.
 * Una partida del jugador en esa ranura nunca se pisa. En multijugador no se guarda.
 *
 * Guardado rápido: F12 guarda y Ctrl+F12 carga ([guardado_rapido] tecla, código de tecla virtual), en la
 * ranura [guardado_rapido] ranura (por defecto 8, la novena), marcada "RAPIDA - " (la fuente del juego no
 * siempre tiene tildes). Misma regla: no se pisa una partida del jugador. Funciona en partida (también en
 * pausa) y sin ventanas ni diálogos abiertos; no en multijugador ni en los menús.
 *  - CLASH: guarda con save_game (0x417C80). Carga con el camino diferido del propio juego: 0x8BF9F8 =
 *    ranura y 0x85F050 = 1; el bucle de la partida (0x42BD24) llama a load_game (0x417040) en su momento.
 *    Si la ranura tiene una partida del mapa estelar, load_game hace el traspaso a SPACE.EXE.
 *  - SPACE: las funciones de su ventana Guardar/Cargar (0x426E30): sav_save (0x40F650) y refresco de la
 *    lista (0x410390); sav_load (0x40FC20, con 0 como en esa ventana), que con una partida planetaria
 *    vuelve a CLASH.EXE.
 */
#include "scenh.h"
#include <mmsystem.h>
#include <stdio.h>
#include <string.h>

#define MISSION_START 0x40FBF0
#define SAVE_GAME 0x417C80
#define REFRESH_SAVES 0x416F30
#define GAME_MODE 0x875C44            /* 4 = multijugador */
#define MISSION_RESULT 0x483BB0       /* 0 recién empezada, 1 en juego, 2 victoria, 3 derrota */
#define SIG "EFSCLANSSAV"
#define SIG_ESP "EFSCLANSESP"
#define DESC_LEN 0x96
#define PREFIX "AUTO - "
#define PREFIX_QUICK "RAPIDA - "
#define DELAY_MS 3000
#define MENU_FLAG 0x8DDC60            /* CLASH: != 0 fuera de la partida (menús) */
#define LOAD_SLOT 0x8BF9F8            /* CLASH: ranura de la carga diferida (u8) */
#define LOAD_PENDING 0x85F050         /* CLASH: carga diferida pendiente (int) */
#define SPACE_SAVE 0x40F650
#define SPACE_LOAD 0x40FC20
#define SPACE_REFRESH 0x410390
#define SPACE_MODAL 0x98A344          /* pantallas de victoria, derrota o rango */
#define SPACE_WINDOW 0x71EE30         /* ventana abierta (!= 0) */
/* diálogos (≠ 0 = abierto: los que cierran Enter/Esc en la WndProc) y ventana de F1–F7 (−1 = ninguna) */
static const uintptr_t DIALOGS[] = {0x87DB70, 0x87EC90, 0x8BD550, 0x8BE810};
#define PANEL_WINDOW 0x8F2298

typedef void(__cdecl *start_fn)(int);
typedef int(__cdecl *save_fn)(int);
typedef void(__cdecl *void_fn)(void);
typedef int(__cdecl *load2_fn)(int, int);

static const uintptr_t CALLS[] = {0x411B1E, 0x411B2B, 0x412549, 0x42B78B};
static int g_slot = -1;
static DWORD g_due;              /* 0 = nada pendiente */
static DWORD g_last_tick;
static int g_quick_on, g_quick_slot = -1, g_quick_key = VK_F12;
static volatile int g_quick_pending;   /* 1 guardar, 2 cargar */

static void __cdecl hk_mission_start(int restart)
{
    ((start_fn)MISSION_START)(restart);
    if (*(volatile uint8_t *)GAME_MODE != 4)
        g_due = timeGetTime() + DELAY_MS;
}

/* 1 si la ranura se puede usar: no existe o ya es una partida nuestra (descripción con `prefix`). */
static int slot_free(const char *path, const char *prefix)
{
    FILE *f = fopen(path, "rb");
    if (!f)
        return 1;
    char head[32] = {0};
    size_t n = fread(head, 1, sizeof head - 1, f);
    fclose(f);
    int sig = n >= 11 && (memcmp(head, SIG, 11) == 0 || memcmp(head, SIG_ESP, 11) == 0);
    return sig && memcmp(head + 11, prefix, strlen(prefix)) == 0;
}

static int slot_exists(int slot)
{
    char path[MAX_PATH];
    wsprintfA(path, "%ss%d.sav", g_dir, slot);
    return GetFileAttributesA(path) != INVALID_FILE_ATTRIBUTES;
}

static void mark(const char *path, const char *prefix)
{
    FILE *f = fopen(path, "r+b");
    if (!f)
        return;
    char desc[DESC_LEN], out[DESC_LEN] = {0};
    if (fseek(f, 11, SEEK_SET) == 0 && fread(desc, 1, DESC_LEN, f) == DESC_LEN) {
        desc[DESC_LEN - 1] = 0;
        _snprintf(out, DESC_LEN - 1, "%s%s", prefix, desc);
        fseek(f, 11, SEEK_SET);
        fwrite(out, 1, DESC_LEN, f);
    }
    fclose(f);
}

static int dialog_open(void)
{
    for (size_t i = 0; i < sizeof DIALOGS / sizeof *DIALOGS; i++)
        if (*(volatile int16_t *)DIALOGS[i])
            return 1;
    return *(volatile int16_t *)PANEL_WINDOW != -1;
}

/* En partida (también en pausa), sin ventanas ni diálogos y fuera de multijugador. */
static int quick_allowed(void)
{
    int paused = *(volatile int *)g_game->paused;
    int ticking = timeGetTime() - *(volatile DWORD *)g_game->last_tick_ms < 500;
    if (!paused && !ticking)
        return 0;
    if (g_game->kind == EXE_CLASH)
        return !*(volatile int *)MENU_FLAG && !dialog_open() && *(volatile uint8_t *)GAME_MODE != 4 &&
               *(volatile uint8_t *)MISSION_RESULT < 2;
    return !*(volatile int32_t *)SPACE_MODAL && !*(volatile int32_t *)SPACE_WINDOW;
}

static void quick_save(void)
{
    char path[MAX_PATH];
    wsprintfA(path, "%ss%d.sav", g_dir, g_quick_slot);
    if (!slot_free(path, PREFIX_QUICK)) {
        log_printf("guardado rápido omitido: la ranura %d tiene una partida del jugador", g_quick_slot + 1);
        osd_show("GUARDADO RAPIDO: RANURA OCUPADA", 2500);
        return;
    }
    int ok = g_game->kind == EXE_CLASH ? ((save_fn)SAVE_GAME)(g_quick_slot) : ((save_fn)SPACE_SAVE)(g_quick_slot);
    if (!ok) {
        log_printf("guardado rápido: falló el guardado en la ranura %d", g_quick_slot + 1);
        osd_show("NO SE PUDO GUARDAR", 2000);
        return;
    }
    mark(path, PREFIX_QUICK);
    ((void_fn)(g_game->kind == EXE_CLASH ? REFRESH_SAVES : SPACE_REFRESH))();
    log_printf("guardado rápido en la ranura %d", g_quick_slot + 1);
    osd_show("PARTIDA GUARDADA", 1500);
}

static void quick_load(void)
{
    if (!slot_exists(g_quick_slot)) {
        osd_show("NO HAY PARTIDA RAPIDA", 2000);
        return;
    }
    log_printf("carga rápida de la ranura %d", g_quick_slot + 1);
    if (g_game->kind == EXE_CLASH) {
        *(volatile uint8_t *)LOAD_SLOT = (uint8_t)g_quick_slot;
        *(volatile int32_t *)LOAD_PENDING = 1;
    } else if (!((load2_fn)SPACE_LOAD)(g_quick_slot, 0)) {
        osd_show("NO SE PUDO CARGAR", 2000);
    }
}

/* Desde la WndProc: solo anota el pedido (se hace en autosave_poll, entre fotogramas). */
int quicksave_on_message(UINT msg, WPARAM wp, LPARAM lp)
{
    if (!g_quick_on || msg != WM_KEYDOWN || (int)wp != g_quick_key || (lp & (1 << 30)))
        return 0;
    g_quick_pending = GetKeyState(VK_CONTROL) < 0 ? 2 : 1;
    return 1;
}

void autosave_poll(void)
{
    if (g_quick_pending) {
        int what = g_quick_pending;
        g_quick_pending = 0;
        if (!quick_allowed())
            osd_show("AHORA NO SE PUEDE", 1500);
        else if (what == 1)
            quick_save();
        else
            quick_load();
    }
    if (!g_due || (int)(timeGetTime() - g_due) < 0 || dialog_open())
        return;
    /* esperar a que la misión esté corriendo: sin pausa, sin resultado y con la simulación avanzando */
    DWORD tick = *(volatile DWORD *)g_game->last_tick_ms;
    int running = !*(volatile int *)g_game->paused && *(volatile uint8_t *)MISSION_RESULT < 2 &&
                  tick != g_last_tick;
    g_last_tick = tick;
    if (!running)
        return;
    g_due = 0;
    char path[MAX_PATH];
    wsprintfA(path, "%ss%d.sav", g_dir, g_slot);
    if (!slot_free(path, PREFIX)) {
        log_printf("autoguardado omitido: la ranura %d tiene una partida del jugador", g_slot + 1);
        osd_show("AUTOGUARDADO: RANURA OCUPADA", 2500);
        return;
    }
    if (!((save_fn)SAVE_GAME)(g_slot)) {
        log_printf("autoguardado: falló save_game(%d)", g_slot);
        return;
    }
    mark(path, PREFIX);
    ((void_fn)REFRESH_SAVES)();
    log_printf("autoguardado en la ranura %d", g_slot + 1);
    osd_show("PARTIDA GUARDADA", 1500);
}

/* Comprueba que en `at` haya un "call target" (rel32). */
static int is_call(uintptr_t at, uintptr_t target)
{
    const uint8_t *p = (const uint8_t *)at;
    return p[0] == 0xE8 && at + 5 + *(const int32_t *)(p + 1) == target;
}

static void quicksave_init(void)
{
    if (!cfg_int("guardado_rapido", "activar", 1))
        return;
    int slot = cfg_int("guardado_rapido", "ranura", 8), key = cfg_int("guardado_rapido", "tecla", VK_F12);
    if (slot < 0 || slot > 9 || key <= 0 || key > 0xFE) {
        log_printf("RECHAZADO guardado rápido: ranura %d (0–9) o tecla %d inválidas", slot, key);
        return;
    }
    int ok;
    if (g_game->kind == EXE_CLASH) {
        static const uint8_t pending_read[] = {0xA1, 0x50, 0xF0, 0x85, 0x00};   /* mov eax,[0x85F050] */
        ok = memcmp((void *)0x42BD24, pending_read, sizeof pending_read) == 0 && is_call(0x42BD33, 0x417040) &&
             is_call(0x43E98B, SAVE_GAME) && is_call(0x43E9B7, REFRESH_SAVES);
    } else {
        ok = is_call(0x428282, SPACE_LOAD) && is_call(0x428345, SPACE_SAVE) && is_call(0x428370, SPACE_REFRESH);
    }
    if (!ok) {
        log_printf("RECHAZADO guardado rápido: las funciones de guardar/cargar no coinciden");
        return;
    }
    g_quick_slot = slot;
    g_quick_key = key;
    g_quick_on = 1;
    log_printf("guardado rápido: tecla 0x%02X guarda, Ctrl+tecla carga (ranura %d)", key, slot + 1);
}

void autosave_init(void)
{
    quicksave_init();
    if (g_game->kind != EXE_CLASH || !cfg_int("autoguardado", "activar", 1))
        return;
    int slot = cfg_int("autoguardado", "ranura", 9);
    if (slot < 0 || slot > 9) {
        log_printf("RECHAZADO autoguardado: ranura %d fuera de 0–9", slot);
        return;
    }
    int ok = 1;
    for (size_t i = 0; i < sizeof CALLS / sizeof *CALLS; i++) {
        const uint8_t *p = (const uint8_t *)CALLS[i];
        ok &= p[0] == 0xE8 && CALLS[i] + 5 + *(const int32_t *)(p + 1) == MISSION_START;
    }
    if (!ok) {
        log_printf("RECHAZADO autoguardado: las llamadas a mission_start no coinciden");
        return;
    }
    for (size_t i = 0; i < sizeof CALLS / sizeof *CALLS; i++) {
        int32_t old = (int32_t)(MISSION_START - (CALLS[i] + 5));
        int32_t rel = (int32_t)((uintptr_t)hk_mission_start - (CALLS[i] + 5));
        patch_bytes(CALLS[i] + 1, &old, &rel, 4, "autoguardado: llamada a mission_start");
    }
    g_slot = slot;
    log_printf("autoguardado al empezar cada misión en la ranura %d", slot + 1);
}
