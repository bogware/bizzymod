#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <readyup>

// [barrymod2 #6] Drug survivors who go AFK too long during ready-up, until they
// move. The drug effect is applied via ServerCommand "sm_drug" (funcommands.smx,
// which barrymod2 loads via shared_plugins.cfg). ServerCommand runs as console
// (root), bypassing sm_drug's ADMFLAG_SLAY requirement.

#define TEAM_SURVIVOR 2

public Plugin myinfo =
{
    name = "B2 ReadyUp AFK Drug",
    author = "Bizzy",
    description = "Drugs survivors who go AFK too long during ready-up, until they move (barrymod2)",
    version = "1.0",
    url = "https://github.com/draxios/bizzymod"
};

ConVar g_cvTime;
float  g_fLastActive[MAXPLAYERS + 1];
bool   g_bDrugged[MAXPLAYERS + 1];
int    g_iLastButtons[MAXPLAYERS + 1];
float  g_fLastAng[MAXPLAYERS + 1][3];

public void OnPluginStart()
{
    g_cvTime = CreateConVar("l4d2_afkdrug_time", "25",
        "Seconds a survivor must be idle during ready-up before being drugged",
        FCVAR_NOTIFY, true, 5.0);
    CreateTimer(1.0, Timer_Check, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

public void OnClientDisconnect(int client)
{
    g_bDrugged[client] = false;
}

public Action Timer_Check(Handle t)
{
    bool inReady = IsInReady();
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i)) continue;

        if (GetClientTeam(i) != TEAM_SURVIVOR || !IsPlayerAlive(i))
        {
            ClearDrug(i);
            continue;
        }
        if (!inReady)
        {
            ClearDrug(i);
            g_fLastActive[i] = GetGameTime();
            continue;
        }

        int btn = GetClientButtons(i);
        float ang[3];
        GetClientEyeAngles(i, ang);

        bool moved =
            btn != g_iLastButtons[i] ||
            FloatAbs(ang[0] - g_fLastAng[i][0]) > 0.5 ||
            FloatAbs(ang[1] - g_fLastAng[i][1]) > 0.5;

        g_iLastButtons[i] = btn;
        g_fLastAng[i][0] = ang[0];
        g_fLastAng[i][1] = ang[1];
        g_fLastAng[i][2] = ang[2];

        if (moved)
        {
            g_fLastActive[i] = GetGameTime();
            ClearDrug(i);
        }
        else if (!g_bDrugged[i] && GetGameTime() - g_fLastActive[i] >= g_cvTime.FloatValue)
        {
            ServerCommand("sm_drug #%d 1", GetClientUserId(i));
            g_bDrugged[i] = true;
        }
    }
    return Plugin_Continue;
}

void ClearDrug(int client)
{
    if (g_bDrugged[client])
    {
        ServerCommand("sm_drug #%d 0", GetClientUserId(client));
        g_bDrugged[client] = false;
    }
}
