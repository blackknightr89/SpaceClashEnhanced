/* scenh — runtime de mejoras de Space Clash (etapa 3 del REMASTER).
 *
 * Se carga dentro de CLASH.EXE y SPACE.EXE porque el instalador renombra su import "GDI32.dll" a
 * "SCENH.dll" (mismo largo); esta DLL reenvía GetStockObject a gdi32 (ver scenh.def). Todo lo demás se
 * hace en memoria, comprobando antes los bytes originales: si algo no coincide, esa mejora no se aplica
 * y queda registrado en scenh.log. Direcciones y evidencias: re/symbols.csv y docs/re/.
 */
#ifndef SCENH_H
#define SCENH_H

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdint.h>

typedef enum { EXE_UNKNOWN, EXE_CLASH, EXE_SPACE } ExeKind;

/* Direcciones que dependen del EXE (VA, ImageBase 0x400000). */
typedef struct {
    ExeKind kind;
    const char *name;
    DWORD timestamp, size_of_image;   /* identificación (cabecera PE del CD español) */
    uintptr_t tick_threshold;         /* imm8 de "cmp reg,0x25" en frame_tick */
    uintptr_t last_tick_ms;           /* DWORD: timeGetTime del último tick */
    uintptr_t paused;                 /* int: pausa (Espacio) */
    uintptr_t game_mode;              /* uint8: 4 = multijugador (0 si no aplica) */
    uintptr_t surface_flip;           /* void surface_flip(void) */
    uintptr_t dds_primary, dds_back;  /* IDirectDrawSurface* globales */
    uintptr_t ddpal;                  /* IDirectDrawPalette* */
} GameInfo;

extern const GameInfo *g_game;
extern char g_dir[MAX_PATH];          /* carpeta del EXE (con barra final) */

/* main.c */
void log_printf(const char *fmt, ...);
int  cfg_int(const char *section, const char *key, int def);
void cfg_set_int(const char *section, const char *key, int value);

/* hooks.c */
int   patch_bytes(uintptr_t addr, const void *expected, const void *repl, size_t n, const char *what);
int   patch_jmp(uintptr_t addr, const void *expected, size_t n, void *target, const char *what);
void *hook_import(const char *dll, const char *func, void *replacement);
typedef struct { const char *dll, *func; void *mine; void **slot; void *next; } ImportHook;
int   import_hook_install(ImportHook *h);
void  import_hooks_refresh(void);

/* speed.c */
void speed_init(void);
int  speed_on_key(HWND h, UINT msg, WPARAM wp);
UINT_PTR WINAPI hk_SetTimer(HWND, UINT_PTR, UINT, TIMERPROC);
BOOL WINAPI hk_KillTimer(HWND, UINT_PTR);
BOOL WINAPI hk_PeekMessageA(LPMSG, HWND, UINT, UINT, UINT);

/* osd.c */
void osd_init(void);
void osd_show(const char *text, DWORD ms);

/* resolution.c */
void resolution_init(void);

/* hud.c */
void hud_init(int wide_w);
int  hud_offset(int screen_w);

/* zoom.c */
void zoom_init(void);
int  zoom_on_message(UINT msg, WPARAM wp);
void zoom_apply_pending(void);

#endif
