/* Z2: zoom en caliente con la rueda del ratón (parte planetaria, CLASH.EXE).
 *
 * El juego tiene tres modos de partida: 1 = 640×480 (cerca), 2 = 800×600, 3 = 1024×768 (lejos; o la
 * resolución panorámica de [resolucion]). El original solo cambia de modo al empezar una misión, pero
 * sabe volver a un modo en plena partida: 0x426AF0 llama a change_video_mode (0x428D20), que libera las
 * superficies, cambia el modo, ajusta la ventana y rehace la maquetación (apply_mode_layout).
 * Aquí la WndProc solo anota el pedido; el cambio se hace entre fotogramas, desde PeekMessage, y solo
 * si la simulación está avanzando (frame_tick activo: no en menús ni en pausa) y no es multijugador.
 * Después se restaura la paleta de la partida y se limita la cámara al nuevo tamaño de vista.
 */
#include "scenh.h"
#include <mmsystem.h>
#include <string.h>

#define G_VIDEO_MODE   ((volatile int16_t *)0x5C7E3C)
#define G_CFG_MODE     ((volatile int16_t *)0x492108)
#define G_CAM_X        ((volatile int32_t *)0x694FC4)
#define G_CAM_Y        ((volatile int32_t *)0x694FC8)
#define G_MAP_W        ((volatile int16_t *)0x694FC0)
#define G_MAP_H        ((volatile int16_t *)0x694FC2)
#define G_VIEW_W       ((volatile int16_t *)0x8BD522)
#define G_VIEW_H       ((volatile int16_t *)0x8BE650)
#define G_TERRAIN_DIRTY ((volatile int32_t *)0x694FD4)
#define GAME_PALETTE   ((void *)0x728880)

typedef int(__cdecl *change_mode_fn)(int idx);
typedef void(__cdecl *set_palette_fn)(void *pal);

static int g_on, g_pending;   /* g_pending: modo pedido (1–3) o 0 */

static int simulation_running(void)
{
    DWORD last = *(volatile DWORD *)g_game->last_tick_ms;
    return !*(volatile int *)g_game->paused && timeGetTime() - last < 200 &&
           *(volatile uint8_t *)g_game->game_mode != 4;
}

static void clamp_camera(void)
{
    int max_x = *G_MAP_W * 40 - *G_VIEW_W - 1, max_y = *G_MAP_H * 40 - *G_VIEW_H - 1;
    if (*G_CAM_X > max_x)
        *G_CAM_X = max_x > 0 ? max_x : 0;
    if (*G_CAM_Y > max_y)
        *G_CAM_Y = max_y > 0 ? max_y : 0;
}

void zoom_apply_pending(void)
{
    if (!g_pending)
        return;
    int idx = g_pending;
    g_pending = 0;
    if (!simulation_running() || idx == *G_VIDEO_MODE) {
        log_printf("zoom: modo %d ignorado (simulación %s, modo actual %d)", idx,
                   simulation_running() ? "en marcha" : "detenida", *G_VIDEO_MODE);
        return;
    }
    /* mantener centrado lo que se está mirando */
    int cx = *G_CAM_X + *G_VIEW_W / 2, cy = *G_CAM_Y + *G_VIEW_H / 2;
    if (!((change_mode_fn)0x428D20)(idx)) {
        log_printf("zoom: change_video_mode(%d) falló", idx);
        return;
    }
    log_printf("zoom: modo %d aplicado (vista %dx%d)", idx, *G_VIEW_W, *G_VIEW_H);
    ((set_palette_fn)0x414BD0)(GAME_PALETTE);
    *G_CFG_MODE = (int16_t)idx;   /* que la próxima misión empiece igual */
    *G_CAM_X = cx - *G_VIEW_W / 2;
    *G_CAM_Y = cy - *G_VIEW_H / 2;
    if (*G_CAM_X < 0) *G_CAM_X = 0;
    if (*G_CAM_Y < 0) *G_CAM_Y = 0;
    clamp_camera();
    *G_TERRAIN_DIRTY = 1;
    static const char *names[] = {"", "ZOOM: CERCA", "ZOOM: MEDIO", "ZOOM: LEJOS"};
    osd_show(names[idx], 1200);
}

/* Devuelve 1 si consumió el mensaje. */
int zoom_on_message(UINT msg, WPARAM wp)
{
    if (!g_on || msg != WM_MOUSEWHEEL)
        return 0;
    int delta = (short)HIWORD(wp);
    int cur = g_pending ? g_pending : *G_VIDEO_MODE;
    int next = cur + (delta > 0 ? -1 : 1);   /* rueda hacia adelante = acercar */
    if (next >= 1 && next <= 3)
        g_pending = next;
    return 1;
}

void zoom_init(void)
{
    if (g_game->kind != EXE_CLASH || !cfg_int("zoom", "activar", 1))
        return;
    static const uint8_t head[] = {0x56, 0xE8};   /* change_video_mode: push esi; call 0x4269D0 */
    if (memcmp((void *)0x428D20, head, sizeof head) != 0) {
        log_printf("RECHAZADO zoom: change_video_mode no coincide");
        return;
    }
    g_on = 1;
    log_printf("ok zoom con la rueda del ratón");
}
