/**
 * commands.sp — chat + console commands available to all players.
 *
 *   sm_rank          — show your rank + points
 *   sm_top10         — show top 10 by points
 *   sm_top10ppm      — show top 10 by points-per-minute
 *   sm_nextrank      — points needed to reach the next rank
 *   sm_showrank      — show ranks of all online players
 *   sm_rankmenu      — open a menu of stats commands
 *   sm_rankmutetoggle — toggle your own stat-message muting
 */

void Bizzy_OnCommandsInit()
{
    RegConsoleCmd("sm_rank",            Cmd_Rank);
    RegConsoleCmd("sm_top10",           Cmd_Top10);
    RegConsoleCmd("sm_top10ppm",        Cmd_Top10Ppm);
    RegConsoleCmd("sm_nextrank",        Cmd_NextRank);
    RegConsoleCmd("sm_showrank",        Cmd_ShowRank);
    RegConsoleCmd("sm_rankmenu",        Cmd_Menu);
    RegConsoleCmd("sm_rankmute",        Cmd_RankMute);
    RegConsoleCmd("sm_rankmutetoggle",  Cmd_RankMuteToggle);
    RegAdminCmd("sm_rank_clear",        Cmd_RankClear, ADMFLAG_ROOT,
        "Clear all stats (asks for confirmation)");
}

void Bizzy_RegisterAdminMenu(TopMenu menu)
{
    // Registration intentionally minimal — admin features hang off existing
    // SourceMod TopMenu categories rather than creating a new one.
}

static Action Cmd_Rank(int client, int args)
{
    if (g_Clients[client].playerId == 0)
    {
        ReplyToCommand(client, "[bizzymod-stats] Stats not loaded yet — try again in a moment.");
        return Plugin_Handled;
    }
    DataPack dp = new DataPack();
    dp.WriteCell(GetClientUserId(client));
    char sql[512];
    FormatEx(sql, sizeof sql,
        "SELECT (1 + (SELECT COUNT(*) FROM v_player_totals t2 WHERE t2.points > t1.points)) AS rank, "
        ... "       t1.points "
        ... "FROM v_player_totals t1 WHERE t1.player_id = %d",
        g_Clients[client].playerId);
    g_DB.Query(OnRankResult, sql, dp);
    return Plugin_Handled;
}

static void OnRankResult(Database db, DBResultSet rs, const char[] err, DataPack dp)
{
    dp.Reset();
    int uid = dp.ReadCell();
    delete dp;
    int client = GetClientOfUserId(uid);
    if (client == 0 || rs == null || !rs.FetchRow()) return;
    PrintToChat(client, "\x04[bizzymod-stats]\x01 Your rank: \x05%d\x01  Points: \x05%d",
        rs.FetchInt(0), rs.FetchInt(1));
}

static Action Cmd_Top10(int client, int args)
{
    PrintTopList(client,
        "SELECT name, points FROM v_player_totals ORDER BY points DESC LIMIT 10",
        "Top 10 by points");
    return Plugin_Handled;
}

static Action Cmd_Top10Ppm(int client, int args)
{
    PrintTopList(client,
        "SELECT name, points_per_minute FROM v_top_players ORDER BY points_per_minute DESC LIMIT 10",
        "Top 10 by PPM");
    return Plugin_Handled;
}

static Action Cmd_NextRank(int client, int args)
{
    if (g_Clients[client].playerId == 0) return Plugin_Handled;
    DataPack dp = new DataPack();
    dp.WriteCell(GetClientUserId(client));
    char sql[512];
    FormatEx(sql, sizeof sql,
        "SELECT MIN(t2.points) - (SELECT points FROM v_player_totals WHERE player_id=%d) "
        ... "FROM v_player_totals t2 "
        ... "WHERE t2.points > (SELECT points FROM v_player_totals WHERE player_id=%d)",
        g_Clients[client].playerId, g_Clients[client].playerId);
    g_DB.Query(OnNextRankResult, sql, dp);
    return Plugin_Handled;
}

static void OnNextRankResult(Database db, DBResultSet rs, const char[] err, DataPack dp)
{
    dp.Reset();
    int uid = dp.ReadCell();
    delete dp;
    int client = GetClientOfUserId(uid);
    if (client == 0 || rs == null || !rs.FetchRow()) return;
    int needed = rs.FetchInt(0);
    if (rs.IsFieldNull(0))
        PrintToChat(client, "\x04[bizzymod-stats]\x01 You are rank #1.");
    else
        PrintToChat(client, "\x04[bizzymod-stats]\x01 %d more points to next rank.", needed);
}

static Action Cmd_ShowRank(int client, int args)
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (Bizzy_IsValidPlayer(i)) Cmd_Rank(i, 0);
    }
    return Plugin_Handled;
}

static Action Cmd_Menu(int client, int args)
{
    Menu m = new Menu(MenuHandler);
    m.SetTitle("bizzymod-stats");
    m.AddItem("rank",      "My rank");
    m.AddItem("nextrank",  "Next rank");
    m.AddItem("top10",     "Top 10");
    m.AddItem("top10ppm",  "Top 10 PPM");
    m.AddItem("motd",      "Server MOTD");
    m.AddItem("mute",      "Toggle stat-message mute");
    m.ExitButton = true;
    m.Display(client, MENU_TIME_FOREVER);
    return Plugin_Handled;
}

static int MenuHandler(Menu m, MenuAction action, int param1, int param2)
{
    if (action == MenuAction_End) { delete m; return 0; }
    if (action != MenuAction_Select) return 0;
    char key[32];
    m.GetItem(param2, key, sizeof key);
    if      (StrEqual(key, "rank"))     Cmd_Rank(param1, 0);
    else if (StrEqual(key, "nextrank")) Cmd_NextRank(param1, 0);
    else if (StrEqual(key, "top10"))    Cmd_Top10(param1, 0);
    else if (StrEqual(key, "top10ppm")) Cmd_Top10Ppm(param1, 0);
    else if (StrEqual(key, "mute"))     Cmd_RankMuteToggle(param1, 0);
    return 0;
}

static Action Cmd_RankMute(int client, int args)
{
    char arg[8];
    GetCmdArg(1, arg, sizeof arg);
    bool on = (StringToInt(arg) != 0);
    g_Clients[client].muted = on;
    PrintToChat(client, "\x04[bizzymod-stats]\x01 Stat messages %s",
        on ? "muted" : "unmuted");
    return Plugin_Handled;
}

static Action Cmd_RankMuteToggle(int client, int args)
{
    g_Clients[client].muted = !g_Clients[client].muted;
    PrintToChat(client, "\x04[bizzymod-stats]\x01 Stat messages %s",
        g_Clients[client].muted ? "muted" : "unmuted");
    return Plugin_Handled;
}

static Action Cmd_RankClear(int client, int args)
{
    if (g_DB == null) return Plugin_Handled;
    // Two-step: first invocation arms a flag, second confirms.
    static int g_ArmedBy = 0;
    static int g_ArmedAt = 0;
    if (g_ArmedBy != client || (GetTime() - g_ArmedAt) > 10)
    {
        g_ArmedBy = client;
        g_ArmedAt = GetTime();
        ReplyToCommand(client, "[bizzymod-stats] Re-run within 10 seconds to confirm WIPE of all stats.");
        return Plugin_Handled;
    }
    Transaction t = Bizzy_DB_BeginTxn();
    t.AddQuery("DELETE FROM player_awards");
    t.AddQuery("DELETE FROM player_si_stats");
    t.AddQuery("DELETE FROM player_weapon_stats");
    t.AddQuery("DELETE FROM player_stats");
    t.AddQuery("DELETE FROM sessions");
    t.AddQuery("DELETE FROM award_events");
    Bizzy_DB_RunTxn(t);
    ReplyToCommand(client, "[bizzymod-stats] Stats cleared.");
    g_ArmedBy = 0;
    return Plugin_Handled;
}

static void PrintTopList(int client, const char[] sql, const char[] title)
{
    DataPack dp = new DataPack();
    dp.WriteCell(client > 0 ? GetClientUserId(client) : 0);
    dp.WriteString(title);
    g_DB.Query(OnTopListResult, sql, dp);
}

static void OnTopListResult(Database db, DBResultSet rs, const char[] err, DataPack dp)
{
    dp.Reset();
    int uid = dp.ReadCell();
    char title[64];
    dp.ReadString(title, sizeof title);
    delete dp;
    if (rs == null) return;
    int client = GetClientOfUserId(uid);
    if (uid != 0 && client == 0) return;

    char buf[256], name[64];
    PrintToOne(client, "\x04[bizzymod-stats]\x01 %s:", title);
    int i = 0;
    while (rs.FetchRow())
    {
        rs.FetchString(0, name, sizeof name);
        int val = rs.FetchInt(1);
        FormatEx(buf, sizeof buf, " %2d. %s — %d", ++i, name, val);
        PrintToOne(client, "%s", buf);
    }
}

static void PrintToOne(int client, const char[] fmt, any ...)
{
    char buf[256];
    VFormat(buf, sizeof buf, fmt, 3);
    if (client == 0) PrintToServer("%s", buf);
    else             PrintToChat(client, "%s", buf);
}
