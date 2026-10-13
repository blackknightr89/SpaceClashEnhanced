/* HUD centrado en pantallas de más de 1024 px de ancho (parte planetaria, CLASH.EXE).
 *
 * El HUD del juego tiene x absolutas pensadas para 1024 (en globales de apply_mode_layout y en literales
 * del código de dibujo). En vez de cambiar cada una, se desplaza todo el HUD dx = (ancho − 1024) / 2:
 *  - dibujo: en render_game_view (0x41DCB0) el tramo que dibuja el HUD (de 0x41DEE9 a la llamada a
 *    0x41A890/0x43CD90) escribe en g_framebuf (0x493214); durante ese tramo el puntero se adelanta dx
 *    píxeles, así que todo lo que dibuja cae dx más a la derecha. Quedan fuera la ventana del tutorial
 *    (0x432EE0) y la barra de mensajes (0x41E8F0, anclada al borde derecho de la pantalla);
 *  - ratón: las funciones que comparan el ratón (0x729DC4/0x729DC8) con el HUD (botones 0x42BAF0, forma
 *    del cursor 0x42A540, minimapa 0x42AF80 y 0x419030, ventanas 0x42B670) lo ven dx más a la izquierda
 *    cuando está sobre la franja del HUD y no hay ninguna ventana abierta (0x8F2298 = −1). El cursor se
 *    dibuja fuera de esos tramos, en su posición real;
 *  - fondo: resolution.c compone M1024.PCX centrado (hud_offset()).
 * Se aplica solo con el HUD visible (F9 lo oculta) y en el modo panorámico.
 */
#include "scenh.h"
#include <string.h>

#define G_FRAMEBUF   ((uint8_t *volatile *)0x493214)
#define G_SCREEN_W   ((volatile int16_t *)0x8F1E60)
#define G_SCREEN_H   ((volatile int16_t *)0x8F1E62)
#define G_HUD_SHOWN  ((volatile int32_t *)0x729DD8)
#define G_WINDOW_ID  ((volatile int16_t *)0x8F2298)
#define G_MOUSE_X    ((volatile int32_t *)0x729DC4)
#define G_MOUSE_Y    ((volatile int32_t *)0x729DC8)
#define HUD_H        167

static int g_on, g_wide_w;
static int g_drawing;                  /* dentro del tramo de dibujo del HUD */
static uint8_t *g_real_framebuf;
static int g_mouse_shifted, g_mouse_value;

int hud_offset(int screen_w)
{
    return g_on && screen_w == g_wide_w && screen_w > 1024 ? (screen_w - 1024) / 2 : 0;
}

static int active_dx(void)
{
    return *G_HUD_SHOWN ? hud_offset(*G_SCREEN_W) : 0;
}

static void mouse_shift(int dx)
{
    if (dx && *G_MOUSE_Y >= *G_SCREEN_H - HUD_H && *G_WINDOW_ID == -1) {
        *G_MOUSE_X -= dx;
        g_mouse_value = *G_MOUSE_X;
        g_mouse_shifted = dx;
    }
}

static void mouse_unshift(void)
{
    if (g_mouse_shifted && *G_MOUSE_X == g_mouse_value)   /* si la función no lo cambió */
        *G_MOUSE_X += g_mouse_shifted;
    g_mouse_shifted = 0;
}

static void begin(void)
{
    int dx = active_dx();
    if (!dx || g_drawing)
        return;
    g_real_framebuf = *G_FRAMEBUF;
    *G_FRAMEBUF = g_real_framebuf + dx;
    mouse_shift(dx);
    g_drawing = 1;
}

static void end(void)
{
    if (!g_drawing)
        return;
    *G_FRAMEBUF = g_real_framebuf;
    mouse_unshift();
    g_drawing = 0;
}

/* ---- envoltorios de llamadas (cdecl, mismos argumentos que el original) ---- */
typedef int(__cdecl *fn0)(void);
typedef int(__cdecl *fn1)(int);
typedef int(__cdecl *fn2)(int, int);
typedef int(__cdecl *fn4)(int, int, int, int);

static int __cdecl w_clip_begin(int a, int b, int c, int d)   /* 0x41DEE4: set_clip(0,0,w-1,h-1) */
{
    int r = ((fn4)0x446830)(a, b, c, d);
    begin();
    return r;
}

static int __cdecl w_tutorial(int a, int b)                   /* 0x41E07F: ventana del tutorial */
{
    int was = g_drawing;
    end();
    int r = ((fn2)0x432EE0)(a, b);
    if (was)
        begin();
    return r;
}

static int __cdecl w_message_bar(int buf)                     /* 0x41E08D: barra de mensajes */
{
    int was = g_drawing;
    if (was) {
        buf -= active_dx();   /* el argumento se leyó con el puntero adelantado */
        end();
    }
    int r = ((fn1)0x41E8F0)(buf);
    if (was)
        begin();
    return r;
}

static int __cdecl w_end2(int a, int b)                       /* 0x41E198: fin del tramo */
{
    end();
    return ((fn2)0x41A890)(a, b);
}

static int __cdecl w_end0(void)                               /* 0x41E1A0: fin del tramo */
{
    end();
    return ((fn0)0x43CD90)();
}

#define MOUSE_WRAPPER(name, target)                            \
    static int __cdecl name(void)                              \
    {                                                          \
        mouse_shift(active_dx());                              \
        int r = ((fn0)(target))();                             \
        mouse_unshift();                                       \
        return r;                                              \
    }
MOUSE_WRAPPER(w_cursor_shape, 0x42A540)
MOUSE_WRAPPER(w_minimap_hover, 0x42AF80)
MOUSE_WRAPPER(w_minimap_click, 0x419030)
MOUSE_WRAPPER(w_windows, 0x42B670)
MOUSE_WRAPPER(w_buttons, 0x42BAF0)

static const struct { uintptr_t at, target; void *wrapper; } CALLS[] = {
    {0x41DEE4, 0x446830, (void *)w_clip_begin}, {0x41E07F, 0x432EE0, (void *)w_tutorial},
    {0x41E08D, 0x41E8F0, (void *)w_message_bar}, {0x41E198, 0x41A890, (void *)w_end2},
    {0x41E1A0, 0x43CD90, (void *)w_end0},       {0x41A657, 0x42A540, (void *)w_cursor_shape},
    {0x41A65C, 0x42AF80, (void *)w_minimap_hover}, {0x42BCCC, 0x419030, (void *)w_minimap_click},
    {0x42BD45, 0x42B670, (void *)w_windows},     {0x42BD4A, 0x42BAF0, (void *)w_buttons},
};

void hud_init(int wide_w)
{
    if (g_game->kind != EXE_CLASH || wide_w <= 1024 || !cfg_int("resolucion", "centrar_hud", 1))
        return;
    for (size_t i = 0; i < sizeof CALLS / sizeof *CALLS; i++) {
        const uint8_t *p = (const uint8_t *)CALLS[i].at;
        if (p[0] != 0xE8 || CALLS[i].at + 5 + *(const int32_t *)(p + 1) != CALLS[i].target) {
            log_printf("RECHAZADO HUD centrado: la llamada en 0x%08lx no coincide", (unsigned long)CALLS[i].at);
            return;
        }
    }
    for (size_t i = 0; i < sizeof CALLS / sizeof *CALLS; i++) {
        int32_t old = *(const int32_t *)(CALLS[i].at + 1);
        int32_t rel = (int32_t)((uintptr_t)CALLS[i].wrapper - (CALLS[i].at + 5));
        patch_bytes(CALLS[i].at + 1, &old, &rel, 4, "HUD centrado: llamada");
    }
    g_wide_w = wide_w;
    g_on = 1;
    log_printf("ok HUD centrado (desplazamiento %d px)", (wide_w - 1024) / 2);
}
