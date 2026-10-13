/* Cursor sin parpadeo (CLASH.EXE y SPACE.EXE).
 *
 * El juego arma cada fotograma de la partida sin el cursor, lo copia al back buffer y hace Flip; recién
 * después, en un camino aparte (CLASH 0x41A5B0, SPACE 0x4123C0), dibuja el cursor directamente sobre la
 * superficie visible. Con el DirectDraw de 1999 eso ocurría dentro del mismo refresco; cnc-ddraw y Wine
 * presentan en otro hilo y a veces muestran el fotograma recién volteado todavía sin cursor: parpadea.
 * Aquí se intercepta el Flip de frame_tick (CLASH 0x42C090, SPACE 0x41CCE8) y antes se dibuja el cursor
 * en el back buffer, con la misma función y en la misma posición que usará el camino aparte.
 */
#include "scenh.h"

typedef void *(__cdecl *lock_fn)(void *surface);
typedef void(__cdecl *unlock_fn)(void *surface);
typedef void(__cdecl *flip_fn)(void);
typedef void(__cdecl *draw2_fn)(uintptr_t, uintptr_t);

typedef struct {
    ExeKind kind;
    uintptr_t flip_call, flip, lock, unlock, back;
    uintptr_t draw_cursor;            /* CLASH: 0x41D830(buf, 0); SPACE: 0x404A50(sprite, buf) */
    uintptr_t sprites, type; int type_is_int16;
} CursorSites;

static const CursorSites SITES[] = {
    {EXE_CLASH, 0x42C090, 0x414C90, 0x414C30, 0x414C80, 0x483BA0, 0x41D830, 0, 0, 0},
    {EXE_SPACE, 0x41CCE8, 0x40D670, 0x40D610, 0x40D660, 0x468430, 0x404A50, 0x98A360, 0x47DD04, 0},
};
static const CursorSites *S;

static void __cdecl present_with_cursor(void)
{
    void *back = *(void **)S->back;
    uint8_t *px = back ? ((lock_fn)S->lock)(back) : NULL;
    if (px) {
        if (S->kind == EXE_CLASH) {
            ((draw2_fn)S->draw_cursor)((uintptr_t)px, 0);
        } else {
            int type = S->type_is_int16 ? *(int16_t *)S->type : *(int8_t *)S->type;
            ((draw2_fn)S->draw_cursor)(S->sprites + (uintptr_t)type * 0x18, (uintptr_t)px);
        }
        ((unlock_fn)S->unlock)(back);
    }
    ((flip_fn)S->flip)();
}

void cursor_init(void)
{
    if (!cfg_int("cursor", "sin_parpadeo", 1))
        return;
    for (size_t i = 0; i < sizeof SITES / sizeof *SITES; i++)
        if (SITES[i].kind == g_game->kind)
            S = &SITES[i];
    if (!S)
        return;
    const uint8_t *p = (const uint8_t *)S->flip_call;
    if (p[0] != 0xE8 || S->flip_call + 5 + *(const int32_t *)(p + 1) != S->flip) {
        log_printf("RECHAZADO cursor sin parpadeo: la llamada a Flip no coincide");
        return;
    }
    int32_t old = *(const int32_t *)(p + 1);
    int32_t rel = (int32_t)((uintptr_t)present_with_cursor - (S->flip_call + 5));
    patch_bytes(S->flip_call + 1, &old, &rel, 4, "cursor sin parpadeo (Flip de frame_tick)");
}
