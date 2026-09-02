/**
 * motd.sp — message-of-the-day storage + display.
 * Backed by the kv_settings table under scope='global', key='motd'.
 */

void Bizzy_OnMotdInit()
{
    RegConsoleCmd("sm_showmotd",   Cmd_ShowMotd, "Show the server MOTD");
    RegAdminCmd("sm_rank_motd",    Cmd_SetMotd, ADMFLAG_GENERIC,
        "Set the server MOTD: sm_rank_motd <text>");
}

static Action Cmd_ShowMotd(int client, int args)
{
    LoadAndShow(client);
    return Plugin_Handled;
}

static Action Cmd_SetMotd(int client, int args)
{
    if (args == 0)
    {
        ReplyToCommand(client, "Usage: sm_rank_motd <message>");
        return Plugin_Handled;
    }
    char msg[512], esc[1100];
    GetCmdArgString(msg, sizeof msg);
    Bizzy_DB_Escape(msg, esc, sizeof esc);

    char sql[1300];
    FormatEx(sql, sizeof sql,
        "INSERT INTO kv_settings (scope, scope_id, `key`, value) "
        ... "VALUES ('global', 0, 'motd', '%s') "
        ... "ON DUPLICATE KEY UPDATE value=VALUES(value), updated_at=NOW()", esc);
    Bizzy_DB_Exec(sql);
    ReplyToCommand(client, "[bizzymod-stats] MOTD updated.");
    return Plugin_Handled;
}

static void LoadAndShow(int client)
{
    if (g_DB == null) return;
    DataPack dp = new DataPack();
    dp.WriteCell(client > 0 ? GetClientUserId(client) : 0);
    g_DB.Query(OnMotdLoaded,
        "SELECT value FROM kv_settings WHERE scope='global' AND `key`='motd'", dp);
}

static void OnMotdLoaded(Database db, DBResultSet rs, const char[] error, DataPack dp)
{
    dp.Reset();
    int uid = dp.ReadCell();
    delete dp;
    if (rs == null || !rs.FetchRow()) return;
    char msg[512];
    rs.FetchString(0, msg, sizeof msg);
    if (uid == 0)
        PrintToChatAll("\x04[bizzymod-stats]\x01 %s", msg);
    else
    {
        int client = GetClientOfUserId(uid);
        if (client > 0) PrintToChat(client, "\x04[bizzymod-stats]\x01 %s", msg);
    }
}
