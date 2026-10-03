#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

// [barrymod2 #16] !trade gives your current-slot item to the nearest survivor
// you are facing. NOTE: GivePlayerItem creates a fresh weapon, so laser sight,
// clip ammo and Last-Stand/incendiary upgrades are NOT carried across the trade.

#define TEAM_SURVIVOR 2
#define TRADE_RANGE   180.0

public Plugin myinfo =
{
    name = "B2 Trade",
    author = "Bizzy",
    description = "!trade gives your current-slot item to the nearest survivor you are facing (barrymod2)",
    version = "1.0",
    url = "https://github.com/draxios/bizzymod"
};

public void OnPluginStart()
{
    RegConsoleCmd("sm_trade", Cmd_Trade, "Give your held item to the nearest survivor you are facing");
}

public Action Cmd_Trade(int client, int args)
{
    if (client < 1 || !IsClientInGame(client) || GetClientTeam(client) != TEAM_SURVIVOR || !IsPlayerAlive(client))
        return Plugin_Handled;

    int wep = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
    if (wep == -1)
    {
        ReplyToCommand(client, "[Trade] You have nothing in hand.");
        return Plugin_Handled;
    }
    int slot = GetWeaponSlot(client, wep);
    if (slot < 0)
    {
        ReplyToCommand(client, "[Trade] That item cannot be traded.");
        return Plugin_Handled;
    }

    int target = FindNearestFacingTeammate(client);
    if (target < 1)
    {
        ReplyToCommand(client, "[Trade] No teammate close enough in front of you.");
        return Plugin_Handled;
    }

    char cls[64];
    GetEntityClassname(wep, cls, sizeof cls);

    // Remove giver's item; drop/replace target's same-slot item, then equip.
    int tOld = GetPlayerWeaponSlot(target, slot);
    if (tOld != -1)
    {
        RemovePlayerItem(target, tOld);
        AcceptEntityInput(tOld, "Kill");
    }
    RemovePlayerItem(client, wep);
    AcceptEntityInput(wep, "Kill");

    int give = GivePlayerItem(target, cls);
    if (give > 0)
        EquipPlayerWeapon(target, give);

    PrintToChat(client, "[Trade] Gave %s to %N.", cls[7], target);
    PrintToChat(target, "[Trade] %N gave you %s.", client, cls[7]);
    return Plugin_Handled;
}

int GetWeaponSlot(int client, int wep)
{
    for (int s = 0; s < 5; s++)
        if (GetPlayerWeaponSlot(client, s) == wep) return s;
    return -1;
}

int FindNearestFacingTeammate(int client)
{
    float me[3], mang[3], fwd[3];
    GetClientAbsOrigin(client, me);
    GetClientEyeAngles(client, mang);
    GetAngleVectors(mang, fwd, NULL_VECTOR, NULL_VECTOR);

    int best = -1;
    float bestDist = TRADE_RANGE;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (i == client || !IsClientInGame(i)) continue;
        if (GetClientTeam(i) != TEAM_SURVIVOR || !IsPlayerAlive(i)) continue;

        float them[3], dir[3];
        GetClientAbsOrigin(i, them);
        SubtractVectors(them, me, dir);
        float dist = GetVectorLength(dir);
        if (dist > bestDist) continue;
        NormalizeVector(dir, dir);
        if (GetVectorDotProduct(fwd, dir) < 0.5) continue; // must be roughly in front
        best = i; bestDist = dist;
    }
    return best;
}
