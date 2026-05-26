/**
 * bizzymod-stats — Left 4 Dead 1 / Left 4 Dead 2 player statistics plugin.
 *
 * Entry point. The plugin is split across files under the bizzymod_stats
 * subdirectory and orchestrated from here. Each module registers its own
 * ConVars, event hooks, and commands in its Bizzy_On*Init() callback.
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <clientprefs>
#undef REQUIRE_PLUGIN
#include <adminmenu>

#include "include/bizzymod_stats.inc"

// -----------------------------------------------------------------------------
// Global state. Modules read/write via the `g_` accessors below.
// -----------------------------------------------------------------------------

Database g_DB;
TopMenu  g_AdminMenu;
Game     g_Game = Game_Unknown;
GameMode g_CurrentMode = GameMode_Unknown;
Difficulty g_CurrentDifficulty = Difficulty_Unknown;

int      g_ServerId = 0;
char     g_ServerKey[33];
char     g_ServerName[128];
char     g_CurrentMap[128];
int      g_CurrentMapId = 0;

ClientState g_Clients[MAXPLAYERS + 1];

// Cached cvars - hot path
ConVar g_cvEnabled;
ConVar g_cvAnnounceJoin;
ConVar g_cvAnnounceRank;        // declared for future "rank changed" announcer; not yet read
ConVar g_cvFFireMode;
ConVar g_cvFFireMultiplier;
ConVar g_cvFFireCooldown;
ConVar g_cvDifficultyMultiplier;
ConVar g_cvEnableNegativeScore;
ConVar g_cvLogEvents;
ConVar g_cvBotMultiplier;       // declared for future bot-related penalty scaling

// -----------------------------------------------------------------------------
// Module sources. Order matters only for compile-time symbol resolution;
// runtime init ordering is controlled by OnPluginStart().
// -----------------------------------------------------------------------------

#include "bizzymod_stats/util.sp"
#include "bizzymod_stats/config.sp"
#include "bizzymod_stats/database.sp"
#include "bizzymod_stats/identity.sp"
#include "bizzymod_stats/combat.sp"
#include "bizzymod_stats/session.sp"
#include "bizzymod_stats/scoring.sp"
#include "bizzymod_stats/awards.sp"
#include "bizzymod_stats/weapons.sp"
#include "bizzymod_stats/tank_witch.sp"
#include "bizzymod_stats/coordination.sp"
#include "bizzymod_stats/movement.sp"
#include "bizzymod_stats/events.sp"
#include "bizzymod_stats/timedmaps.sp"
#include "bizzymod_stats/versus.sp"
#include "bizzymod_stats/rankvote.sp"
#include "bizzymod_stats/motd.sp"
#include "bizzymod_stats/commands.sp"

// -----------------------------------------------------------------------------
// SourceMod plugin metadata
// -----------------------------------------------------------------------------

public Plugin myinfo =
{
    name        = BIZZY_PLUGIN_NAME,
    author      = "bizzymod-stats contributors",
    description = "Modern player statistics and ranking for L4D1 / L4D2",
    version     = BIZZY_PLUGIN_VERSION,
    url         = BIZZY_PLUGIN_URL,
};

// -----------------------------------------------------------------------------
// Plugin lifecycle
// -----------------------------------------------------------------------------

public void OnPluginStart()
{
    // Detect game; bail early if not L4D1 / L4D2 so we never half-init.
    char folder[32];
    GetGameFolderName(folder, sizeof folder);
    if (StrEqual(folder, "left4dead"))
        g_Game = Game_L4D1;
    else if (StrEqual(folder, "left4dead2"))
        g_Game = Game_L4D2;
    else
    {
        SetFailState("bizzymod-stats: unsupported game '%s' (L4D1/L4D2 only)", folder);
    }

    LoadTranslations("bizzymod_stats.phrases");
    LoadTranslations("common.phrases");

    Bizzy_OnConfigInit();
    AutoExecConfig(true, "bizzymod_stats");

    // Database is async — every dependent module schedules its work in
    // OnDatabaseReady() (called from database.sp once the connection is
    // alive AND the server row has been resolved).
    Bizzy_OnDatabaseInit();

    Bizzy_OnSessionInit();
    Bizzy_OnAwardsInit();
    Bizzy_OnEventsInit();
    Bizzy_OnTimedMapsInit();
    Bizzy_OnTankWitchInit();
    Bizzy_OnCoordinationInit();
    Bizzy_OnMovementInit();
    Bizzy_OnVersusInit();
    Bizzy_OnRankvoteInit();
    Bizzy_OnMotdInit();
    Bizzy_OnCommandsInit();

    // Admin menu (optional dep on adminmenu)
    TopMenu menu = GetAdminTopMenu();
    if (menu != null)
        OnAdminMenuReady(menu);
}

public void OnAllPluginsLoaded()
{
    // Re-detect mode on load in case the plugin was hot-reloaded mid-round.
    Bizzy_DetectGameMode();
}

public void OnMapStart()
{
    GetCurrentMap(g_CurrentMap, sizeof g_CurrentMap);
    Bizzy_DetectGameMode();
    Bizzy_OnMapStart();      // sessions module: closes opens, schedules new ones
    Bizzy_Versus_OnMapStart(); // versus module: open/continue/close match
    Bizzy_Events_ResetSaferoomOrdinal();
    // Reset "untouchable map" flag for all in-game survivors
    for (int i = 1; i <= MaxClients; i++)
        if (Bizzy_IsValidPlayer(i)) g_Clients[i].untouchableMapRunning = 1;
}

public void OnMapEnd()
{
    Bizzy_OnMapEnd();     // sessions module: flush all live sessions
}

public void OnClientConnected(int client)
{
    Bizzy_ResetClientState(client);
}

public void OnClientPostAdminCheck(int client)
{
    if (IsFakeClient(client))
        return;
    Bizzy_BeginClientSession(client);
}

public void OnClientDisconnect(int client)
{
    if (IsFakeClient(client) || !g_Clients[client].inUse)
        return;
    Bizzy_EndClientSession(client);
}

public void OnAdminMenuReady(Handle topmenu)
{
    TopMenu menu = view_as<TopMenu>(topmenu);
    if (menu == g_AdminMenu)
        return;
    g_AdminMenu = menu;
    Bizzy_RegisterAdminMenu(menu);
}
