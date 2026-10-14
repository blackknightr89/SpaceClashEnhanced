/* Z2/Z3: zoom en caliente con la rueda del ratón, sin pantalla negra: parte planetaria (CLASH.EXE) y mapa
 * estelar (SPACE.EXE).
 *
 * Niveles: sin resolución panorámica, 1024×768 → 800×600 → 640×480 (los modos 3, 2 y 1 del juego). Con
 * resolución panorámica, tamaños con la misma proporción que la configurada, todos en el modo 3:
 * 1920×1080 → 1600×900 → 1280×720 → 1024×576 (el ancho no baja de 1024, lo que mide el HUD).
 *
 * Cambiar el modo de DirectDraw (SetDisplayMode) hace que cnc-ddraw y Wine reinicien la presentación y
 * la pantalla queda en negro unos instantes. Por eso el modo real queda siempre en el tamaño máximo y el
 * zoom es por software: el juego dibuja al tamaño lógico del nivel (su maquetación con ese ancho/alto)
 * y sus Lock/Unlock (surface_lock, surface_unlock) se redirigen a búferes propios de ese tamaño. Antes de
 * cada Flip el back buffer se escala a la pantalla real ("nítido": copia o mezcla al 50 % entre dos
 * píxeles vecinos, con una tabla de 256×256 hecha con la paleta de la partida); el cursor por software
 * se escala solo en su recuadro. El ratón se escala al revés (lParam de los mensajes y GetCursorPos).
 *
 * La WndProc solo anota el pedido; el cambio se hace entre fotogramas, desde PeekMessage, si la simulación
 * está avanzando (no en menús ni en pausa) y no es multijugador. Si el juego cambia de modo de verdad
 * (ddraw_set_mode: pantallas de 640×480, siguiente misión), el modo 3 vuelve antes al tamaño máximo, para
 * que la maquetación coincida con las superficies que se crean.
 */
#include "scenh.h"
#include <ddraw.h>
#include <mmsystem.h>
#include <string.h>

typedef struct {
    ExeKind kind;
    uintptr_t video_mode;                     /* int16: índice de modo (1–3) */
    uintptr_t screen_w, screen_h, view_w, view_h;   /* int16 */
    uintptr_t mouse_x, mouse_y;               /* int32 */
    uintptr_t ddraw, ddsd, palette;           /* IDirectDraw*, DDSURFACEDESC de surface_lock, paleta */
    uintptr_t lock, unlock, cursor_unlock_ret;   /* surface_lock/unlock; retorno del Unlock del cursor */
    uintptr_t layout, set_target, set_clip, set_palette, set_mode;
    uintptr_t busy;                           /* int32 != 0: pantalla modal (0 si no aplica) */
} ZoomSites;

static const ZoomSites SITES[] = {
    {EXE_CLASH, 0x5C7E3C, 0x8F1E60, 0x8F1E62, 0x8BD522, 0x8BE650, 0x729DC4, 0x729DC8,
     0x483BA4, 0x481DA8, 0x728880, 0x414C30, 0x414C80, 0x41A73C,
     0x428A70, 0x446890, 0x446830, 0x414BD0, 0x414A50, 0},
    {EXE_SPACE, 0x5C16E6, 0x817090, 0x817092, 0x807180, 0x807188, 0x73F9C4, 0x73F9C8,
     0x468434, 0x467668, 0x69A200, 0x40D610, 0x40D660, 0x412554,
     0x420B00, 0x430470, 0x430410, 0x40D5B0, 0x40D430, 0x98A344},
};
static const ZoomSites *S;

#define I16(a) (*(volatile int16_t *)(a))
#define I32(a) (*(volatile int32_t *)(a))
#define G_VIDEO_MODE    I16(S->video_mode)
#define G_SCREEN_W      I16(S->screen_w)
#define G_SCREEN_H      I16(S->screen_h)
#define G_VIEW_W        I16(S->view_w)
#define G_VIEW_H        I16(S->view_h)
#define G_DDS_BACK      (*(IDirectDrawSurface **)g_game->dds_back)
#define G_DDS_PRIMARY   (*(IDirectDrawSurface **)g_game->dds_primary)
#define G_DDRAW         (*(IDirectDraw **)S->ddraw)
#define G_DDSD          ((DDSURFACEDESC *)S->ddsd)
#define GAME_PALETTE    ((PALETTEENTRY *)S->palette)

/* CLASH: cámara del mapa planetario y lo que usa clash_present_now */
#define CL_CAM_X        I32(0x694FC4)
#define CL_CAM_Y        I32(0x694FC8)
#define CL_MAP_W        I16(0x694FC0)
#define CL_MAP_H        I16(0x694FC2)
#define CL_TERRAIN_DIRTY I32(0x694FD4)
#define CL_FRAMEBUF     (*(uint8_t **)0x493214)
#define CL_CURSOR_BG    (*(uint8_t **)0x8F1E70)   /* copia del cuadro sin cursor (fondo del cursor) */

/* SPACE: cámara galáctica y su rutina de desplazamiento (límites, paralaje, minimapa) */
#define SP_CAM_X        I32(0x773B24)
#define SP_CAM_Y        I32(0x773B28)
#define SP_HUD_SHOWN    I32(0x73F9D8)             /* F9 lo alterna */
#define SP_MOUSE_ZONE   (*(volatile uint8_t *)0x73F9C0)   /* 4/5: ratón sobre el minimapa o la carta grande */
#define SP_TICK_PENDING I32(0x467970)
#define SP_SCROLL_HUD   0x41AEB0                  /* void (int forzar): con el HUD visible */
#define SP_SCROLL_FULL  0x41B3B0                  /* void (void): sin HUD */

typedef void(__cdecl *fn0)(void);
typedef void(__cdecl *set_palette_fn)(void *pal);

typedef struct { int idx, w, h; } Level;
static Level g_levels[8];
static int g_nlevels, g_on, g_wide, g_pending = -1;

/* ---- estado del escalado ---- */
static int g_surf_w, g_surf_h;                 /* tamaño real de las superficies */
static uint8_t *g_shadow_back, *g_shadow_primary;
static size_t g_shadow_size;
static uint8_t g_blend[256][256];              /* índice más cercano a la mezcla 50 % de dos colores */
static int g_blend_ok;
static int g_last_mx = -1, g_last_my = -1;

/* Tamaño real de la primaria. Se consulta siempre: el juego libera y vuelve a crear las superficies en
 * cada cambio de modo y la nueva puede quedar en la misma dirección que la anterior (no sirve guardarlo
 * según el puntero). */
static void refresh_surface_size(void)
{
    IDirectDrawSurface *p = G_DDS_PRIMARY;
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
    int w = G_SCREEN_W, h = G_SCREEN_H;
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
    int sw = G_SCREEN_W, sh = G_SCREEN_H, dw = g_surf_w, dh = g_surf_h;
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
        /* medidas lógicas: SPACE con P4 copia dwHeight × lPitch bytes a la superficie bloqueada */
        G_DDSD->lpSurface = p;
        G_DDSD->dwWidth = (DWORD)G_SCREEN_W;
        G_DDSD->dwHeight = (DWORD)G_SCREEN_H;
        G_DDSD->lPitch = G_SCREEN_W;
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
            if ((uintptr_t)__builtin_return_address(0) == S->cursor_unlock_ret) {
                /* cursor por software: solo el recuadro de la posición anterior y la actual */
                int mx = I32(S->mouse_x), my = I32(S->mouse_y);
                int px = g_last_mx < 0 ? mx : g_last_mx, py = g_last_my < 0 ? my : g_last_my;
                blit_scaled(s, g_shadow_primary, (mx < px ? mx : px) - 24, (my < py ? my : py) - 24,
                            (mx > px ? mx : px) + 24, (my > py ? my : py) + 24);
                g_last_mx = mx;
                g_last_my = my;
            } else {
                blit_scaled(s, g_shadow_primary, 0, 0, G_SCREEN_W, G_SCREEN_H);
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
    blit_scaled(G_DDS_BACK, g_shadow_back, 0, 0, G_SCREEN_W, G_SCREEN_H);
    memcpy(g_shadow_primary, g_shadow_back, (size_t)G_SCREEN_W * G_SCREEN_H);   /* lo que quedará visible */
}

/* ---- ratón: de la pantalla real al tamaño lógico ---- */
static void to_logical(LONG *x, LONG *y)
{
    if (!scaling())
        return;
    *x = *x * G_SCREEN_W / g_surf_w;
    *y = *y * G_SCREEN_H / g_surf_h;
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
    if (*(volatile int *)g_game->paused || timeGetTime() - last >= 200)
        return 0;
    if (g_game->game_mode && *(volatile uint8_t *)g_game->game_mode == 4)   /* multijugador */
        return 0;
    return !S->busy || !I32(S->busy);
}

static int current_level(void)
{
    for (int i = 0; i < g_nlevels; i++)
        if (g_levels[i].idx == G_VIDEO_MODE && g_levels[i].w == G_SCREEN_W && g_levels[i].h == G_SCREEN_H)
            return i;
    return -1;
}

/* Centro de la vista en coordenadas del mapa */
static void view_center(int *cx, int *cy)
{
    int x = S->kind == EXE_CLASH ? CL_CAM_X : SP_CAM_X, y = S->kind == EXE_CLASH ? CL_CAM_Y : SP_CAM_Y;
    *cx = x + G_VIEW_W / 2;
    *cy = y + G_VIEW_H / 2;
}

static void clash_clamp_camera(void)
{
    int max_x = CL_MAP_W * 40 - G_VIEW_W - 1, max_y = CL_MAP_H * 40 - G_VIEW_H - 1;
    if (CL_CAM_X > max_x)
        CL_CAM_X = max_x;
    if (CL_CAM_Y > max_y)
        CL_CAM_Y = max_y;
    if (CL_CAM_X < 0)
        CL_CAM_X = 0;
    if (CL_CAM_Y < 0)
        CL_CAM_Y = 0;
}

/* CLASH: lo mismo que el final de frame_tick: dibujar, copiar al back buffer y a la copia del cursor, Flip. */
static void clash_present_now(void)
{
    ((fn0)0x41DCB0)();                                   /* render_game_view */
    size_t n = (size_t)G_SCREEN_W * G_SCREEN_H;
    void *px = my_surface_lock(G_DDS_BACK);
    if (px) {
        memcpy(px, CL_FRAMEBUF, n);
        memcpy(CL_CURSOR_BG, CL_FRAMEBUF, n);
        my_surface_unlock(G_DDS_BACK);
        ((fn0)g_game->surface_flip)();
    }
}

/* Lleva la cámara al centro (cx, cy) con la vista nueva y presenta el fotograma. */
static void recenter(int cx, int cy)
{
    if (S->kind == EXE_CLASH) {
        CL_CAM_X = cx - G_VIEW_W / 2;
        CL_CAM_Y = cy - G_VIEW_H / 2;
        clash_clamp_camera();
        CL_TERRAIN_DIRTY = 1;
        clash_present_now();
        return;
    }
    /* SPACE: la rutina de desplazamiento del juego limita la cámara a la galaxia y mueve el paralaje, el
     * fondo y el recuadro del minimapa. Con el ratón sobre el minimapa o la carta grande (zona 4/5),
     * forzarla centraría la vista en el ratón: se llama como si estuviera fuera. */
    SP_CAM_X = cx - G_VIEW_W / 2;
    SP_CAM_Y = cy - G_VIEW_H / 2;
    if (SP_HUD_SHOWN) {
        uint8_t zone = SP_MOUSE_ZONE;
        SP_MOUSE_ZONE = 0;
        ((void(__cdecl *)(int))SP_SCROLL_HUD)(1);
        SP_MOUSE_ZONE = zone;
    } else {
        ((fn0)SP_SCROLL_FULL)();
    }
    SP_TICK_PENDING = 1;   /* el próximo frame_tick dibuja y presenta ya, sin esperar al reloj */
}

/* Respaldo: llevar las superficies reales al tamaño máximo sin destruir el objeto DirectDraw (como
 * ddraw_set_mode, pero conservando IDirectDraw y la paleta). Solo hace falta si la partida arrancó en un
 * modo más chico; puede pasar por negro una vez. */
static int grow_surfaces(int w, int h)
{
    IDirectDraw *dd = G_DDRAW;
    if (!dd)
        return 0;
    if (G_DDS_PRIMARY) {
        IDirectDrawSurface_Release(G_DDS_PRIMARY);
        G_DDS_PRIMARY = NULL;
        G_DDS_BACK = NULL;
    }
    if (IDirectDraw_SetDisplayMode(dd, (DWORD)w, (DWORD)h, 8) != DD_OK)
        return 0;
    DDSURFACEDESC d;
    memset(&d, 0, sizeof d);
    d.dwSize = sizeof d;
    d.dwFlags = DDSD_CAPS | DDSD_BACKBUFFERCOUNT;
    d.ddsCaps.dwCaps = DDSCAPS_PRIMARYSURFACE | DDSCAPS_FLIP | DDSCAPS_COMPLEX;
    d.dwBackBufferCount = 2;
    IDirectDrawSurface *primary = NULL, *back = NULL;
    if (IDirectDraw_CreateSurface(dd, &d, &primary, NULL) != DD_OK)
        return 0;
    DDSCAPS caps = {DDSCAPS_BACKBUFFER};
    if (IDirectDrawSurface_GetAttachedSurface(primary, &caps, &back) != DD_OK) {
        IDirectDrawSurface_Release(primary);
        return 0;
    }
    G_DDS_PRIMARY = primary;
    G_DDS_BACK = back;
    ((void(__cdecl *)(void *))S->set_palette)(GAME_PALETTE);   /* paleta en la primaria nueva */
    log_printf("zoom: superficies ampliadas a %dx%d", w, h);
    return 1;
}

/* Cambia el tamaño lógico; las superficies reales quedan como están (las del nivel 0). */
static int change_level(const Level *lv)
{
    refresh_surface_size();
    if (lv->w > g_surf_w || lv->h > g_surf_h) {
        /* la partida arrancó en un modo más chico que el máximo: ampliar una vez las superficies */
        log_printf("zoom: la pantalla mide %dx%d, menos que %dx%d", g_surf_w, g_surf_h, lv->w, lv->h);
        if (!grow_surfaces(g_levels[0].w, g_levels[0].h))
            return 0;
        refresh_surface_size();
    }
    if (g_wide && !resolution_set_mode3(lv->w, lv->h))
        return 0;
    G_VIDEO_MODE = (int16_t)lv->idx;
    ((fn0)S->layout)();                                  /* maquetación: ancho/alto, vista, HUD */
    ((void(__cdecl *)(int, int))S->set_target)(lv->w, lv->h);   /* tamaño del destino de los blits */
    ((void(__cdecl *)(int, int, int, int))S->set_clip)(0, 0, lv->w - 1, lv->h - 1);   /* recorte */
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
    int cx, cy;
    view_center(&cx, &cy);   /* mantener el centro */
    if (!change_level(&g_levels[target])) {
        log_printf("zoom: no se pudo pasar a %dx%d", g_levels[target].w, g_levels[target].h);
        return;
    }
    char msg[32];
    wsprintfA(msg, "ZOOM %dX%d", g_levels[target].w, g_levels[target].h);
    osd_show(msg, 1200);
    recenter(cx, cy);
}

/* ddraw_set_mode: un cambio de modo real crea superficies con el tamaño de la tabla de modos; con la
 * resolución panorámica el modo 3 vuelve antes al máximo para que la maquetación coincida. */
typedef int(__cdecl *set_mode_fn)(int idx, HWND hwnd);
static set_mode_fn g_set_mode_orig;

static int __cdecl my_set_mode(int idx, HWND hwnd)
{
    if (g_wide)
        resolution_set_mode3(g_levels[0].w, g_levels[0].h);
    return g_set_mode_orig(idx, hwnd);
}

static void hook_set_mode(void)
{
    /* sub esp,0x404; push esi; push edi: 8 bytes que se copian tal cual a la trampa */
    static const uint8_t head[] = {0x81, 0xEC, 0x04, 0x04, 0x00, 0x00, 0x56, 0x57};
    uint8_t *t = VirtualAlloc(NULL, 16, MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE);
    if (!t || memcmp((void *)S->set_mode, head, sizeof head)) {
        log_printf("RECHAZADO zoom: ddraw_set_mode no coincide");
        return;
    }
    memcpy(t, head, sizeof head);
    t[8] = 0xE9;
    int32_t rel = (int32_t)((S->set_mode + sizeof head) - ((uintptr_t)t + 13));
    memcpy(t + 9, &rel, 4);
    g_set_mode_orig = (set_mode_fn)t;
    patch_jmp(S->set_mode, head, sizeof head, (void *)my_set_mode, "zoom: ddraw_set_mode");
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
    if (!cfg_int("zoom", "activar", 1))
        return;
    for (size_t i = 0; i < sizeof SITES / sizeof *SITES; i++)
        if (SITES[i].kind == g_game->kind)
            S = &SITES[i];
    if (!S)
        return;
    static const uint8_t lock_head[] = {0x56, 0x8B, 0x74, 0x24, 0x08, 0x6A, 0x00, 0x6A, 0x00};
    static const uint8_t unlock_head[] = {0x8B, 0x44, 0x24, 0x04, 0x6A, 0x00, 0x50, 0x8B, 0x08};
    if (memcmp((void *)S->lock, lock_head, sizeof lock_head) ||
        memcmp((void *)S->unlock, unlock_head, sizeof unlock_head)) {
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
    patch_jmp(S->lock, lock_head, sizeof lock_head, (void *)my_surface_lock, "zoom: surface_lock");
    patch_jmp(S->unlock, unlock_head, sizeof unlock_head, (void *)my_surface_unlock, "zoom: surface_unlock");
    if (g_wide)
        hook_set_mode();
    import_hook_install(&g_hk_cursor);
    g_on = 1;
    char buf[160] = "";
    for (int i = 0; i < g_nlevels; i++)
        wsprintfA(buf + lstrlenA(buf), "%s%dx%d", i ? ", " : "", g_levels[i].w, g_levels[i].h);
    log_printf("ok zoom con la rueda del ratón: %s", buf);
}
