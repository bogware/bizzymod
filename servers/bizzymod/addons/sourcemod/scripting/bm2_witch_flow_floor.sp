#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <left4dhooks>
#define L4D2UTIL_STOCKS_ONLY
#include <l4d2util_rounds>

// [barrymod2 #18] Force the versus witch into a restricted LATE-map flow band,
// independent of the tank. witch_and_tankifier draws witch AND tank from the
// shared versus_boss_flow_min/max with no separate witch floor, so we clamp the
// witch's assigned flow after the tankifier has set it (round_start + 3.0s,
// before survivors leave the saferoom and before l4d_boss_percent's 5.0s read,
// so the ready-up display reflects the corrected value). Scoped to barrymod2.

ConVar g_hMin, g_hMax;

public Plugin myinfo =
{
    name        = "[barrymod2] Witch Flow Floor",
    author      = "bizzymod",
    description = "Clamps the versus witch spawn flow into a restricted late-map band",
    version     = "1.0",
    url         = "https://github.com/draxios/bizzymod"
};

public void OnPluginStart()
{
    g_hMin = CreateConVar("bm2_witch_flow_min", "0.50", "barrymod2: minimum witch spawn flow (0.0-1.0)", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_hMax = CreateConVar("bm2_witch_flow_max", "0.85", "barrymod2: maximum witch spawn flow (0.0-1.0)", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);
}

void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
    CreateTimer(3.0, Timer_ClampWitch, _, TIMER_FLAG_NO_MAPCHANGE);
}

Action Timer_ClampWitch(Handle timer)
{
    int round = InSecondHalfOfRound() ? 1 : 0;

    if (!L4D2Direct_GetVSWitchToSpawnThisRound(round))
        return Plugin_Stop;

    float flow = L4D2Direct_GetVSWitchFlowPercent(round);
    float lo = g_hMin.FloatValue;
    float hi = g_hMax.FloatValue;
    if (hi < lo) hi = lo;

    if (flow < lo || flow > hi)
    {
        float newFlow = lo + GetURandomFloat() * (hi - lo);
        L4D2Direct_SetVSWitchFlowPercent(round, newFlow);
    }

    return Plugin_Stop;
}
