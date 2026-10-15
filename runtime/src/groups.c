/* Q3: grupos de selección y Q4: desplazamiento con las flechas (CLASH.EXE y SPACE.EXE).
 *
 * Parte planetaria (CLASH):
 * El original ya tiene grupos: Ctrl+0–9 guarda la selección en g_select_groups (0x8DB540, [10][150]) y el
 * número solo la recupera (WndProc 0x42C0C0, WM_KEYDOWN '0'–'9'). Falta lo habitual en un RTS: pulsar dos
 * veces seguidas el mismo número para llevar la cámara al grupo.
 *
 * La WndProc solo anota la doble pulsación; el centrado se hace en el bucle del juego, justo después de
 * camera_tick (0x42BCB0, llamada única en 0x42BDBB). camera_tick calcula el desplazamiento del fotograma
 * (g_cam_dx/dy = anterior − nuevo) y marca el terreno para redibujar; aquí se suma el salto a ese
 * desplazamiento, igual que cuando se arrastra el minimapa, y se aplica el mismo límite que el original
 * (0 .. mapa·40 − vista − 1). Unidades: 0x752100 + (jugador·150 + i)·0x4C8 (docs/re/partidas-red.md §1.4).
 *
 * Mapa estelar (SPACE): el original no tiene grupos. Se añaden igual que en CLASH: Ctrl+0–9 guarda las
 * naves seleccionadas y 0–9 las recupera; dos pulsaciones centran la cámara. Naves: g_ships 0x69A740,
 * 4 × 150 × 0x388 B; +2 índice (−1 = libre), +4 seleccionada (lo que recorren las órdenes a la selección,
 * p. ej. 0x404560), +0x26C ≠ 0 = no disponible (las órdenes la saltan), +0x1E0/+0x1E8 posición (double, px).
 * La cámara (0x773B24/28) se mueve justo antes de galaxy_scroll (0x41AEB0, llamada por fotograma en
 * 0x413200) y se la llama con force=1: aplica el límite y desplaza el fondo y las capas de paralaje
 * según el salto, como cualquier otro desplazamiento.
 *
 * Flechas: en el original solo mueven la selección en las listas de las ventanas; la cámara se mueve con
 * los bordes de la pantalla (CLASH camera_scroll_update 0x419030, SPACE galaxy_scroll 0x41AEB0: ratón a
 * menos de 5 px del borde → velocidad +4 por tick hasta 40). Con una flecha apretada, durante esa llamada
 * se pone el ratón del juego en el borde que corresponde y luego se restaura: mismo desplazamiento, misma
 * aceleración y mismos límites que con el ratón. El eje sin flecha queda en el centro de la vista. No con
 * una ventana o diálogo abierto (ahí las flechas son del juego) ni con el botón derecho apretado
 * (arrastre del minimapa). El estado de las flechas se lleva desde la WndProc (KEYDOWN/KEYUP; se suelta
 * todo al perder el foco). En CLASH el ratón se cambia alrededor de camera_tick, que llama a
 * camera_scroll_update a través del desvío de hud.c (0x42BCCC); en SPACE, justo antes de galaxy_scroll.
 */
#include "scenh.h"

#define CAMERA_TICK 0x42BCB0
#define CAMERA_TICK_CALL 0x42BDBB
#define UNITS 0x752100
#define UNIT_SIZE 0x4C8
#define LOCAL_PLAYER 0x8F1E84         /* u8 */
#define CAM_X 0x694FC4                /* int32 */
#define CAM_Y 0x694FC8
#define CAM_DX 0x694FCC               /* int32: anterior − nuevo del fotograma */
#define CAM_DY 0x694FD0
#define TERRAIN_DIRTY 0x694FD4
#define MAP_W 0x694FC0                /* int16, en celdas de 40 px */
#define MAP_H 0x694FC2
#define VIEW_W 0x8BD522               /* int16 */
#define VIEW_H 0x8BE650
#define DOUBLE_MS 400

/* SPACE */
#define GALAXY_SCROLL 0x41AEB0
#define GALAXY_SCROLL_CALL 0x413200
#define SHIPS 0x69A740
#define SHIP_SIZE 0x388
#define SPACE_PLAYER 0x98A244         /* u8 */
#define GALAXY_CAM_X 0x773B24         /* int32 */
#define GALAXY_CAM_Y 0x773B28
#define GALAXY_VIEW_W 0x807180        /* int16 */
#define GALAXY_VIEW_H 0x807188
#define SPACE_PAUSED 0x69A1E4
#define SPACE_MODAL 0x98A344          /* pantallas de victoria, derrota o rango */
#define SPACE_WINDOW 0x71EE30         /* ventana abierta (≠ 0) */

/* ratón (int32), botón derecho (u8) y tamaño lógico de la pantalla (int16) */
#define CL_MOUSE_X 0x729DC4
#define CL_MOUSE_Y 0x729DC8
#define CL_RBUTTON 0x729DCE
#define CL_SCREEN_W 0x8F1E60
#define CL_SCREEN_H 0x8F1E62
#define SP_MOUSE_X 0x73F9C4
#define SP_MOUSE_Y 0x73F9C8
#define SP_RBUTTON 0x73F9CE
#define SP_SCREEN_W 0x817090
#define SP_SCREEN_H 0x817092

static int g_on;          /* grupos */
static int g_arrows_on;   /* flechas */
static volatile int g_arrow[4];   /* izquierda, arriba, derecha, abajo (VK_LEFT..VK_DOWN) */
static int g_last_digit = -1;
static DWORD g_last_time;
static volatile int g_center_pending;
static uint8_t g_space_groups[10][150];

static uint8_t *ship(int i)
{
    return (uint8_t *)SHIPS + ((size_t)*(volatile uint8_t *)SPACE_PLAYER * 150 + i) * SHIP_SIZE;
}

static int ship_usable(const uint8_t *s)
{
    return *(const int16_t *)(s + 2) != -1 && *(const int32_t *)(s + 0x26C) == 0;
}

/* SPACE: Ctrl+N guarda la selección, N la recupera (devuelve 0 si no se está en el mapa estelar). */
static int space_group_key(int d, int ctrl)
{
    if (*(volatile int32_t *)SPACE_PAUSED || *(volatile int32_t *)SPACE_MODAL || *(volatile int32_t *)SPACE_WINDOW)
        return 0;
    for (int i = 0; i < 150; i++) {
        uint8_t *s = ship(i);
        if (ctrl)
            g_space_groups[d][i] = *(const int16_t *)(s + 2) != -1 && *(const int32_t *)(s + 4);
        else if (ship_usable(s))
            *(int32_t *)(s + 4) = g_space_groups[d][i];
    }
    return 1;
}

static void arrows_on_message(UINT msg, WPARAM wp)
{
    if (msg == WM_KILLFOCUS || (msg == WM_ACTIVATEAPP && !wp)) {
        g_arrow[0] = g_arrow[1] = g_arrow[2] = g_arrow[3] = 0;
    } else if ((msg == WM_KEYDOWN || msg == WM_KEYUP) && wp >= VK_LEFT && wp <= VK_DOWN) {
        g_arrow[wp - VK_LEFT] = msg == WM_KEYDOWN;
    }
}

int groups_on_message(UINT msg, WPARAM wp, LPARAM lp)
{
    if (g_arrows_on)
        arrows_on_message(msg, wp);
    if (!g_on || msg != WM_KEYDOWN || wp < '0' || wp > '9' || (lp & (1 << 30)))   /* sin autorrepetición */
        return 0;
    int ctrl = GetKeyState(VK_CONTROL) < 0;
    if (g_game->kind == EXE_SPACE && !space_group_key((int)wp - '0', ctrl))
        return 0;
    if (ctrl)   /* guardar grupo */
        return 0;
    DWORD now = GetTickCount();
    if ((int)wp - '0' == g_last_digit && now - g_last_time <= DOUBLE_MS) {
        g_center_pending = 1;
        g_last_digit = -1;
    } else {
        g_last_digit = (int)wp - '0';
        g_last_time = now;
    }
    return 0;   /* la tecla sigue hacia el juego (CLASH recupera el grupo; SPACE la ignora) */
}

/* Pone el ratón del juego en el borde que piden las flechas; devuelve 1 si lo cambió (guarda el valor). */
static int arrows_push(uintptr_t mx, uintptr_t my, uintptr_t rbutton, uintptr_t sw, uintptr_t sh,
                       int window_open, int32_t saved[2])
{
    int h = g_arrow[2] - g_arrow[0], v = g_arrow[3] - g_arrow[1];
    if (!g_arrows_on || (!h && !v) || window_open || *(volatile uint8_t *)rbutton)
        return 0;
    int w = *(volatile int16_t *)sw, ht = *(volatile int16_t *)sh;
    volatile int32_t *x = (volatile int32_t *)mx, *y = (volatile int32_t *)my;
    saved[0] = *x;
    saved[1] = *y;
    *x = h < 0 ? 0 : h > 0 ? w - 1 : w / 2;
    *y = v < 0 ? 0 : v > 0 ? ht - 1 : ht / 3;   /* sin flecha vertical: dentro de la vista, lejos del HUD */
    return 1;
}

static void arrows_pop(uintptr_t mx, uintptr_t my, const int32_t saved[2])
{
    *(volatile int32_t *)mx = saved[0];
    *(volatile int32_t *)my = saved[1];
}

static int clampi(int v, int lo, int hi)
{
    return v < lo ? lo : v > hi ? hi : v;
}

static void __cdecl hk_camera_tick(void)
{
    int32_t saved[2];
    int pushed = arrows_push(CL_MOUSE_X, CL_MOUSE_Y, CL_RBUTTON, CL_SCREEN_W, CL_SCREEN_H,
                             clash_dialog_open(), saved);
    ((void(__cdecl *)(void))CAMERA_TICK)();
    if (pushed)
        arrows_pop(CL_MOUSE_X, CL_MOUSE_Y, saved);
    if (!g_on || !g_center_pending)
        return;
    g_center_pending = 0;
    const uint8_t *u = (const uint8_t *)UNITS + (size_t)*(volatile uint8_t *)LOCAL_PLAYER * 150 * UNIT_SIZE;
    long sx = 0, sy = 0, n = 0;
    for (int i = 0; i < 150; i++, u += UNIT_SIZE) {
        if (*(const int16_t *)(u + 2) == -1 || !*(const int32_t *)(u + 8) || !*(const int16_t *)(u + 0x48))
            continue;
        sx += *(const int16_t *)(u + 0x70) * 40 + 20;
        sy += *(const int16_t *)(u + 0x72) * 40 + 20;
        n++;
    }
    if (!n)
        return;
    int vw = *(volatile int16_t *)VIEW_W, vh = *(volatile int16_t *)VIEW_H;
    int x = clampi((int)(sx / n) - vw / 2, 0, *(volatile int16_t *)MAP_W * 40 - vw - 1);
    int y = clampi((int)(sy / n) - vh / 2, 0, *(volatile int16_t *)MAP_H * 40 - vh - 1);
    volatile int32_t *cx = (volatile int32_t *)CAM_X, *cy = (volatile int32_t *)CAM_Y;
    *(volatile int32_t *)CAM_DX += (int16_t)(*cx - x);
    *(volatile int32_t *)CAM_DY += (int16_t)(*cy - y);
    *cx = x;
    *cy = y;
    if (*(volatile int32_t *)CAM_DX || *(volatile int32_t *)CAM_DY)
        *(volatile int32_t *)TERRAIN_DIRTY = 1;
}

static void __cdecl hk_galaxy_scroll(int force)
{
    if (g_on && g_center_pending) {
        g_center_pending = 0;
        double sx = 0, sy = 0;
        int n = 0;
        for (int i = 0; i < 150; i++) {
            const uint8_t *s = ship(i);
            if (*(const int16_t *)(s + 2) == -1 || !*(const int32_t *)(s + 4))
                continue;
            sx += *(const double *)(s + 0x1E0);
            sy += *(const double *)(s + 0x1E8);
            n++;
        }
        if (n) {   /* galaxy_scroll aplica el límite con force=1 */
            *(volatile int32_t *)GALAXY_CAM_X = (int32_t)(sx / n) - *(volatile int16_t *)GALAXY_VIEW_W / 2;
            *(volatile int32_t *)GALAXY_CAM_Y = (int32_t)(sy / n) - *(volatile int16_t *)GALAXY_VIEW_H / 2;
            force = 1;
        }
    }
    int32_t saved[2];
    int window = *(volatile int32_t *)SPACE_WINDOW || *(volatile int32_t *)SPACE_MODAL;
    int pushed = arrows_push(SP_MOUSE_X, SP_MOUSE_Y, SP_RBUTTON, SP_SCREEN_W, SP_SCREEN_H, window, saved);
    ((void(__cdecl *)(int))GALAXY_SCROLL)(force);
    if (pushed)
        arrows_pop(SP_MOUSE_X, SP_MOUSE_Y, saved);
}

static int hook_call(uintptr_t at, uintptr_t target, void *repl, const char *what)
{
    const uint8_t *p = (const uint8_t *)at;
    int32_t old = (int32_t)(target - (at + 5));
    if (p[0] != 0xE8 || *(const int32_t *)(p + 1) != old) {
        log_printf("RECHAZADO %s: la llamada no coincide", what);
        return 0;
    }
    int32_t rel = (int32_t)((uintptr_t)repl - (at + 5));
    return patch_bytes(at + 1, &old, &rel, 4, what);
}

void groups_init(void)
{
    int groups = cfg_int("grupos", "activar", 1), arrows = cfg_int("desplazamiento", "flechas", 1), ok = 0;
    if (!groups && !arrows)
        return;
    if (g_game->kind == EXE_CLASH)
        ok = hook_call(CAMERA_TICK_CALL, CAMERA_TICK, (void *)hk_camera_tick,
                       "grupos (centrado con doble pulsación) y cámara con las flechas");
    else if (g_game->kind == EXE_SPACE)
        ok = hook_call(GALAXY_SCROLL_CALL, GALAXY_SCROLL, (void *)hk_galaxy_scroll,
                       "grupos de naves (Ctrl+0-9, centrado) y cámara con las flechas");
    g_on = ok && groups;
    g_arrows_on = ok && arrows;
}
