/* HUD centrado en pantallas de más de 1024 px de ancho (CLASH.EXE y SPACE.EXE).
 *
 * El HUD del juego tiene x absolutas pensadas para 1024 (en globales de la maquetación y en literales del
 * código de dibujo). En vez de cambiar cada una, se desplaza todo el HUD dx = (ancho − 1024) / 2:
 *  - dibujo: en la función de render, el tramo que dibuja el HUD escribe en el búfer de dibujo
 *    (CLASH 0x493214, SPACE 0x487D0C); durante ese tramo el puntero se adelanta dx píxeles, así que todo
 *    lo que se dibuja cae dx más a la derecha. En CLASH quedan fuera la ventana del tutorial (0x432EE0) y
 *    la barra de mensajes (0x41E8F0, anclada al borde derecho de la pantalla);
 *  - ratón: las funciones que comparan el ratón con el HUD lo ven dx más a la izquierda cuando está sobre
 *    la franja del HUD (alto − 167) y no hay ninguna ventana abierta. El cursor (por software) se dibuja
 *    fuera de esos tramos, en su posición real;
 *  - fondo: resolution.c compone M1024.PCX centrado (hud_offset()).
 * Solo con el HUD visible (F9 lo oculta) y en el modo panorámico. Evidencias: docs/re/mapa.md, video.md.
 */
#include "scenh.h"
#include <string.h>

#define HUD_H 167

typedef int(__cdecl *fn0)(void);
typedef int(__cdecl *fn1)(int);
typedef int(__cdecl *fn2)(int, int);
typedef int(__cdecl *fn4)(int, int, int, int);

enum { W_BEGIN4, W_SUSPEND2, W_SUSPEND_BUF1, W_END2, W_END0, W_CALL2_END, W_ISOLATED1, W_MOUSE0 };
typedef struct { uintptr_t at, target; int kind; } HudCall;

typedef struct {
    ExeKind kind;
    uintptr_t framebuf, screen_w, screen_h, hud_shown, mouse_x, mouse_y;
    uintptr_t window_flag; int window_none;   /* valor del indicador cuando no hay ventana abierta */
    int window_is_int16;
    HudCall calls[12];
} HudSites;

static const HudSites SITES[] = {
    {EXE_CLASH, 0x493214, 0x8F1E60, 0x8F1E62, 0x729DD8, 0x729DC4, 0x729DC8, 0x8F2298, -1, 1,
     {{0x41DEE4, 0x446830, W_BEGIN4},          /* set_clip(0,0,w-1,h-1): empieza el HUD */
      {0x41E07F, 0x432EE0, W_SUSPEND2},        /* ventana del tutorial */
      {0x41E08D, 0x41E8F0, W_SUSPEND_BUF1},    /* barra de mensajes */
      {0x41E198, 0x41A890, W_END2},            /* fin del tramo */
      {0x41E1A0, 0x43CD90, W_END0},
      {0x41A657, 0x42A540, W_MOUSE0},          /* forma del cursor / zona */
      {0x41A65C, 0x42AF80, W_MOUSE0},          /* minimapa: posición bajo el ratón */
      {0x42BCCC, 0x419030, W_MOUSE0},          /* minimapa: clic y desplazamiento por bordes */
      {0x42BD45, 0x42B670, W_MOUSE0},          /* ventanas */
      {0x42BD4A, 0x42BAF0, W_MOUSE0}}},        /* botones del HUD */
    {EXE_SPACE, 0x487D0C, 0x817090, 0x817092, 0x73F9D8, 0x73F9C4, 0x73F9C8, 0x71EE30, 0, 0,
     {{0x4133B7, 0x412B30, W_ISOLATED1},       /* minimapa del HUD (arg 0; con 1 es la carta grande F8) */
      {0x4133E7, 0x430410, W_BEGIN4},          /* set_clip(0,0,w-1,h-1) antes de draw_hud_panels */
      {0x413467, 0x404C70, W_CALL2_END},       /* último botón del HUD (0x98A260): fin del tramo */
      {0x41CC0A, 0x413050, W_MOUSE0},          /* game_logic_step: botones, minimapa, bordes */
      {0x412466, 0x41C5D0, W_MOUSE0}}},        /* zona y forma del cursor */
};

static const HudSites *S;
static int g_on, g_wide_w;
static int g_drawing;
static uint8_t *g_real_framebuf;
static int g_mouse_shifted, g_mouse_value;

#define I16(a) (*(volatile int16_t *)(a))
#define I32(a) (*(volatile int32_t *)(a))

int hud_offset(int screen_w)
{
    return g_on && screen_w == g_wide_w && screen_w > 1024 ? (screen_w - 1024) / 2 : 0;
}

static int active_dx(void)
{
    return I32(S->hud_shown) ? hud_offset(I16(S->screen_w)) : 0;
}

static int window_open(void)
{
    int v = S->window_is_int16 ? I16(S->window_flag) : I32(S->window_flag);
    return v != S->window_none;
}

static void mouse_shift(int dx)
{
    if (dx && !g_mouse_shifted && I32(S->mouse_y) >= I16(S->screen_h) - HUD_H && !window_open()) {
        I32(S->mouse_x) -= dx;
        g_mouse_value = I32(S->mouse_x);
        g_mouse_shifted = dx;
    }
}

static void mouse_unshift(void)
{
    if (g_mouse_shifted && I32(S->mouse_x) == g_mouse_value)   /* si la función no lo cambió */
        I32(S->mouse_x) += g_mouse_shifted;
    g_mouse_shifted = 0;
}

static void begin(void)
{
    int dx = active_dx();
    if (!dx || g_drawing)
        return;
    g_real_framebuf = *(uint8_t **)S->framebuf;
    *(uint8_t **)S->framebuf = g_real_framebuf + dx;
    mouse_shift(dx);
    g_drawing = dx;
}

static void end(void)
{
    if (!g_drawing)
        return;
    *(uint8_t **)S->framebuf = g_real_framebuf;
    mouse_unshift();
    g_drawing = 0;
}

/* Un envoltorio por llamada: cada uno guarda su destino original. */
static uintptr_t g_target[12];

#define WRAP(n)                                                                                       \
    static int __cdecl w##n(int a, int b, int c, int d)                                             \
    {                                                                                                 \
        switch (S->calls[n].kind) {                                                                   \
        case W_BEGIN4: { int r = ((fn4)g_target[n])(a, b, c, d); begin(); return r; }                 \
        case W_SUSPEND2: { int was = g_drawing; end(); int r = ((fn2)g_target[n])(a, b);             \
                           if (was) { begin(); } return r; }                                          \
        case W_SUSPEND_BUF1: { int was = g_drawing; if (was) { a -= was; end(); }                    \
                               int r = ((fn1)g_target[n])(a); if (was) { begin(); } return r; }      \
        case W_END2: end(); return ((fn2)g_target[n])(a, b);                                         \
        case W_END0: end(); return ((fn0)g_target[n])();                                             \
        case W_CALL2_END: { int r = ((fn2)g_target[n])(a, b); end(); return r; }                     \
        case W_ISOLATED1: { begin(); int r = ((fn1)g_target[n])(a); end(); return r; }               \
        default: { mouse_shift(active_dx()); int r = ((fn0)g_target[n])(); mouse_unshift();         \
                   return r; }                                                                        \
        }                                                                                             \
    }
WRAP(0) WRAP(1) WRAP(2) WRAP(3) WRAP(4) WRAP(5) WRAP(6) WRAP(7) WRAP(8) WRAP(9)
static void *const WRAPPERS[] = {(void *)w0, (void *)w1, (void *)w2, (void *)w3, (void *)w4,
                                 (void *)w5, (void *)w6, (void *)w7, (void *)w8, (void *)w9};

void hud_init(int wide_w)
{
    if (wide_w <= 1024 || !cfg_int("resolucion", "centrar_hud", 1))
        return;
    for (size_t i = 0; i < sizeof SITES / sizeof *SITES; i++)
        if (SITES[i].kind == g_game->kind)
            S = &SITES[i];
    if (!S)
        return;
    int n = 0;
    for (; n < 10 && S->calls[n].at; n++) {
        const uint8_t *p = (const uint8_t *)S->calls[n].at;
        if (p[0] != 0xE8 || S->calls[n].at + 5 + *(const int32_t *)(p + 1) != S->calls[n].target) {
            log_printf("RECHAZADO HUD centrado: la llamada en 0x%08lx no coincide", (unsigned long)S->calls[n].at);
            S = NULL;
            return;
        }
    }
    for (int i = 0; i < n; i++) {
        g_target[i] = S->calls[i].target;
        int32_t old = *(const int32_t *)(S->calls[i].at + 1);
        int32_t rel = (int32_t)((uintptr_t)WRAPPERS[i] - (S->calls[i].at + 5));
        patch_bytes(S->calls[i].at + 1, &old, &rel, 4, "HUD centrado: llamada");
    }
    g_wide_w = wide_w;
    g_on = 1;
    log_printf("ok HUD centrado (desplazamiento %d px)", (wide_w - 1024) / 2);
}
