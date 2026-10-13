/* Avisos breves en pantalla ("VELOCIDAD X2").
 *
 * surface_flip (CLASH 0x414C90, SPACE 0x40D670) es la única función que hace Flip de la superficie primaria;
 * se sustituye entera por osd_flip, que dibuja el aviso en el back buffer (8 bpp) y luego hace el mismo
 * Flip con reintento si la superficie se perdió. La fuente es propia (5×7) para no depender del estado de
 * las fuentes del juego, y los colores se eligen de la paleta activa (el más claro y el más oscuro).
 */
#include "scenh.h"
#include <ddraw.h>
#include <string.h>

static char g_text[48];
static DWORD g_until;

/* 5×7: cada carácter son 7 filas de 5 bits (bit 4 = columna izquierda). */
static const struct { char c; uint8_t rows[7]; } FONT[] = {
    {'0', {0x0E, 0x11, 0x13, 0x15, 0x19, 0x11, 0x0E}}, {'1', {0x04, 0x0C, 0x04, 0x04, 0x04, 0x04, 0x0E}},
    {'2', {0x0E, 0x11, 0x01, 0x02, 0x04, 0x08, 0x1F}}, {'3', {0x1F, 0x02, 0x04, 0x02, 0x01, 0x11, 0x0E}},
    {'4', {0x02, 0x06, 0x0A, 0x12, 0x1F, 0x02, 0x02}}, {'5', {0x1F, 0x10, 0x1E, 0x01, 0x01, 0x11, 0x0E}},
    {'6', {0x06, 0x08, 0x10, 0x1E, 0x11, 0x11, 0x0E}}, {'7', {0x1F, 0x01, 0x02, 0x04, 0x08, 0x08, 0x08}},
    {'8', {0x0E, 0x11, 0x11, 0x0E, 0x11, 0x11, 0x0E}}, {'9', {0x0E, 0x11, 0x11, 0x0F, 0x01, 0x02, 0x0C}},
    {'A', {0x0E, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11}}, {'B', {0x1E, 0x11, 0x11, 0x1E, 0x11, 0x11, 0x1E}},
    {'C', {0x0E, 0x11, 0x10, 0x10, 0x10, 0x11, 0x0E}}, {'D', {0x1C, 0x12, 0x11, 0x11, 0x11, 0x12, 0x1C}},
    {'E', {0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x1F}}, {'F', {0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x10}},
    {'G', {0x0E, 0x11, 0x10, 0x17, 0x11, 0x11, 0x0F}}, {'H', {0x11, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11}},
    {'I', {0x0E, 0x04, 0x04, 0x04, 0x04, 0x04, 0x0E}}, {'J', {0x07, 0x02, 0x02, 0x02, 0x02, 0x12, 0x0C}},
    {'K', {0x11, 0x12, 0x14, 0x18, 0x14, 0x12, 0x11}}, {'L', {0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x1F}},
    {'M', {0x11, 0x1B, 0x15, 0x15, 0x11, 0x11, 0x11}}, {'N', {0x11, 0x11, 0x19, 0x15, 0x13, 0x11, 0x11}},
    {'O', {0x0E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E}}, {'P', {0x1E, 0x11, 0x11, 0x1E, 0x10, 0x10, 0x10}},
    {'Q', {0x0E, 0x11, 0x11, 0x11, 0x15, 0x12, 0x0D}}, {'R', {0x1E, 0x11, 0x11, 0x1E, 0x14, 0x12, 0x11}},
    {'S', {0x0F, 0x10, 0x10, 0x0E, 0x01, 0x01, 0x1E}}, {'T', {0x1F, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04}},
    {'U', {0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E}}, {'V', {0x11, 0x11, 0x11, 0x11, 0x11, 0x0A, 0x04}},
    {'W', {0x11, 0x11, 0x11, 0x15, 0x15, 0x15, 0x0A}}, {'X', {0x11, 0x11, 0x0A, 0x04, 0x0A, 0x11, 0x11}},
    {'Y', {0x11, 0x11, 0x11, 0x0A, 0x04, 0x04, 0x04}}, {'Z', {0x1F, 0x01, 0x02, 0x04, 0x08, 0x10, 0x1F}},
    {',', {0x00, 0x00, 0x00, 0x00, 0x0C, 0x04, 0x08}}, {'.', {0x00, 0x00, 0x00, 0x00, 0x00, 0x0C, 0x0C}},
    {'%', {0x18, 0x19, 0x02, 0x04, 0x08, 0x13, 0x03}}, {':', {0x00, 0x0C, 0x0C, 0x00, 0x0C, 0x0C, 0x00}},
    {'-', {0x00, 0x00, 0x00, 0x1F, 0x00, 0x00, 0x00}},
};

static const uint8_t *glyph(char c)
{
    for (size_t i = 0; i < sizeof FONT / sizeof *FONT; i++)
        if (FONT[i].c == c)
            return FONT[i].rows;
    return NULL;   /* espacio u otro: hueco */
}

static void pick_colors(uint8_t *fg, uint8_t *bg)
{
    *fg = 1;   /* en PALETA.PCX: 1 = blanco, 0 = negro */
    *bg = 0;
    IDirectDrawPalette *pal = g_game->ddpal ? *(IDirectDrawPalette **)g_game->ddpal : NULL;
    PALETTEENTRY e[256];
    if (!pal || IDirectDrawPalette_GetEntries(pal, 0, 0, 256, e) != DD_OK)
        return;
    int best = -1, worst = 1 << 30;
    for (int i = 0; i < 256; i++) {
        int l = e[i].peRed * 3 + e[i].peGreen * 6 + e[i].peBlue;
        if (l > best) { best = l; *fg = (uint8_t)i; }
        if (l < worst) { worst = l; *bg = (uint8_t)i; }
    }
}

static void draw(uint8_t *px, int pitch, int w, int h)
{
    int scale = w >= 1024 ? 3 : 2;
    int len = (int)strlen(g_text);
    int cw = 6 * scale, tw = len * cw, th = 7 * scale;
    int x0 = (w - tw) / 2, y0 = h / 6;
    uint8_t fg, bg;
    pick_colors(&fg, &bg);
    /* recuadro oscuro con margen */
    for (int y = y0 - scale * 2; y < y0 + th + scale * 2; y++)
        for (int x = x0 - scale * 3; x < x0 + tw + scale * 2; x++)
            if (x >= 0 && y >= 0 && x < w && y < h)
                px[y * pitch + x] = bg;
    for (int i = 0; i < len; i++) {
        const uint8_t *g = glyph(g_text[i]);
        if (!g)
            continue;
        for (int r = 0; r < 7; r++)
            for (int c = 0; c < 5; c++)
                if (g[r] & (0x10 >> c))
                    for (int sy = 0; sy < scale; sy++)
                        for (int sx = 0; sx < scale; sx++) {
                            int x = x0 + i * cw + c * scale + sx, y = y0 + r * scale + sy;
                            if (x < w && y < h)
                                px[y * pitch + x] = fg;
                        }
    }
}

static void osd_flip(void)
{
    import_hooks_refresh();
    IDirectDrawSurface *primary = *(IDirectDrawSurface **)g_game->dds_primary;
    IDirectDrawSurface *back = *(IDirectDrawSurface **)g_game->dds_back;
    if (g_text[0] && back) {
        if ((int)(GetTickCount() - g_until) < 0) {
            DDSURFACEDESC d;
            memset(&d, 0, sizeof d);
            d.dwSize = sizeof d;
            if (IDirectDrawSurface_Lock(back, NULL, &d, DDLOCK_WAIT, NULL) == DD_OK) {
                draw((uint8_t *)d.lpSurface, (int)d.lPitch, (int)d.dwWidth, (int)d.dwHeight);
                IDirectDrawSurface_Unlock(back, NULL);
            }
        } else {
            g_text[0] = 0;
        }
    }
    for (;;) {   /* igual que el original: Flip(NULL, 0); si se perdió la superficie, Restore y reintentar */
        HRESULT hr = IDirectDrawSurface_Flip(primary, NULL, 0);
        if (hr != DDERR_SURFACELOST || IDirectDrawSurface_Restore(primary) != DD_OK)
            break;
    }
}

void osd_init(void)
{
    if (!cfg_int("general", "avisos", 1))
        return;
    /* mov eax,[primaria]; push 0; push 0 */
    uint8_t expected[9] = {0xA1, 0, 0, 0, 0, 0x6A, 0x00, 0x6A, 0x00};
    memcpy(expected + 1, &g_game->dds_primary, 4);
    patch_jmp(g_game->surface_flip, expected, sizeof expected, (void *)osd_flip, "surface_flip → avisos");
}

void osd_show(const char *text, DWORD ms)
{
    lstrcpynA(g_text, text, sizeof g_text);
    g_until = GetTickCount() + ms;
}
