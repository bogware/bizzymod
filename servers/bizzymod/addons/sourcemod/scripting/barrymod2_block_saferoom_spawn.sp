#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <left4dhooks>

// [barrymod2 #14] Block SI from materializing inside a checkpoint saferoom while
// its door is closed. L4D_OnSpawnSpecial fires ONLY for bot spawns, not player
// ghosts, so the correct block point is L4D_OnMaterializeFromGhostPre.

// Nav spawn-attribute flags (verify live): 64 = CHECKPOINT (saferoom) area.
#define NAV_CHECKPOINT 64
// prop_door_rotating_checkpoint m_eDoorState: 0 = DOOR_STATE_CLOSED.
#define DOOR_STATE_CLOSED 0

ConVar g_cvEnable;

public Plugin myinfo =
{
    name        = "barrymod2 Block SI Spawn Through Closed Saferoom Door",
    author      = "Bizzy",
    description = "Blocks SI from materializing inside a checkpoint saferoom while its door is closed.",
    version     = "1.0",
    url         = "https://github.com/draxios/bizzymod"
};

public void OnPluginStart()
{
    g_cvEnable = CreateConVar("barrymod2_block_saferoom_spawn", "1", "Block SI materialize inside a closed checkpoint saferoom.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
}

// Pre-hook: return Plugin_Handled to stop the SI popping out of ghost here.
public Action L4D_OnMaterializeFromGhostPre(int client)
{
    if (!g_cvEnable.BoolValue)
        return Plugin_Continue;
    if (client < 1 || client > MaxClients || !IsClientInGame(client) || GetClientTeam(client) != 3)
        return Plugin_Continue;

    float pos[3];
    GetClientAbsOrigin(client, pos);

    Address nav = L4D_GetNearestNavArea(pos, 120.0);
    if (nav == Address_Null)
        return Plugin_Continue;

    int attr = L4D_GetNavArea_SpawnAttributes(nav);
    if (!(attr & NAV_CHECKPOINT))
        return Plugin_Continue;

    if (IsAnyCheckpointDoorClosed())
    {
        PrintHintText(client, "You cannot spawn inside the closed saferoom.");
        return Plugin_Handled;
    }
    return Plugin_Continue;
}

bool IsAnyCheckpointDoorClosed()
{
    int ent = -1;
    while ((ent = FindEntityByClassname(ent, "prop_door_rotating_checkpoint")) != -1)
    {
        if (GetEntProp(ent, Prop_Send, "m_eDoorState") == DOOR_STATE_CLOSED)
            return true;
    }
    return false;
}
