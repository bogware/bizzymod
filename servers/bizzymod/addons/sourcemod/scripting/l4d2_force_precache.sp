/**
 * l4d2_force_precache — eliminate mid-round "Late precache of models" hitches.
 *
 * On a heavily-modded L4D2 server, anniversary/rework map scripts (anv_mapfixes.nut
 * etc.) reference props that were NOT in the map BSP's precache list, so the engine
 * loads them ON DEMAND during the round the moment a survivor reaches them — each a
 * frame hitch. Clustered early in a chapter as survivors advance, this reads as a few
 * seconds of "laggy conditions" (player-reported on Bizzy's Dugout, Dark Carnival).
 *
 * This plugin precaches a configured model list during the OnMapStart precache window
 * (i.e. on the loading screen) so those models are already resident and never
 * late-precache mid-round. Precaching a model not used on the current map is harmless
 * (one stringtable slot); the list is small and bounded.
 *
 * Model list: addons/sourcemod/configs/bizzymod_precache.txt (one path per line;
 * '//' comments and blank lines ignored; back-slashes normalised to forward).
 */
#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

#define CFG_NAME "configs/bizzymod_precache.txt"

public Plugin myinfo =
{
    name        = "L4D2 Force Precache",
    author      = "bizzymod",
    description = "Precaches props that otherwise late-precache mid-round, removing hitches",
    version     = "1.0.0",
    url         = "https://github.com/bogware/bizzymod"
};

ArrayList g_Models;
ConVar    g_cvEnabled;

public void OnPluginStart()
{
    g_cvEnabled = CreateConVar("bizzy_precache_enable", "1",
        "Force-precache the configured model list at map start (0 = off).",
        FCVAR_NONE, true, 0.0, true, 1.0);
    g_Models = new ArrayList(ByteCountToCells(PLATFORM_MAX_PATH));
    LoadList();
}

void LoadList()
{
    g_Models.Clear();
    char path[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, path, sizeof path, CFG_NAME);
    File f = OpenFile(path, "r");
    if (f == null)
    {
        LogError("[force_precache] model list not found: %s", path);
        return;
    }
    char line[PLATFORM_MAX_PATH];
    while (f.ReadLine(line, sizeof line))
    {
        TrimString(line);
        ReplaceString(line, sizeof line, "\\", "/");
        if (line[0] == '\0') continue;
        if (line[0] == '/' && line[1] == '/') continue;
        if (StrContains(line, ".mdl") == -1) continue;
        // de-dup
        if (g_Models.FindString(line) == -1)
            g_Models.PushString(line);
    }
    delete f;
    LogMessage("[force_precache] loaded %d models to preload", g_Models.Length);
}

public void OnMapStart()
{
    if (!g_cvEnabled.BoolValue || g_Models == null) return;
    char m[PLATFORM_MAX_PATH];
    int n = g_Models.Length;
    for (int i = 0; i < n; i++)
    {
        g_Models.GetString(i, m, sizeof m);
        PrecacheModel(m, true);
    }
}
