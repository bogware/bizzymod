#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <left4dhooks>

// [barrymod2 #4] Block ALL witch spawns on finale maps.
// versus_witch_chance_finale 0 is unreliable here because witch_and_tankifier
// force-places the witch each map and has no finale logic. Blocking the engine
// witch-spawn detour catches director, scripted, tankifier and bride witches.
// Scoped to barrymod2 via confogl_plugins.cfg only.

public Plugin myinfo =
{
    name        = "[barrymod2] No Finale Witch",
    author      = "bizzymod",
    description = "Blocks all witch spawns on finale maps",
    version     = "1.0",
    url         = "https://github.com/draxios/bizzymod"
};

public Action L4D_OnSpawnWitch(const float vecPos[3], const float vecAng[3])
{
    if (L4D_IsMissionFinalMap())
        return Plugin_Handled;
    return Plugin_Continue;
}

public Action L4D_OnSpawnWitchBridge(const float vecPos[3], const float vecAng[3])
{
    if (L4D_IsMissionFinalMap())
        return Plugin_Handled;
    return Plugin_Continue;
}
