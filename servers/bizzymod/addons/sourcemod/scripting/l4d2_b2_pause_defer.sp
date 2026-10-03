#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <left4dhooks>

// [barrymod2 #15] Delay !pause while a survivor is healing/using an item or
// getting up. Sits in front of the already-loaded pause.smx via a command
// listener; it does not replace it. When nothing is blocking, pause is normal.

#define TEAM_SURVIVOR 2

public Plugin myinfo =
{
    name = "B2 Pause Defer",
    author = "Bizzy",
    description = "Delays !pause while a survivor is healing/using an item or getting up (barrymod2)",
    version = "1.0",
    url = "https://github.com/draxios/bizzymod"
};

bool   g_bBypass;
int    g_iPendingUserId;
Handle g_hRetry;

public void OnPluginStart()
{
    AddCommandListener(Cmd_Pause, "sm_pause");
    AddCommandListener(Cmd_Pause, "pause");
    AddCommandListener(Cmd_Pause, "callpause");
}

public Action Cmd_Pause(int client, const char[] command, int argc)
{
    if (g_bBypass) return Plugin_Continue;         // our own re-issue: let pause.smx handle it
    if (client < 1 || !IsClientInGame(client)) return Plugin_Continue;
    if (!AnyBusySurvivor()) return Plugin_Continue; // nothing blocking -> normal pause

    g_iPendingUserId = GetClientUserId(client);
    PrintToChatAll("\x04[Pause]\x01 Pause queued - waiting for revive/heal/getup to finish...");
    if (g_hRetry == null)
        g_hRetry = CreateTimer(0.5, Timer_Retry, _, TIMER_REPEAT);
    return Plugin_Handled;                          // swallow this pause attempt
}

public Action Timer_Retry(Handle t)
{
    if (AnyBusySurvivor()) return Plugin_Continue;

    g_hRetry = null;
    int c = GetClientOfUserId(g_iPendingUserId);
    g_iPendingUserId = 0;
    if (c > 0 && IsClientInGame(c))
    {
        g_bBypass = true;
        FakeClientCommand(c, "sm_pause");
        g_bBypass = false;
    }
    return Plugin_Stop;
}

bool AnyBusySurvivor()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || GetClientTeam(i) != TEAM_SURVIVOR) continue;
        if (!IsPlayerAlive(i)) continue;

        // Heal / defib / being-revived: the HUD progress bar is active.
        float dur = GetEntPropFloat(i, Prop_Send, "m_flProgressBarDuration");
        if (dur > 0.0) return true;

        // Someone is being revived (either side of the revive).
        if (GetEntProp(i, Prop_Send, "m_reviveTarget") > 0) return true;
        if (GetEntProp(i, Prop_Send, "m_reviveOwner")  > 0) return true;

        // Getting up from a stumble/pin (staggering counts as getup animation).
        if (L4D_IsPlayerStaggering(i)) return true;
    }
    return false;
}
