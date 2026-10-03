#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <left4dhooks>

// [barrymod2 #2] SI respawn at a fraction of their class max health after dying.
// SI zombieClass ids: 1=Smoker 2=Boomer 3=Hunter 4=Spitter 5=Jockey 6=Charger 8=Tank

ConVar g_cvEnable;
ConVar g_cvFrac;
ConVar g_cvAfterDeathOnly;

bool g_bDiedThisMap[MAXPLAYERS + 1];

public Plugin myinfo =
{
    name        = "barrymod2 SI Fractional Respawn Health",
    author      = "Bizzy",
    description = "SI respawn at a fraction of their class max health (default half) after dying.",
    version     = "1.0",
    url         = "https://github.com/draxios/bizzymod"
};

public void OnPluginStart()
{
    g_cvEnable         = CreateConVar("barrymod2_si_halfhp", "1", "Enable fractional SI respawn health.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvFrac           = CreateConVar("barrymod2_si_halfhp_frac", "0.5", "Fraction of class max health an SI gets on respawn.", FCVAR_NOTIFY, true, 0.05, true, 1.0);
    g_cvAfterDeathOnly = CreateConVar("barrymod2_si_halfhp_after_death_only", "1", "1 = first spawn full HP, every spawn after a death is fractional; 0 = every SI spawn fractional.", FCVAR_NOTIFY, true, 0.0, true, 1.0);

    HookEvent("player_death", Event_PlayerDeath);
    HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);
}

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
    for (int i = 1; i <= MaxClients; i++)
        g_bDiedThisMap[i] = false;
}

public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client > 0 && client <= MaxClients && IsClientInGame(client) && GetClientTeam(client) == 3)
        g_bDiedThisMap[client] = true;
}

// Post-hook: MaterializeFromGhost has already restored full HP, so we override it here.
public void L4D_OnMaterializeFromGhost(int client)
{
    if (!g_cvEnable.BoolValue)
        return;
    if (client < 1 || client > MaxClients || !IsClientInGame(client))
        return;
    if (GetClientTeam(client) != 3 || !IsPlayerAlive(client))
        return;
    if (g_cvAfterDeathOnly.BoolValue && !g_bDiedThisMap[client])
        return;

    int cls = GetEntProp(client, Prop_Send, "m_zombieClass");
    int maxhp = GetClassMaxHealth(cls);
    if (maxhp <= 0)
        return;

    int newhp = RoundToCeil(float(maxhp) * g_cvFrac.FloatValue);
    if (newhp < 1)
        newhp = 1;

    SetEntProp(client, Prop_Data, "m_iMaxHealth", newhp);
    SetEntProp(client, Prop_Send, "m_iMaxHealth", newhp);
    SetEntProp(client, Prop_Data, "m_iHealth", newhp);
    SetEntityHealth(client, newhp);
}

int GetClassMaxHealth(int cls)
{
    char cvar[32];
    switch (cls)
    {
        case 1: cvar = "z_gas_health";       // Smoker
        case 2: cvar = "z_exploding_health"; // Boomer
        case 3: cvar = "z_hunter_health";    // Hunter
        case 4: cvar = "z_spitter_health";   // Spitter
        case 5: cvar = "z_jockey_health";    // Jockey
        case 6: cvar = "z_charger_health";   // Charger
        default: return 0;                   // Tank / unknown: untouched
    }
    ConVar cv = FindConVar(cvar);
    return (cv == null) ? 0 : cv.IntValue;
}
