/* I4 (spike): resolución panorámica en la parte planetaria (CLASH.EXE).
 *
 * Se reutiliza el modo 3 del juego (1024×768, el que elige Opciones → 1024) con el tamaño de scenh.ini
 * [resolucion] ancho/alto. Evidencias en docs/re/video.md §0 y §6:
 *  - tabla de modos {int32 ancho, alto, bpp}[4] en 0x457550: la entrada 3 pasa a ancho×alto;
 *  - apply_mode_layout (0x428A70) fija ancho/alto del modo 3 con inmediatos (0x428A83, 0x428A87);
 *  - todos los búferes de pantalla se reservan en 0x4154BC–0x415530 con 1024×768 forzado o 0xC0000;
 *  - la vista del mapa (ancho × alto−167), la cámara y el minimapa se derivan de ancho/alto;
 *  - el HUD (M1024.PCX, 1024×768) se carga con un lector que escribe en lineal con el ancho del PCX
 *    (0x429360): se intercepta esa llamada y se compone fila a fila, anclado abajo a la izquierda.
 * Sin pitch: las copias a la superficie usan ancho×alto, así que el ancho debe ser múltiplo de 8.
 */
#include "scenh.h"
#include <string.h>

#define MIN_W 1024
#define MIN_H 768
#define MAX_W 2560
#define MAX_H 1600

static int g_w, g_h;
typedef int(__cdecl *pcx_load_fn)(const char *path, uint8_t *dst, uint8_t *pal, int flag);
static const pcx_load_fn pcx_load = (pcx_load_fn)0x429360;

/* Sustituye la llamada a pcx_load de M1024.PCX en apply_mode_layout (0x428C7B). */
static int __cdecl hud_pcx_load(const char *path, uint8_t *dst, uint8_t *pal, int flag)
{
    static uint8_t tmp[MIN_W * MIN_H];
    int r = pcx_load(path, tmp, pal, flag);
    memset(dst, 0, (size_t)g_w * g_h);
    for (int y = 0; y < MIN_H; y++) {   /* anclado abajo; si el alto es menor, se recorta por arriba */
        int dy = y + g_h - MIN_H;
        if (dy >= 0)
            memcpy(dst + (size_t)dy * g_w, tmp + (size_t)y * MIN_W, MIN_W);
    }
    /* A la derecha de los 1024 px del HUD: se prolonga la moldura superior (filas 601–629 del PCX,
     * lisa entre x=650 y 760) repitiendo un tramo de 32 px; debajo queda negro como el fondo de los paneles. */
    for (int y = 601; y <= 629; y++) {
        int dy = y + g_h - MIN_H;
        if (dy < 0)
            continue;
        for (int x = MIN_W; x < g_w; x++)
            dst[(size_t)dy * g_w + x] = tmp[(size_t)y * MIN_W + 700 + (x - MIN_W) % 32];
    }
    return r;
}

static void imm16(uintptr_t at, uint16_t old, uint16_t now, const char *what)
{
    patch_bytes(at, &old, &now, 2, what);
}

static void imm32(uintptr_t at, uint32_t old, uint32_t now, const char *what)
{
    patch_bytes(at, &old, &now, 4, what);
}

void resolution_init(void)
{
    if (g_game->kind != EXE_CLASH || !cfg_int("resolucion", "activar", 0))
        return;
    g_w = cfg_int("resolucion", "ancho", 1280);
    g_h = cfg_int("resolucion", "alto", 768);
    if (g_w < MIN_W || g_h < 600 || g_w > MAX_W || g_h > MAX_H || g_w % 8 || g_w * g_h < MIN_W * MIN_H) {
        log_printf("RECHAZADO resolución %dx%d: ancho %d–%d (múltiplo de 8), alto 600–%d y área >= 1024x768",
                   g_w, g_h, MIN_W, MAX_W, MAX_H);
        return;
    }
    /* Comprobar todo antes de escribir nada: o se aplica entero o no se aplica */
    static const uint8_t mode3[12] = {0x00, 0x04, 0, 0, 0x00, 0x03, 0, 0, 0x08, 0, 0, 0};
    static const uint8_t layout[] = {0x66, 0xB8, 0x00, 0x03, 0x66, 0xC7, 0x05, 0x60, 0x1E, 0x8F, 0x00, 0x00, 0x04};
    static const uint8_t init[] = {0x68, 0x00, 0x00, 0x0C, 0x00, 0x66, 0xC7, 0x05, 0x60, 0x1E, 0x8F, 0x00,
                                   0x00, 0x04, 0x66, 0xC7, 0x05, 0x62, 0x1E, 0x8F, 0x00, 0x00, 0x03};
    static const uint8_t hudcall[] = {0x68, 0x08, 0x8C, 0x45, 0x00, 0xE8, 0xE0, 0x06, 0x00, 0x00};  /* push "m1024.pcx"; call */
    if (memcmp((void *)0x457574, mode3, sizeof mode3) || memcmp((void *)0x428A83, layout, sizeof layout) ||
        memcmp((void *)0x4154BC, init, sizeof init) || memcmp((void *)0x428C76, hudcall, sizeof hudcall)) {
        log_printf("RECHAZADO resolución: el código no coincide con el CLASH.EXE conocido");
        return;
    }
    imm32(0x457574, 1024, (uint32_t)g_w, "tabla de modos: ancho del modo 3");
    imm32(0x457578, 768, (uint32_t)g_h, "tabla de modos: alto del modo 3");
    imm16(0x428A85, 768, (uint16_t)g_h, "apply_mode_layout: alto del modo 3");
    imm16(0x428A8E, 1024, (uint16_t)g_w, "apply_mode_layout: ancho del modo 3");
    imm32(0x4154BD, 0xC0000, (uint32_t)(g_w * g_h), "búfer de dibujo");
    imm16(0x4154C8, 1024, (uint16_t)g_w, "ancho de los búferes");
    imm16(0x4154D1, 768, (uint16_t)g_h, "alto de los búferes");
    int32_t rel = (int32_t)((uintptr_t)hud_pcx_load - (0x428C7B + 5));
    int32_t old = 0x6E0;
    patch_bytes(0x428C7C, &old, &rel, 4, "carga del HUD M1024.PCX");
    log_printf("resolución del modo 1024 cambiada a %dx%d", g_w, g_h);
}
