/* Q2: velocidad de juego ajustable y menos consumo de CPU.
 *
 * El juego avanza un tick de simulación cuando timeGetTime() supera en más de 0x25 ms al del último tick
 * (frame_tick: CLASH 0x42BED9 "cmp ecx,0x25", SPACE 0x41CBE0 "cmp edx,0x25"): un tick cada 38 ms. Cambiar
 * ese byte cambia el ritmo de toda la simulación. El reloj de misión y la lógica "por segundo" van con el
 * temporizador 1 (SetTimer de 1000 ms), que se reescala igual. En multijugador (lockstep) no se toca.
 *
 * El bucle principal (PeekMessage sin Sleep) ocupa un núcleo entero: si no hay mensajes y falta tiempo
 * para el siguiente tick, se duerme 1 ms.
 */
#include "scenh.h"
#include <mmsystem.h>

#define BASE_TICK_MS 38
static const int LEVELS[] = {50, 75, 100, 150, 200, 300};   /* % de la velocidad original */
#define NLEVELS ((int)(sizeof LEVELS / sizeof *LEVELS))

static int g_level = 2;          /* índice en LEVELS */
static int g_speed_ok;           /* el byte del umbral se verificó */
static int g_keys, g_cpu;
static HWND g_timer_hwnd;
static TIMERPROC g_timer_proc;
static int g_timer_set;
static int g_debug;
static ImportHook g_hk_settimer = {"USER32.dll", "SetTimer", (void *)hk_SetTimer, 0, 0};
static ImportHook g_hk_killtimer = {"USER32.dll", "KillTimer", (void *)hk_KillTimer, 0, 0};
static ImportHook g_hk_peek = {"USER32.dll", "PeekMessageA", (void *)hk_PeekMessageA, 0, 0};
typedef UINT_PTR(WINAPI *settimer_fn)(HWND, UINT_PTR, UINT, TIMERPROC);
typedef BOOL(WINAPI *killtimer_fn)(HWND, UINT_PTR);
typedef BOOL(WINAPI *peek_fn)(LPMSG, HWND, UINT, UINT, UINT);

static int threshold_for(int pct)
{
    return (BASE_TICK_MS * 100 + pct / 2) / pct - 1;   /* tick cuando pasan > umbral ms */
}

static int timer_ms(void)
{
    return 1000 * 100 / LEVELS[g_level];
}

static int in_multiplayer(void)
{
    return g_game->game_mode && *(volatile uint8_t *)g_game->game_mode == 4;
}

static void apply_level(int announce)
{
    if (!g_speed_ok)
        return;
    uint8_t want = (uint8_t)threshold_for(LEVELS[g_level]);
    uint8_t cur = *(volatile uint8_t *)g_game->tick_threshold;
    if (cur != want)
        patch_bytes(g_game->tick_threshold, &cur, &want, 1, "umbral de tick");
    if (g_timer_set)
        SetTimer(g_timer_hwnd, 1, timer_ms(), g_timer_proc);
    if (announce) {
        char msg[32];
        int pct = LEVELS[g_level];
        if (pct % 100 == 0)
            wsprintfA(msg, "VELOCIDAD X%d", pct / 100);
        else if (pct % 10 == 0)
            wsprintfA(msg, "VELOCIDAD X%d,%d", pct / 100, (pct % 100) / 10);
        else
            wsprintfA(msg, "VELOCIDAD X%d,%02d", pct / 100, pct % 100);
        osd_show(msg, 1500);
        cfg_set_int("velocidad", "inicial", pct);
        log_printf("velocidad %d%% (umbral %d ms)", pct, want);
    }
}

void speed_init(void)
{
    g_keys = cfg_int("velocidad", "teclas", 1);
    g_cpu = cfg_int("cpu", "ahorro", 1);
    g_debug = cfg_int("general", "depurar", 0);
    int initial = cfg_int("velocidad", "inicial", 100);
    for (int i = 0; i < NLEVELS; i++)
        if (LEVELS[i] == initial)
            g_level = i;

    static const uint8_t orig = 0x25;
    g_speed_ok = cfg_int("velocidad", "activar", 1) && *(volatile uint8_t *)g_game->tick_threshold <= 0x7F;
    if (g_speed_ok && *(volatile uint8_t *)g_game->tick_threshold != orig) {
        log_printf("RECHAZADO velocidad: el umbral de tick no vale 0x25");
        g_speed_ok = 0;
    }
    if (g_speed_ok) {
        import_hook_install(&g_hk_settimer);
        import_hook_install(&g_hk_killtimer);
        apply_level(0);
    }
    if (g_cpu)
        timeBeginPeriod(1);
    /* también lo usa el zoom (zoom.c) para aplicar el cambio de modo entre fotogramas */
    import_hook_install(&g_hk_peek);
}

/* Devuelve 1 si consumió la tecla. */
int speed_on_key(HWND h, UINT msg, WPARAM wp)
{
    (void)h;
    if (msg != WM_KEYDOWN || !g_keys || !g_speed_ok)
        return 0;
    int dir = 0;
    if (wp == VK_ADD || wp == VK_OEM_PLUS)
        dir = 1;
    else if (wp == VK_SUBTRACT || wp == VK_OEM_MINUS)
        dir = -1;
    if (!dir)
        return 0;
    if (in_multiplayer()) {
        osd_show("VELOCIDAD FIJA EN RED", 1500);
        return 1;
    }
    int next = g_level + dir;
    if (next >= 0 && next < NLEVELS)
        g_level = next;
    apply_level(1);
    return 1;
}

UINT_PTR WINAPI hk_SetTimer(HWND h, UINT_PTR id, UINT ms, TIMERPROC proc)
{
    if (id == 1 && ms == 1000) {   /* temporizador de 1 s del juego */
        if (!g_timer_set)
            log_printf("temporizador de 1 s del juego a %d ms", in_multiplayer() ? 1000 : timer_ms());
        g_timer_hwnd = h;
        g_timer_proc = proc;
        g_timer_set = 1;
        ms = in_multiplayer() ? 1000 : (UINT)timer_ms();
    }
    return ((settimer_fn)g_hk_settimer.next)(h, id, ms, proc);
}

BOOL WINAPI hk_KillTimer(HWND h, UINT_PTR id)
{
    if (id == 1 && h == g_timer_hwnd)
        g_timer_set = 0;
    return ((killtimer_fn)g_hk_killtimer.next)(h, id);
}

/* depurar=1: ticks de simulación por segundo en scenh.log, cada 5 s */
static void measure(void)
{
    static DWORD last_seen, window_start;
    static int ticks;
    DWORD t = *(volatile DWORD *)g_game->last_tick_ms, now = timeGetTime();
    if (t != last_seen) {
        last_seen = t;
        ticks++;
    }
    if (!window_start)
        window_start = now;
    if (now - window_start >= 5000) {
        log_printf("depurar: %d ticks en %lu ms = %d,%d ticks/s (velocidad %d%%)", ticks,
                   (unsigned long)(now - window_start), ticks * 1000 / (int)(now - window_start),
                   ticks * 10000 / (int)(now - window_start) % 10, LEVELS[g_level]);
        ticks = 0;
        window_start = now;
    }
}

BOOL WINAPI hk_PeekMessageA(LPMSG m, HWND h, UINT lo, UINT hi, UINT remove)
{
    zoom_apply_pending();
    static int depth;   /* por si otro eslabón volviera a llamar por la IAT: ir directo a USER32 */
    BOOL r;
    if (depth) {
        r = PeekMessageA(m, h, lo, hi, remove);
    } else {
        depth++;
        r = ((peek_fn)g_hk_peek.next)(m, h, lo, hi, remove);
        depth--;
    }
    if (g_debug)
        measure();
    if (!r && g_cpu) {
        if (*(volatile int *)g_game->paused) {
            Sleep(5);
        } else {
            int wait = (int)(*(volatile DWORD *)g_game->last_tick_ms
                             + *(volatile uint8_t *)g_game->tick_threshold + 1 - timeGetTime());
            if (wait >= 2 && wait <= 200)
                Sleep(1);
        }
    }
    return r;
}
