/**
 * rankvote.sp — team shuffle vote based on player PPM (points per minute).
 *
 * Modern rewrite of the legacy "rankvote" / "sm_rank_shuffle" feature.
 * Uses the BuiltinVoteManager API where available; falls back to NativeVotes
 * if installed; else uses a simple MenuPanel.
 */

#define RANKVOTE_DURATION_DEFAULT 20.0

static bool g_VoteActive = false;

void Bizzy_OnRankvoteInit()
{
    RegConsoleCmd("sm_rankvote",  Cmd_RankVote, "Vote to shuffle teams by PPM");
    RegAdminCmd("sm_rank_shuffle", Cmd_Shuffle, ADMFLAG_KICK,
        "Force-shuffle teams by PPM (no vote)");
}

static Action Cmd_RankVote(int client, int args)
{
    if (g_VoteActive)
    {
        ReplyToCommand(client, "[bizzymod-stats] A vote is already active.");
        return Plugin_Handled;
    }
    if (g_CurrentMode != GameMode_Versus && g_CurrentMode != GameMode_Scavenge
        && g_CurrentMode != GameMode_RealismVersus)
    {
        ReplyToCommand(client, "[bizzymod-stats] Rank vote only works in two-team modes.");
        return Plugin_Handled;
    }
    StartRankVote();
    return Plugin_Handled;
}

static Action Cmd_Shuffle(int client, int args)
{
    DoShuffle();
    ReplyToCommand(client, "[bizzymod-stats] Teams shuffled by PPM.");
    return Plugin_Handled;
}

static void StartRankVote()
{
    if (IsVoteInProgress()) return;
    Menu menu = new Menu(VoteHandler, MenuAction_VoteEnd | MenuAction_End);
    menu.SetTitle("Shuffle teams by PPM?");
    menu.AddItem("yes", "Yes");
    menu.AddItem("no",  "No");
    menu.ExitButton = false;
    g_VoteActive = true;
    menu.DisplayVoteToAll(RoundToNearest(RANKVOTE_DURATION_DEFAULT));
}

static int VoteHandler(Menu menu, MenuAction action, int param1, int param2)
{
    if (action == MenuAction_VoteEnd)
    {
        // param1 = winning item index (0 = "yes", 1 = "no").
        bool yesWon = (param1 == 0);
        if (yesWon)
        {
            DoShuffle();
            PrintToChatAll("\x04[bizzymod-stats]\x01 Vote passed — shuffling teams.");
        }
        else
        {
            PrintToChatAll("\x04[bizzymod-stats]\x01 Vote failed.");
        }
        g_VoteActive = false;
    }
    else if (action == MenuAction_End)
    {
        delete menu;
        g_VoteActive = false;
    }
    return 0;
}

// Vote decision uses MenuAction_VoteEnd's param1 (winning item index).

// -----------------------------------------------------------------------------
// Shuffle implementation: zig-zag pair-up by PPM.
// -----------------------------------------------------------------------------

static void DoShuffle()
{
    // Build [client, ppm] list for in-game humans
    int clients[MAXPLAYERS + 1];
    float ppm[MAXPLAYERS + 1];
    int n = 0;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!Bizzy_IsValidPlayer(i)) continue;
        int t = GetClientTeam(i);
        if (t != TEAM_SURVIVORS && t != TEAM_INFECTED) continue;
        clients[n] = i;
        ppm[n] = ComputePPMFromSession(i);
        n++;
    }

    // Sort by ppm desc (insertion sort, n is small)
    for (int i = 1; i < n; i++)
    {
        int ci = clients[i];
        float pi = ppm[i];
        int j = i;
        while (j > 0 && ppm[j-1] < pi)
        {
            clients[j] = clients[j-1];
            ppm[j] = ppm[j-1];
            j--;
        }
        clients[j] = ci;
        ppm[j] = pi;
    }

    // Zig-zag: 0->A, 1->B, 2->B, 3->A, 4->A, 5->B, ...
    for (int i = 0; i < n; i++)
    {
        int target = ((i + 1) / 2) % 2 == 0 ? TEAM_SURVIVORS : TEAM_INFECTED;
        ChangeClientTeam(clients[i], target);
    }
}

static float ComputePPMFromSession(int client)
{
    int duration = Bizzy_NowEpoch() - g_Clients[client].sessionStartTime;
    if (duration < 60) return 0.0;
    return float(g_Clients[client].pointsThisSession) * 60.0 / float(duration);
}
