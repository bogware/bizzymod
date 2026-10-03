#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <left4dhooks>

// [barrymod2 #3] Let a ghost SI toggle between Boomer and Spitter while a Tank is active.

#define ZC_BOOMER  2
#define ZC_SPITTER 4
#define ZC_TANK    8

ConVar g_cvEnable;
ConVar g_cvCooldown;

bool  g_bTankInPlay;
float g_fNextSwap[MAXPLAYERS + 1];

public Plugin myinfo =
{
    name        = "barrymod2 SI Boomer/Spitter Swap During Tank",
    author      = "Bizzy",
    description = "Lets a ghost SI toggle between Boomer and Spitter while a Tank is active.",
    version     = "1.0",
    url         = "https://github.com/draxios/bizzymod"
};

public void OnPluginStart()
{
    g_cvEnable   = CreateConVar("barrymod2_si_class_swap_tank", "1", "Allow ghost SI to swap boomer<->spitter during a tank.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvCooldown = CreateConVar("barrymod2_si_class_swap_cooldown", "3", "Seconds between class swaps per player.", FCVAR_NOTIFY, true, 0.0, true, 60.0);

    RegConsoleCmd("sm_boomer",  Cmd_Boomer,  "Swap to Boomer (ghost only, during tank).");
    RegConsoleCmd("sm_spitter", Cmd_Spitter, "Swap to Spitter (ghost only, during tank).");

    HookEvent("tank_spawn",   Event_TankSpawn);
    HookEvent("player_death", Event_PlayerDeath);
    HookEvent("round_start",  Event_RoundStart, EventHookMode_PostNoCopy);
}

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
    g_bTankInPlay = false;
    for (int i = 1; i <= MaxClients; i++)
        g_fNextSwap[i] = 0.0;
}

public void Event_TankSpawn(Event event, const char[] name, bool dontBroadcast)
{
    g_bTankInPlay = true;
}

public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client > 0 && client <= MaxClients && IsClientInGame(client)
        && GetEntProp(client, Prop_Send, "m_zombieClass") == ZC_TANK)
    {
        CreateTimer(0.5, Timer_RecheckTank, _, TIMER_FLAG_NO_MAPCHANGE);
    }
}

public Action Timer_RecheckTank(Handle timer)
{
    g_bTankInPlay = IsAnyTankAlive();
    return Plugin_Stop;
}

bool IsAnyTankAlive()
{
    for (int i = 1; i <= MaxClients; i++)
        if (IsClientInGame(i) && GetClientTeam(i) == 3 && IsPlayerAlive(i)
            && GetEntProp(i, Prop_Send, "m_zombieClass") == ZC_TANK)
            return true;
    return false;
}

public Action Cmd_Boomer(int client, int args)  { SwapClass(client, ZC_BOOMER);  return Plugin_Handled; }
public Action Cmd_Spitter(int client, int args) { SwapClass(client, ZC_SPITTER); return Plugin_Handled; }

void SwapClass(int client, int newClass)
{
    if (!g_cvEnable.BoolValue)
        return;
    if (client < 1 || client > MaxClients || !IsClientInGame(client) || GetClientTeam(client) != 3)
        return;
    if (!g_bTankInPlay)
    {
        PrintToChat(client, "[barrymod2] Class swap is only allowed while a Tank is active.");
        return;
    }
    if (!IsGhost(client))
    {
        PrintToChat(client, "[barrymod2] You must be a ghost (not spawned) to swap class.");
        return;
    }
    int cur = GetEntProp(client, Prop_Send, "m_zombieClass");
    if (cur != ZC_BOOMER && cur != ZC_SPITTER)
    {
        PrintToChat(client, "[barrymod2] Only Boomer and Spitter can swap.");
        return;
    }
    if (cur == newClass)
        return;
    if (GetGameTime() < g_fNextSwap[client])
    {
        PrintToChat(client, "[barrymod2] Swap on cooldown.");
        return;
    }

    L4D_SetClass(client, newClass);
    SetEntProp(client, Prop_Send, "m_zombieClass", newClass);
    L4D_RespawnPlayer(client);

    g_fNextSwap[client] = GetGameTime() + g_cvCooldown.FloatValue;
    if (newClass == ZC_BOOMER)
        PrintToChat(client, "[barrymod2] Swapped to Boomer.");
    else
        PrintToChat(client, "[barrymod2] Swapped to Spitter.");
}

bool IsGhost(int client)
{
    return GetEntProp(client, Prop_Send, "m_isGhost") == 1;
}
