/* Q5: autoguardado al empezar cada misión (CLASH.EXE).
 *
 * Cada misión empieza en mission_start (0x40FBF0), llamada desde 4 sitios: el traspaso desde el mapa
 * estelar o la misión siguiente de la campaña lineal (0x411B1E, 0x411B2B), y volver a empezar tras una
 * derrota (0x412549, 0x42B78B). Se interceptan esas llamadas y, unos segundos después, desde el bucle
 * principal (PeekMessage), se guarda con la misma función que el menú Guardar (save_game 0x417C80, que en
 * la campaña espacial copia también esp.sav y planeta.nfo) y se refresca la lista de partidas (0x416F30).
 *
 * Ranura: [autoguardado] ranura (0–9; por defecto 9, la décima de la lista). Solo se usa si está vacía o
 * ya es un autoguardado: a la descripción se le antepone "AUTO - " para reconocerla en Cargar partida.
 * Una partida del jugador en esa ranura nunca se pisa. En multijugador no se guarda.
 */
#include "scenh.h"
#include <mmsystem.h>
#include <stdio.h>
#include <string.h>

#define MISSION_START 0x40FBF0
#define SAVE_GAME 0x417C80
#define REFRESH_SAVES 0x416F30
#define GAME_MODE 0x875C44            /* 4 = multijugador */
#define MISSION_RESULT 0x483BB0       /* 0 = en juego */
#define SIG "EFSCLANSSAV"
#define SIG_ESP "EFSCLANSESP"
#define DESC_LEN 0x96
#define PREFIX "AUTO - "
#define DELAY_MS 3000

typedef void(__cdecl *start_fn)(int);
typedef int(__cdecl *save_fn)(int);
typedef void(__cdecl *void_fn)(void);

static const uintptr_t CALLS[] = {0x411B1E, 0x411B2B, 0x412549, 0x42B78B};
static int g_slot = -1;
static DWORD g_due;              /* 0 = nada pendiente */
static DWORD g_last_tick;

static void __cdecl hk_mission_start(int restart)
{
    ((start_fn)MISSION_START)(restart);
    if (*(volatile uint8_t *)GAME_MODE != 4)
        g_due = timeGetTime() + DELAY_MS;
}

/* 1 si la ranura se puede usar: no existe o ya es un autoguardado. */
static int slot_free(const char *path)
{
    FILE *f = fopen(path, "rb");
    if (!f)
        return 1;
    char head[11 + sizeof PREFIX] = {0};
    size_t n = fread(head, 1, sizeof head - 1, f);
    fclose(f);
    int sig = n >= 11 && (memcmp(head, SIG, 11) == 0 || memcmp(head, SIG_ESP, 11) == 0);
    return sig && memcmp(head + 11, PREFIX, sizeof PREFIX - 1) == 0;
}

static void mark_auto(const char *path)
{
    FILE *f = fopen(path, "r+b");
    if (!f)
        return;
    char desc[DESC_LEN], out[DESC_LEN] = {0};
    if (fseek(f, 11, SEEK_SET) == 0 && fread(desc, 1, DESC_LEN, f) == DESC_LEN) {
        desc[DESC_LEN - 1] = 0;
        _snprintf(out, DESC_LEN - 1, "%s%s", PREFIX, desc);
        fseek(f, 11, SEEK_SET);
        fwrite(out, 1, DESC_LEN, f);
    }
    fclose(f);
}

void autosave_poll(void)
{
    if (!g_due || (int)(timeGetTime() - g_due) < 0)
        return;
    /* esperar a que la misión esté corriendo: sin pausa, sin resultado y con la simulación avanzando */
    DWORD tick = *(volatile DWORD *)g_game->last_tick_ms;
    int running = !*(volatile int *)g_game->paused && *(volatile uint8_t *)MISSION_RESULT == 0 &&
                  tick != g_last_tick;
    g_last_tick = tick;
    if (!running)
        return;
    g_due = 0;
    char path[MAX_PATH];
    wsprintfA(path, "%ss%d.sav", g_dir, g_slot);
    if (!slot_free(path)) {
        log_printf("autoguardado omitido: la ranura %d tiene una partida del jugador", g_slot + 1);
        osd_show("AUTOGUARDADO: RANURA OCUPADA", 2500);
        return;
    }
    if (!((save_fn)SAVE_GAME)(g_slot)) {
        log_printf("autoguardado: falló save_game(%d)", g_slot);
        return;
    }
    mark_auto(path);
    ((void_fn)REFRESH_SAVES)();
    log_printf("autoguardado en la ranura %d", g_slot + 1);
    osd_show("PARTIDA GUARDADA", 1500);
}

void autosave_init(void)
{
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
