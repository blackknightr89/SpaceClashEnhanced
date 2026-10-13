/* Z2: zoom en caliente con la rueda del ratón (parte planetaria, CLASH.EXE), sin pantalla negra.
 *
 * Niveles: sin resolución panorámica, 1024×768 → 800×600 → 640×480 (los modos 3, 2 y 1 del juego). Con
 * resolución panorámica, tamaños con la misma proporción que la configurada, todos en el modo 3:
 * 1920×1080 → 1600×900 → 1280×720 → 1024×576 (el ancho no baja de 1024, lo que mide el HUD).
 *
 * Cambiar el modo de DirectDraw (SetDisplayMode) hace que cnc-ddraw y Wine reinicien la presentación y
 * la pantalla queda en negro unos instantes. Por eso el modo real queda siempre en el tamaño máximo y el
 * zoom es por software: el juego dibuja al tamaño lógico del nivel (apply_mode_layout con ese ancho/alto)
 * y sus Lock/Unlock (surface_lock 0x414C30, surface_unlock 0x414C80) se redirigen a búferes propios de
 * ese tamaño. Antes de cada Flip el back buffer se escala a la pantalla real ("nítido": copia o mezcla
 * al 50 % entre dos píxeles vecinos, con una tabla de 256×256 hecha con la paleta de la partida); el
 * cursor por software (0x41A5B0) se escala solo en su recuadro. El ratón se escala al revés (lParam de
 * los mensajes y GetCursorPos).
 *
 * La WndProc solo anota el pedido; el cambio se hace entre fotogramas, desde PeekMessage, si la simulación
 * está avanzando (no en menús ni en pausa) y no es multijugador.
 */
#include "scenh.h"
#include <ddraw.h>
#include <mmsystem.h>
#include <string.h>

#define G_VIDEO_MODE    ((volatile int16_t *)0x5C7E3C)
#define G_CAM_X         ((volatile int32_t *)0x694FC4)
#define G_CAM_Y         ((volatile int32_t *)0x694FC8)
#define G_MAP_W         ((volatile int16_t *)0x694FC0)
#define G_MAP_H         ((volatile int16_t *)0x694FC2)
#define G_VIEW_W        ((volatile int16_t *)0x8BD522)
#define G_VIEW_H        ((volatile int16_t *)0x8BE650)
#define G_SCREEN_W      ((volatile int16_t *)0x8F1E60)
#define G_SCREEN_H      ((volatile int16_t *)0x8F1E62)
#define G_MOUSE_X       ((volatile int32_t *)0x729DC4)
#define G_MOUSE_Y       ((volatile int32_t *)0x729DC8)
#define G_TERRAIN_DIRTY ((volatile int32_t *)0x694FD4)
#define G_HWND          (*(HWND *)0x7287F4)
#define G_FRAMEBUF      (*(uint8_t **)0x493214)
#define G_CURSOR_BG     (*(uint8_t **)0x8F1E70)   /* copia del cuadro sin cursor (fondo del cursor) */
#define G_DDS_BACK      (*(IDirectDrawSurface **)0x483BA0)
#define G_DDS_PRIMARY   (*(IDirectDrawSurface **)0x483BA8)
#define G_DDRAW         (*(IDirectDraw **)0x483BA4)
#define G_DDSD          ((DDSURFACEDESC *)0x481DA8)  /* la que usa surface_lock; lpSurface en 0x481DCC */
#define GAME_PALETTE    ((PALETTEENTRY *)0x728880)
#define CURSOR_UNLOCK_RET 0x41A73C                    /* retorno del Unlock del cursor por software */

typedef void(__cdecl *fn0)(void);
typedef void(__cdecl *set_palette_fn)(void *pal);

typedef struct { int idx, w, h; } Level;
static Level g_levels[8];
static int g_nlevels, g_on, g_wide, g_pending = -1;

/* ---- estado del escalado ---- */
static IDirectDrawSurface *g_known_primary;
static int g_surf_w, g_surf_h;                 /* tamaño real de las superficies */
static uint8_t *g_shadow_back, *g_shadow_primary;
static size_t g_shadow_size;
static uint8_t g_blend[256][256];              /* índice más cercano a la mezcla 50 % de dos colores */
static int g_blend_ok;
static int g_last_mx = -1, g_last_my = -1;

static void refresh_surface_size(void)
{
    IDirectDrawSurface *p = G_DDS_PRIMARY;
    if (p == g_known_primary)
        return;
    g_known_primary = p;
    g_surf_w = g_surf_h = 0;
    if (!p)
        return;
    DDSURFACEDESC d;
    memset(&d, 0, sizeof d);
    d.dwSize = sizeof d;
    if (IDirectDrawSurface_GetSurfaceDesc(p, &d) == DD_OK) {
        g_surf_w = (int)d.dwWidth;
        g_surf_h = (int)d.dwHeight;
    }
}

/* El zoom por software está activo si el juego dibuja más chico que las superficies reales. */
static int scaling(void)
{
    if (!g_on)
        return 0;
    refresh_surface_size();
    int w = *G_SCREEN_W, h = *G_SCREEN_H;
    return g_shadow_back && g_surf_w && (w < g_surf_w || h < g_surf_h) && w * h > 0 &&
           (size_t)w * h <= g_shadow_size;
}

static void build_blend(void)
{
    for (int a = 0; a < 256; a++)
        for (int b = a; b < 256; b++) {
            int r = (GAME_PALETTE[a].peRed + GAME_PALETTE[b].peRed) / 2;
            int g = (GAME_PALETTE[a].peGreen + GAME_PALETTE[b].peGreen) / 2;
            int bl = (GAME_PALETTE[a].peBlue + GAME_PALETTE[b].peBlue) / 2;
            int best = a, bd = 1 << 30;
            for (int c = 0; c < 256; c++) {
                int dr = GAME_PALETTE[c].peRed - r, dg = GAME_PALETTE[c].peGreen - g;
                int db = GAME_PALETTE[c].peBlue - bl;
                int dd = dr * dr * 3 + dg * dg * 6 + db * db;
                if (dd < bd) { bd = dd; best = c; }
            }
            g_blend[a][b] = g_blend[b][a] = (uint8_t)best;
        }
    g_blend_ok = 1;
}

/* Mapa de un eje: para cada píxel de destino, el de origen y si se mezcla con el siguiente. */
static int g_map_dw, g_map_sw, g_map_dh, g_map_sh;
static int16_t g_xsrc[4096], g_ysrc[4096];
static uint8_t g_xmix[4096], g_ymix[4096];

static void build_axis(int16_t *src, uint8_t *mix, int dn, int sn)
{
    for (int i = 0; i < dn; i++) {
        int pos = (int)(((2LL * i + 1) * sn * 256 / (2 * dn)) - 128);   /* centro del píxel, en 1/256 */
        if (pos < 0)
            pos = 0;
        int s = pos >> 8, f = pos & 255;
        if (s >= sn - 1) { s = sn - 1; f = 0; }
        if (f > 170) { s++; f = 0; }          /* "nítido": copia salvo cerca de la mitad */
        src[i] = (int16_t)s;
        mix[i] = (uint8_t)(f >= 85);
    }
}

static void ensure_maps(int sw, int sh, int dw, int dh)
{
    if (sw == g_map_sw && sh == g_map_sh && dw == g_map_dw && dh == g_map_dh)
        return;
    build_axis(g_xsrc, g_xmix, dw, sw);
    build_axis(g_ysrc, g_ymix, dh, sh);
    g_map_sw = sw; g_map_sh = sh; g_map_dw = dw; g_map_dh = dh;
}

static void scale_rows(const uint8_t *src, int sw, int sh, uint8_t *dst, int dpitch, int dw, int dh,
                       int x0, int y0, int x1, int y1)
{
    ensure_maps(sw, sh, dw, dh);
    for (int y = y0; y < y1; y++) {
        const uint8_t *r0 = src + (size_t)g_ysrc[y] * sw;
        const uint8_t *r1 = g_ymix[y] ? r0 + sw : r0;
        uint8_t *out = dst + (size_t)y * dpitch;
        for (int x = x0; x < x1; x++) {
            int sx = g_xsrc[x];
            uint8_t a = r0[sx], b = r1[sx];
            if (g_xmix[x]) {
                a = g_blend[a][r0[sx + 1]];
                if (g_ymix[y])
                    b = g_blend[b][r1[sx + 1]];
            }
            out[x] = g_ymix[y] ? g_blend[a][b] : a;
        }
    }
}

static int real_lock(IDirectDrawSurface *s, uint8_t **px, int *pitch)
{
    DDSURFACEDESC d;
    memset(&d, 0, sizeof d);
    d.dwSize = sizeof d;
    HRESULT hr = IDirectDrawSurface_Lock(s, NULL, &d, DDLOCK_WAIT, NULL);
    if (hr == DDERR_SURFACELOST && IDirectDrawSurface_Restore(G_DDS_PRIMARY) == DD_OK)
        hr = IDirectDrawSurface_Lock(s, NULL, &d, DDLOCK_WAIT, NULL);
    if (hr != DD_OK)
        return 0;
    *px = (uint8_t *)d.lpSurface;
    *pitch = (int)d.lPitch;
    return 1;
}

/* Escala src (tamaño lógico) a la superficie real, en el rectángulo de origen [lx0,lx1)×[ly0,ly1). */
static void blit_scaled(IDirectDrawSurface *surf, const uint8_t *src, int lx0, int ly0, int lx1, int ly1)
{
    int sw = *G_SCREEN_W, sh = *G_SCREEN_H, dw = g_surf_w, dh = g_surf_h;
    uint8_t *px;
    int pitch;
    if (!surf || !real_lock(surf, &px, &pitch))
        return;
    if (!g_blend_ok)
        build_blend();
    int x0 = lx0 * dw / sw - 2, y0 = ly0 * dh / sh - 2, x1 = lx1 * dw / sw + 3, y1 = ly1 * dh / sh + 3;
    if (x0 < 0) x0 = 0;
    if (y0 < 0) y0 = 0;
    if (x1 > dw) x1 = dw;
    if (y1 > dh) y1 = dh;
    scale_rows(src, sw, sh, px, pitch, dw, dh, x0, y0, x1, y1);
    IDirectDrawSurface_Unlock(surf, NULL);
}

/* ---- surface_lock / surface_unlock del juego ---- */
static void *__cdecl my_surface_lock(IDirectDrawSurface *s)
{
    if (scaling() && (s == G_DDS_BACK || s == G_DDS_PRIMARY)) {
        void *p = s == G_DDS_BACK ? g_shadow_back : g_shadow_primary;
        G_DDSD->lpSurface = p;
        return p;
    }
    HRESULT hr = IDirectDrawSurface_Lock(s, NULL, G_DDSD, 0, NULL);   /* como el original */
    if (hr == DDERR_SURFACELOST && IDirectDrawSurface_Restore(G_DDS_PRIMARY) == DD_OK)
        hr = IDirectDrawSurface_Lock(s, NULL, G_DDSD, 0, NULL);
    return hr == DD_OK ? G_DDSD->lpSurface : NULL;
}

static void __cdecl my_surface_unlock(IDirectDrawSurface *s)
{
    if (scaling() && (s == G_DDS_BACK || s == G_DDS_PRIMARY)) {
        if (s == G_DDS_PRIMARY) {
            if ((uintptr_t)__builtin_return_address(0) == CURSOR_UNLOCK_RET) {
                /* cursor por software: solo el recuadro de la posición anterior y la actual */
                int mx = *G_MOUSE_X, my = *G_MOUSE_Y;
                int px = g_last_mx < 0 ? mx : g_last_mx, py = g_last_my < 0 ? my : g_last_my;
                blit_scaled(s, g_shadow_primary, (mx < px ? mx : px) - 24, (my < py ? my : py) - 24,
                            (mx > px ? mx : px) + 24, (my > py ? my : py) + 24);
                g_last_mx = mx;
                g_last_my = my;
            } else {
                blit_scaled(s, g_shadow_primary, 0, 0, *G_SCREEN_W, *G_SCREEN_H);
            }
        }
        return;
    }
    IDirectDrawSurface_Unlock(s, NULL);
}

/* Llamada por osd.c antes de cada Flip. */
void zoom_before_flip(void)
{
    if (!scaling())
        return;
    if (!g_blend_ok)
        build_blend();
    blit_scaled(G_DDS_BACK, g_shadow_back, 0, 0, *G_SCREEN_W, *G_SCREEN_H);
    memcpy(g_shadow_primary, g_shadow_back, (size_t)*G_SCREEN_W * *G_SCREEN_H);   /* lo que quedará visible */
}

/* ---- ratón: de la pantalla real al tamaño lógico ---- */
static void to_logical(LONG *x, LONG *y)
{
    if (!scaling())
        return;
    *x = *x * *G_SCREEN_W / g_surf_w;
    *y = *y * *G_SCREEN_H / g_surf_h;
}

LPARAM zoom_translate_mouse(UINT msg, LPARAM lp)
{
    if (msg < WM_MOUSEFIRST || msg > WM_MOUSELAST || msg == WM_MOUSEWHEEL || !scaling())
        return lp;
    LONG x = (short)LOWORD(lp), y = (short)HIWORD(lp);
    to_logical(&x, &y);
    return MAKELPARAM(x, y);
}

static BOOL WINAPI hk_GetCursorPos(LPPOINT p);
static ImportHook g_hk_cursor = {"USER32.dll", "GetCursorPos", (void *)hk_GetCursorPos, 0, 0};
static BOOL WINAPI hk_GetCursorPos(LPPOINT p)
{
    BOOL r = ((BOOL(WINAPI *)(LPPOINT))g_hk_cursor.next)(p);
    if (r && p)
        to_logical(&p->x, &p->y);
    return r;
}

/* ---- niveles y cambio ---- */
static int simulation_running(void)
{
    DWORD last = *(volatile DWORD *)g_game->last_tick_ms;
    return !*(volatile int *)g_game->paused && timeGetTime() - last < 200 &&
           *(volatile uint8_t *)g_game->game_mode != 4;
}

static int current_level(void)
{
    for (int i = 0; i < g_nlevels; i++)
        if (g_levels[i].idx == *G_VIDEO_MODE && g_levels[i].w == *G_SCREEN_W && g_levels[i].h == *G_SCREEN_H)
            return i;
    return -1;
}

static void clamp_camera(void)
{
    int max_x = *G_MAP_W * 40 - *G_VIEW_W - 1, max_y = *G_MAP_H * 40 - *G_VIEW_H - 1;
    if (*G_CAM_X > max_x)
        *G_CAM_X = max_x;
    if (*G_CAM_Y > max_y)
        *G_CAM_Y = max_y;
    if (*G_CAM_X < 0)
        *G_CAM_X = 0;
    if (*G_CAM_Y < 0)
        *G_CAM_Y = 0;
}

/* Lo mismo que el final de frame_tick: dibujar, copiar al back buffer y a la copia del cursor, Flip. */
static void present_now(void)
{
    ((fn0)0x41DCB0)();                                   /* render_game_view */
    size_t n = (size_t)*G_SCREEN_W * *G_SCREEN_H;
    void *px = my_surface_lock(G_DDS_BACK);
    if (px) {
        memcpy(px, G_FRAMEBUF, n);
        memcpy(G_CURSOR_BG, G_FRAMEBUF, n);
        my_surface_unlock(G_DDS_BACK);
        ((fn0)0x414C90)();                               /* surface_flip */
    }
}

/* Cambia el tamaño lógico; las superficies reales quedan como están (las del nivel 0). */
static int change_level(const Level *lv)
{
    refresh_surface_size();
    if (lv->w > g_surf_w || lv->h > g_surf_h)
        return 0;   /* el juego arrancó la misión en un modo más chico: no se puede ampliar sin cambiar */
    if (g_wide && !resolution_set_mode3(lv->w, lv->h))
        return 0;
    *G_VIDEO_MODE = (int16_t)lv->idx;
    ((fn0)0x428A70)();                                   /* apply_mode_layout: ancho/alto, vista, HUD */
    ((void(__cdecl *)(int, int))0x446890)(lv->w, lv->h); /* tamaño del destino de los blits */
    ((void(__cdecl *)(int, int, int, int))0x446830)(0, 0, lv->w - 1, lv->h - 1);   /* recorte */
    g_last_mx = g_last_my = -1;
    return 1;
}

void zoom_apply_pending(void)
{
    if (g_pending < 0)
        return;
    int target = g_pending;
    g_pending = -1;
    int cur = current_level();
    if (!simulation_running() || target == cur || cur < 0)
        return;
    int cx = *G_CAM_X + *G_VIEW_W / 2, cy = *G_CAM_Y + *G_VIEW_H / 2;   /* mantener el centro */
    if (!change_level(&g_levels[target])) {
        log_printf("zoom: no se pudo pasar a %dx%d", g_levels[target].w, g_levels[target].h);
        return;
    }
    *G_CAM_X = cx - *G_VIEW_W / 2;
    *G_CAM_Y = cy - *G_VIEW_H / 2;
    clamp_camera();
    *G_TERRAIN_DIRTY = 1;
    char msg[32];
    wsprintfA(msg, "ZOOM %dX%d", g_levels[target].w, g_levels[target].h);
    osd_show(msg, 1200);
    present_now();
}

/* Devuelve 1 si consumió el mensaje. Nivel 0 = el más lejano (más grande). */
int zoom_on_message(UINT msg, WPARAM wp)
{
    if (!g_on || msg != WM_MOUSEWHEEL)
        return 0;
    int cur = g_pending >= 0 ? g_pending : current_level();
    if (cur < 0)
        return 1;
    int next = cur + ((short)HIWORD(wp) > 0 ? 1 : -1);   /* rueda hacia adelante = acercar */
    if (next >= 0 && next < g_nlevels)
        g_pending = next;
    return 1;
}

void zoom_init(void)
{
    if (g_game->kind != EXE_CLASH || !cfg_int("zoom", "activar", 1))
        return;
    static const uint8_t lock_head[] = {0x56, 0x8B, 0x74, 0x24, 0x08, 0x6A, 0x00, 0x6A, 0x00};
    static const uint8_t unlock_head[] = {0x8B, 0x44, 0x24, 0x04, 0x6A, 0x00, 0x50, 0x8B, 0x08};
    if (memcmp((void *)0x414C30, lock_head, sizeof lock_head) ||
        memcmp((void *)0x414C80, unlock_head, sizeof unlock_head)) {
        log_printf("RECHAZADO zoom: surface_lock/surface_unlock no coinciden");
        return;
    }
    int W, H;
    if (resolution_max(&W, &H)) {
        /* misma proporción: W, 5/6 W, 4/6 W… (ancho múltiplo de 8, >= 1024) y 1024 al final */
        g_wide = 1;
        for (int k = 6; k >= 1 && g_nlevels < 7; k--) {
            int w = (W * k / 6) & ~7, h = ((int)((int64_t)w * H / W) + 1) & ~1;
            if (w < 1024)
                break;
            g_levels[g_nlevels++] = (Level){3, w, h};
        }
        if (g_levels[g_nlevels - 1].w > 1024)
            g_levels[g_nlevels++] = (Level){3, 1024, ((int)((int64_t)1024 * H / W) + 1) & ~1};
    } else {
        W = 1024;
        H = 768;
        g_levels[0] = (Level){3, 1024, 768};
        g_levels[1] = (Level){2, 800, 600};
        g_levels[2] = (Level){1, 640, 480};
        g_nlevels = 3;
    }
    g_shadow_size = (size_t)W * H;
    g_shadow_back = VirtualAlloc(NULL, g_shadow_size, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
    g_shadow_primary = VirtualAlloc(NULL, g_shadow_size, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
    if (!g_shadow_back || !g_shadow_primary) {
        log_printf("RECHAZADO zoom: sin memoria para los búferes");
        return;
    }
    patch_jmp(0x414C30, lock_head, sizeof lock_head, (void *)my_surface_lock, "zoom: surface_lock");
    patch_jmp(0x414C80, unlock_head, sizeof unlock_head, (void *)my_surface_unlock, "zoom: surface_unlock");
    import_hook_install(&g_hk_cursor);
    g_on = 1;
    char buf[160] = "";
    for (int i = 0; i < g_nlevels; i++)
        wsprintfA(buf + lstrlenA(buf), "%s%dx%d", i ? ", " : "", g_levels[i].w, g_levels[i].h);
    log_printf("ok zoom con la rueda del ratón: %s", buf);
}
