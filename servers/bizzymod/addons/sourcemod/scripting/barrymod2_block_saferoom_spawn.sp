#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <left4dhooks>

// [barrymod2 #14] Block SI from materializing inside a checkpoint saferoom while
// its door is closed. L4D_OnSpawnSpecial fires ONLY for bot spawns, not player
// ghosts, so the correct block point is L4D_OnMaterializeFromGhostPre.
//
// FINALE GUARD (v1.1 fix): this block must NOT apply once a finale event has
// started. IsAnyCheckpointDoorClosed() is a MAP-WIDE check, and during a finale
// the abandoned start-saferoom door stays closed while the finale arena's nav
// can match the spawn attribute below -- so near-survivor SI spawns in the
// finale arena were all rejected, forcing infected to materialize comically far
// away (reported on c10m5 / Death Toll, but it affects every finale). The
// saferoom-spawn exploit this guards against is a round-/map-start concern, so
// we disable the block for the rest of a map once its finale event fires.

// Nav spawn-attribute flag the original author matched. NOTE: the value was
// never verified upstream ("verify live") and may not actually be CHECKPOINT.
// The finale guard makes the finale case correct regardless of its exact value;
// confirm this flag separately if the non-finale saferoom block is relied upon.
#define NAV_CHECKPOINT 64
// prop_door_rotating_checkpoint m_eDoorState: 0 = DOOR_STATE_CLOSED.
#define DOOR_STATE_CLOSED 0

ConVar g_cvEnable;
bool g_bFinaleStarted;

public Plugin myinfo =
{
    name        = "barrymod2 Block SI Spawn Through Closed Saferoom Door",
    author      = "Bizzy",
    description = "Blocks SI from materializing inside a closed checkpoint saferoom (not during finales).",
    version     = "1.1",
    url         = "https://github.com/draxios/bizzymod"
};

public void OnPluginStart()
{
    g_cvEnable = CreateConVar("barrymod2_block_saferoom_spawn", "1", "Block SI materialize inside a closed checkpoint saferoom.", FCVAR_NOTIFY, true, 0.0, true, 1.0);

    // Track whether a finale event is active this map. Hook every finale-start
    // variant so standard, radio and gauntlet finales are all covered; reset on
    // round boundaries (versus plays two rounds per finale map) and map change.
    HookEvent("finale_start",          Event_FinaleStart, EventHookMode_PostNoCopy);
    HookEvent("finale_radio_start",    Event_FinaleStart, EventHookMode_PostNoCopy);
    HookEvent("gauntlet_finale_start", Event_FinaleStart, EventHookMode_PostNoCopy);
    HookEvent("round_start",           Event_ResetFinale, EventHookMode_PostNoCopy);
    HookEvent("round_end",             Event_ResetFinale, EventHookMode_PostNoCopy);
}

public void OnMapStart()
{
    g_bFinaleStarted = false;
}

void Event_FinaleStart(Event event, const char[] name, bool dontBroadcast)
{
    g_bFinaleStarted = true;
}

void Event_ResetFinale(Event event, const char[] name, bool dontBroadcast)
{
    g_bFinaleStarted = false;
}

// Pre-hook: return Plugin_Handled to stop the SI popping out of ghost here.
public Action L4D_OnMaterializeFromGhostPre(int client)
{
    if (!g_cvEnable.BoolValue)
        return Plugin_Continue;
    // Finale event in progress: never block (the start-saferoom exploit this
    // plugin guards is a pre-finale concern; blocking here strands SI far away).
    if (g_bFinaleStarted)
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
