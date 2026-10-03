#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <left4dhooks>

// [barrymod2 #13] A hunter moving faster than a threshold while pouncing cannot
// be deadstopped by a shove. Below the threshold (or cvar 0) shoves behave
// normally, so slow/setup pounces stay deadstoppable.

#define ZC_HUNTER 3

ConVar g_cvMinSpeed;

public Plugin myinfo =
{
    name = "L4D2 Hunter Fast-Pounce No Deadstop (barrymod2)",
    author = "Bizzymod",
    description = "A hunter moving faster than a threshold while pouncing cannot be deadstopped by a shove.",
    version = "1.0",
    url = "https://github.com/draxios/bizzymod"
};

public void OnPluginStart()
{
    g_cvMinSpeed = CreateConVar(
        "barrymod2_hunter_nodeadstop_speed",
        "600.0",
        "Pounce speed (units/sec) at or above which a pouncing hunter cannot be deadstopped by a shove. 0 = disabled (deadstops always work).",
        FCVAR_NONE, true, 0.0, false);
}

public Action L4D2_OnEntityShoved(int client, int entity, int weapon, float vecDir[3], bool bIsHighPounce)
{
    float minSpeed = g_cvMinSpeed.FloatValue;
    if (minSpeed <= 0.0)
        return Plugin_Continue;

    if (entity < 1 || entity > MaxClients || !IsClientInGame(entity) || !IsPlayerAlive(entity))
        return Plugin_Continue;

    if (GetClientTeam(entity) != 3 || GetEntProp(entity, Prop_Send, "m_zombieClass") != ZC_HUNTER)
        return Plugin_Continue;

    // Only mid-pounce (airborne). A grounded hunter shove is not a deadstop.
    if (GetEntPropEnt(entity, Prop_Send, "m_hGroundEntity") != -1)
        return Plugin_Continue;

    if (GetEntProp(entity, Prop_Send, "m_isAttemptingToPounce") == 0)
        return Plugin_Continue;

    float vel[3];
    GetEntPropVector(entity, Prop_Data, "m_vecVelocity", vel);
    if (GetVectorLength(vel) >= minSpeed)
    {
        // Fast pounce: negate the shove so the deadstop fails and the pounce continues.
        return Plugin_Handled;
    }

    return Plugin_Continue;
}
