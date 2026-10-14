/* Traspaso CLASH ↔ SPACE sin segundos de pantalla negra (CLASH.EXE y SPACE.EXE).
 *
 * Al fijar un modo, cnc-ddraw llama a ChangeDisplaySettingsA aunque el modo pedido sea el que ya tiene la
 * pantalla (con width=0/height=0 pide siempre el tamaño del escritorio). Wine difunde entonces
 * WM_DISPLAYCHANGE a todas las ventanas con SendMessageTimeout (2 s por ventana). Al terminar una misión,
 * CLASH.EXE lanza SPACE.EXE y se queda esperándolo (Sleep(2000) + _cwait en 0x416DE0) sin atender
 * mensajes: sus ventanas agotan el plazo una por una y SPACE.EXE queda ~6 s en negro antes de la pantalla
 * de ascenso. Lo mismo al revés, al pasar del mapa estelar a una misión.
 * Aquí se intercepta ChangeDisplaySettingsA en la IAT de ddraw.dll: si el modo pedido ya es el actual
 * (incluido ChangeDisplaySettingsA(NULL, 0), "volver al modo del registro", que es la llamada lenta al
 * arrancar SPACE.EXE), no hay nada que cambiar y se devuelve éxito sin difundir nada; si no, se llama a la
 * función real.
 */
#include "scenh.h"

typedef LONG(WINAPI *cds_fn)(DEVMODEA *, DWORD);
typedef BOOL(WINAPI *eds_fn)(LPCSTR, DWORD, DEVMODEA *);
static cds_fn g_real_cds;
static eds_fn g_real_eds;   /* el de user32: cnc-ddraw engancha EnumDisplaySettingsA en todos los módulos
                             * (también en esta DLL) y devuelve el modo emulado del juego, no el real */

/* El modo pedido (NULL = el del registro) coincide con el actual en lo que especifica. */
static int same_as_current(const DEVMODEA *dm)
{
    DEVMODEA cur = {.dmSize = sizeof cur}, reg = {.dmSize = sizeof reg};
    if (!g_real_eds(NULL, ENUM_CURRENT_SETTINGS, &cur))
        return 0;
    if (!dm) {   /* NULL = volver al modo del registro */
        if (!g_real_eds(NULL, ENUM_REGISTRY_SETTINGS, &reg))
            return 0;
        reg.dmFields = DM_PELSWIDTH | DM_PELSHEIGHT | DM_BITSPERPEL;
        dm = &reg;
    }
    DWORD f = dm->dmFields;
    if ((f & DM_POSITION) || (f & DM_DISPLAYORIENTATION))
        return 0;
    return (!(f & DM_PELSWIDTH) || dm->dmPelsWidth == cur.dmPelsWidth) &&
           (!(f & DM_PELSHEIGHT) || dm->dmPelsHeight == cur.dmPelsHeight) &&
           (!(f & DM_BITSPERPEL) || dm->dmBitsPerPel == cur.dmBitsPerPel) &&
           (!(f & DM_DISPLAYFREQUENCY) || dm->dmDisplayFrequency <= 1 ||
            dm->dmDisplayFrequency == cur.dmDisplayFrequency);
}

static LONG WINAPI hk_ChangeDisplaySettingsA(DEVMODEA *dm, DWORD flags)
{
    if (!(flags & (CDS_TEST | CDS_UPDATEREGISTRY)) && same_as_current(dm)) {
        static int logged;
        if (!logged++)
            log_printf("ChangeDisplaySettings sin cambio de modo: omitido (sin espera por WM_DISPLAYCHANGE)");
        return DISP_CHANGE_SUCCESSFUL;
    }
    return g_real_cds(dm, flags);
}

void display_init(void)
{
    if (!cfg_int("pantalla", "sin_cambio_de_modo_inutil", 1))
        return;
    HMODULE ddraw = GetModuleHandleA("ddraw.dll");
    g_real_eds = (eds_fn)GetProcAddress(GetModuleHandleA("user32.dll"), "EnumDisplaySettingsA");
    if (!g_real_eds)
        return;
    g_real_cds = (cds_fn)hook_module_import(ddraw, "USER32.dll", "ChangeDisplaySettingsA",
                                            (void *)hk_ChangeDisplaySettingsA);
}
