/* I4/I6: resolución panorámica (experimental) en CLASH.EXE (parte planetaria) y SPACE.EXE (mapa estelar).
 *
 * Se reutiliza el modo 3 del juego (1024×768, el que elige Opciones → 1024) con el tamaño de scenh.ini
 * [resolucion] ancho/alto. Evidencias en docs/re/video.md §0, §5.2 y §6:
 *  - tabla de modos {int32 ancho, alto, bpp}[4]: la entrada 3 pasa a ancho×alto;
 *  - la función de maquetación fija ancho/alto del modo 3 con dos inmediatos;
 *  - todos los búferes de pantalla se reservan al arrancar con 1024×768 forzado o malloc(0xC0000);
 *  - la vista (ancho × alto−167), la cámara y el minimapa se derivan de ancho/alto;
 *  - el HUD (M1024.PCX, 1024×768) se carga con un lector que escribe en lineal con el ancho del PCX:
 *    se intercepta esa llamada y se compone fila a fila, anclado abajo a la izquierda;
 *  - SPACE: tres SetWindowPos fijos a 1024×768, y el fondo estelar FONDO.PCX (1560×1310) que draw_fondo
 *    copia sin recorte: se sustituye por una copia que, si la vista no cabe, estira el fondo lo justo.
 * Sin pitch: las copias a la superficie usan ancho×alto, así que el ancho debe ser múltiplo de 8.
 */
#include "scenh.h"
#include <string.h>

#define HUD_W 1024
#define HUD_H 768
#define FONDO_W 1560
#define FONDO_H 1310

typedef int16_t(__cdecl *pcx_load_fn)(const char *path, uint8_t *dst, uint8_t *pal, int flag);

typedef struct { uintptr_t at; uint8_t size; uint32_t old; int what; } Imm;   /* what: 0 ancho, 1 alto, 2 área */

typedef struct {
    ExeKind kind;
    uintptr_t mode3;                  /* tabla de modos, entrada 3 */
    Imm imms[12];
    uintptr_t hud_call;               /* "call pcx_load" de M1024.PCX */
    uintptr_t pcx_load;
    uintptr_t draw_fondo;             /* SPACE: copia del fondo con paralaje */
} ResSites;

static const ResSites SITES[] = {
    {EXE_CLASH, 0x457574,
     {{0x428A85, 2, 768, 1}, {0x428A8E, 2, 1024, 0},                                /* apply_mode_layout */
      {0x4154BD, 4, 0xC0000, 2}, {0x4154C8, 2, 1024, 0}, {0x4154D1, 2, 768, 1}},   /* búferes */
     0x428C7B, 0x429360, 0},
    {EXE_SPACE, 0x43E47C,
     {{0x420B17, 2, 1024, 0}, {0x420B1B, 2, 768, 1},                                /* set_screen_size */
      {0x40E19B, 2, 1024, 0}, {0x40E1A4, 2, 768, 1}, {0x40E1A7, 4, 0xC0000, 2},    /* búferes */
      {0x40E9F7, 4, 768, 1}, {0x40E9FC, 4, 1024, 0},                                /* SetWindowPos ×3 */
      {0x40EDD5, 4, 768, 1}, {0x40EDDA, 4, 1024, 0},
      {0x414147, 4, 768, 1}, {0x41414C, 4, 1024, 0}},
     0x420CA5, 0x419A20, 0x412890},
};

static int g_w, g_h;          /* tamaño actual del modo 3 (el zoom lo cambia: resolution_set_mode3) */
static int g_max_w, g_max_h;  /* el de scenh.ini: los búferes se reservan para este */
static const ResSites *g_sites;

static int __cdecl hud_pcx_load(const char *path, uint8_t *dst, uint8_t *pal, int flag)
{
    static uint8_t tmp[HUD_W * HUD_H];
    int r = ((pcx_load_fn)g_sites->pcx_load)(path, tmp, pal, flag);
    int dx = hud_offset(g_w);   /* 0 = anclado a la izquierda; si no, centrado (hud.c) */
    memset(dst, 0, (size_t)g_w * g_h);
    for (int y = 0; y < HUD_H; y++) {   /* anclado abajo; si el alto es menor, se recorta por arriba */
        int dy = y + g_h - HUD_H;
        if (dy >= 0)
            memcpy(dst + (size_t)dy * g_w + dx, tmp + (size_t)y * HUD_W, HUD_W);
    }
    /* Fuera de los 1024 px del HUD: se prolonga la moldura superior (filas 601–629, lisa entre x=650 y
     * 760) repitiendo un tramo de 32 px; debajo queda negro como el fondo de los paneles. */
    for (int y = 601; y <= 629; y++) {
        int dy = y + g_h - HUD_H;
        if (dy < 0)
            continue;
        for (int x = 0; x < g_w; x++)
            if (x < dx || x >= dx + HUD_W)
                dst[(size_t)dy * g_w + x] = tmp[(size_t)y * HUD_W + 700 + ((x - dx) % 32 + 32) % 32];
    }
    return r;
}

/* Posición en FONDO.PCX para el píxel i de la vista: directa si todo el recorrido del paralaje cabe en el
 * fondo; si no, escalada para que el recorrido completo (desplazamiento máximo + vista) ocupe el fondo. */
static int fondo_coord(int scroll, int i, int view, int limit, int size)
{
    int range = (limit - view - 1) / 8 + view;   /* el original: cámara <= límite − vista − 1; fondo = cámara/8 */
    if (range < view)
        range = view;
    int v = range > size ? (int)((int64_t)(scroll + i) * size / range) : scroll + i;
    return v < 0 ? 0 : v >= size ? size - 1 : v;
}

/* SPACE draw_fondo (0x412890): igual que el original, pero sin leer fuera de FONDO.PCX (1560×1310): con
 * vistas grandes el fondo se estira lo justo en el eje que no alcanza. */
static void __cdecl space_draw_fondo(void)
{
    static int cols[2560];
    const uint8_t *fondo = *(uint8_t **)0x80B174;
    uint8_t *dst = *(uint8_t **)0x487D0C;
    int w = *(int16_t *)0x817090, view_h = *(int16_t *)0x807188;
    int sx = *(int *)0x5C1704, sy = *(int *)0x5C1708;
    int lim_x = *(int16_t *)0x6980B4, lim_y = *(int16_t *)0x6980B8;   /* tamaño de la galaxia en px */
    if (fondo && dst && w <= 2560) {
        for (int x = 0; x < w; x++)
            cols[x] = fondo_coord(sx, x, w, lim_x, FONDO_W);
        for (int y = 0; y < view_h; y++) {
            const uint8_t *row = fondo + (size_t)fondo_coord(sy, y, view_h, lim_y, FONDO_H) * FONDO_W;
            uint8_t *out = dst + (size_t)y * w;
            if (cols[w - 1] - cols[0] == w - 1) {
                memcpy(out, row + cols[0], (size_t)w);
            } else {
                for (int x = 0; x < w; x++)
                    out[x] = row[cols[x]];
            }
        }
    }
    ((void(__cdecl *)(void))0x41B6E0)();   /* segunda pasada del original (capa por encima del fondo) */
}

void resolution_init(void)
{
    if (!cfg_int("resolucion", "activar", 0))
        return;
    for (size_t i = 0; i < sizeof SITES / sizeof *SITES; i++)
        if (SITES[i].kind == g_game->kind)
            g_sites = &SITES[i];
    if (!g_sites)
        return;
    g_w = cfg_int("resolucion", "ancho", 1280);
    g_h = cfg_int("resolucion", "alto", 720);
    if (g_w < 1024 || g_h < 600 || g_w > 2560 || g_h > 1600 || g_w % 8 || g_w * g_h < HUD_W * HUD_H) {
        log_printf("RECHAZADO resolución %dx%d: ancho 1024–2560 (múltiplo de 8), alto 600–1600 y área >= 1024x768",
                   g_w, g_h);
        return;
    }
    /* Comprobar todo antes de escribir nada: o se aplica entero o no se aplica */
    static const uint32_t mode3[2] = {1024, 768};
    int ok = memcmp((void *)g_sites->mode3, mode3, sizeof mode3) == 0;
    for (const Imm *m = g_sites->imms; m->at; m++)
        ok &= memcmp((void *)m->at, &m->old, m->size) == 0;
    int32_t hud_rel = *(int32_t *)(g_sites->hud_call + 1);
    ok &= *(uint8_t *)g_sites->hud_call == 0xE8 && g_sites->hud_call + 5 + hud_rel == g_sites->pcx_load;
    static const uint8_t fondo_head[] = {0x53, 0x55, 0x56, 0x57, 0x33, 0xDB};   /* push ebx/ebp/esi/edi; xor ebx,ebx */
    if (g_sites->draw_fondo)
        ok &= memcmp((void *)g_sites->draw_fondo, fondo_head, sizeof fondo_head) == 0;
    if (!ok) {
        log_printf("RECHAZADO resolución: el código no coincide con el %s conocido", g_game->name);
        return;
    }

    uint32_t table[2] = {(uint32_t)g_w, (uint32_t)g_h};
    patch_bytes(g_sites->mode3, mode3, table, sizeof table, "tabla de modos: modo 3");
    for (const Imm *m = g_sites->imms; m->at; m++) {
        uint32_t v = m->what == 0 ? (uint32_t)g_w : m->what == 1 ? (uint32_t)g_h : (uint32_t)(g_w * g_h);
        patch_bytes(m->at, &m->old, &v, m->size, m->what == 2 ? "tamaño de búfer" : "ancho/alto del modo 3");
    }
    int32_t rel = (int32_t)((uintptr_t)hud_pcx_load - (g_sites->hud_call + 5));
    patch_bytes(g_sites->hud_call + 1, &hud_rel, &rel, 4, "carga del HUD M1024.PCX");
    if (g_sites->draw_fondo)
        patch_jmp(g_sites->draw_fondo, fondo_head, sizeof fondo_head, (void *)space_draw_fondo,
                  "draw_fondo → fondo sin salirse de FONDO.PCX");
    g_max_w = g_w;
    g_max_h = g_h;
    log_printf("resolución del modo 1024 cambiada a %dx%d", g_w, g_h);
    hud_init(g_w);
}

/* Tamaño máximo configurado (0 si la resolución panorámica no está activa). */
int resolution_max(int *w, int *h)
{
    if (!g_max_w)
        return 0;
    *w = g_max_w;
    *h = g_max_h;
    return 1;
}

/* Cambia en caliente el tamaño lógico del modo 3 (para el zoom): los inmediatos de la maquetación
 * (CLASH apply_mode_layout, SPACE set_screen_size: las dos primeras entradas de imms). La tabla de modos
 * queda en el máximo, así que las superficies de DirectDraw se crean siempre a ese tamaño y el zoom escala
 * por software (zoom.c). */
int resolution_set_mode3(int w, int h)
{
    if (!g_max_w || !g_sites || w > g_max_w || h > g_max_h || w < HUD_W)
        return 0;
    if (w == g_w && h == g_h)
        return 1;
    for (int i = 0; i < 2; i++) {
        const Imm *m = &g_sites->imms[i];
        uint16_t old = (uint16_t)(m->what == 0 ? g_w : g_h), v = (uint16_t)(m->what == 0 ? w : h);
        if (!patch_bytes(m->at, &old, &v, 2, m->what == 0 ? "zoom: ancho del modo 3" : "zoom: alto del modo 3"))
            return 0;
    }
    g_w = w;
    g_h = h;
    return 1;
}
