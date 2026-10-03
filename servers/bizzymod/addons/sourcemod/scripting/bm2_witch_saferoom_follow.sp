#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <left4dhooks>

// [barrymod2 #1] Witch saferoom-follow assist.  EXPERIMENTAL — the load line in
// confogl_plugins.cfg is intentionally COMMENTED OUT until this is verified on a
// live map where the glitch reproduces (e.g. c8m1). The witch NextBot fails to
// path through the CLOSED start-saferoom door when the survivor that startled her
// runs back inside. Witches cannot open doors, so we (a) unlock+open the
// start-saferoom checkpoint door once a witch is active and startled, and (b) if
// the witch sits with ~0 velocity for >1.5s while a survivor is still in the
// start area, nudge her toward that survivor so she does not 'give up'. Tune
// STUCK_SPEED / STUCK_TIME live. Scoped to barrymod2 via confogl_plugins only.

#define STUCK_SPEED   12.0
#define STUCK_TIME    1.5

bool  g_bActive;
float g_fLastMove[2049];   // last engine-time the witch had real velocity

public Plugin myinfo =
{
    name        = "[barrymod2] Witch Saferoom Follow",
    author      = "bizzymod",
    description = "Opens the start-saferoom door and unsticks a startled witch chasing a survivor inside it",
    version     = "1.0",
    url         = "https://github.com/draxios/bizzymod"
};

public void OnPluginStart()
{
    HookEvent("witch_spawn", Event_WitchSpawn, EventHookMode_PostNoCopy);
    CreateTimer(0.5, Timer_Watch, _, TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);
}

void Event_WitchSpawn(Event e, const char[] n, bool db) { g_bActive = true; }

Action Timer_Watch(Handle t)
{
    if (!g_bActive) return Plugin_Continue;

    bool anyWitch = false;
    int witch = -1;
    while ((witch = FindEntityByClassname(witch, "witch")) != -1)
    {
        anyWitch = true;
        if (!IsValidEntity(witch)) continue;

        // Is any survivor still inside the mission start area?
        int target = -1;
        for (int i = 1; i <= MaxClients; i++)
        {
            if (IsClientInGame(i) && IsPlayerAlive(i) && GetClientTeam(i) == 2
                && GetEntProp(i, Prop_Send, "m_isInMissionStartArea") != 0)
            {
                target = i;
                break;
            }
        }
        if (target == -1) continue;

        // Open the start-saferoom checkpoint door so the witch can path in.
        OpenStartCheckpointDoors();

        // Stuck detection: near-zero velocity for STUCK_TIME while a target is inside.
        float vel[3];
        GetEntPropVector(witch, Prop_Data, "m_vecVelocity", vel);
        float speed = GetVectorLength(vel);
        float now = GetEngineTime();
        if (speed > STUCK_SPEED) { g_fLastMove[witch] = now; continue; }
        if (g_fLastMove[witch] == 0.0) { g_fLastMove[witch] = now; continue; }

        if (now - g_fLastMove[witch] >= STUCK_TIME)
        {
            // Nudge the witch one step toward the target along the ground.
            float wPos[3], tPos[3], dir[3];
            GetEntPropVector(witch, Prop_Send, "m_vecOrigin", wPos);
            GetClientAbsOrigin(target, tPos);
            MakeVectorFromPoints(wPos, tPos, dir);
            dir[2] = 0.0;
            NormalizeVector(dir, dir);
            ScaleVector(dir, 40.0);
            AddVectors(wPos, dir, wPos);
            TeleportEntity(witch, wPos, NULL_VECTOR, NULL_VECTOR);
            g_fLastMove[witch] = now;
        }
    }

    if (!anyWitch) g_bActive = false;
    return Plugin_Continue;
}

void OpenStartCheckpointDoors()
{
    int door = -1;
    while ((door = FindEntityByClassname(door, "prop_door_rotating_checkpoint")) != -1)
    {
        AcceptEntityInput(door, "Unlock");
        AcceptEntityInput(door, "Open");
    }
    door = -1;
    while ((door = FindEntityByClassname(door, "prop_door_rotating")) != -1)
    {
        char nm[64];
        GetEntPropString(door, Prop_Data, "m_iName", nm, sizeof(nm));
        if (StrContains(nm, "checkpoint", false) != -1 || StrContains(nm, "saferoom", false) != -1)
        {
            AcceptEntityInput(door, "Unlock");
            AcceptEntityInput(door, "Open");
        }
    }
}
