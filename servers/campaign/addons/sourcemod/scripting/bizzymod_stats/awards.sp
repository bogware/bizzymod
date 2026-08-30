/**
 * awards.sp — fire and persist awards.
 *
 * Awards are addressed by their string `code` (matches `awards.code` in
 * the DB). On first sight we look up the numeric ID and cache it in a
 * StringMap so subsequent fires are O(1) into a single async UPSERT.
 */

static StringMap g_AwardIds;            // code -> award_id (int)
static StringMap g_AwardBasePoints;     // code -> base_points (int)

void Bizzy_OnAwardsInit()
{
    g_AwardIds        = new StringMap();
    g_AwardBasePoints = new StringMap();
    // Catalog is loaded lazily — first Bizzy_Awards_Fire triggers a load.
}

static void LoadCatalog()
{
    if (g_DB == null) return;
    g_DB.Query(OnCatalogLoaded,
        "SELECT id, code, base_points FROM awards");
}

static void OnCatalogLoaded(Database db, DBResultSet rs, const char[] error, any data)
{
    if (rs == null) { LogError("[bizzymod-stats] award catalog load: %s", error); return; }
    while (rs.FetchRow())
    {
        int id = rs.FetchInt(0);
        char code[64];
        rs.FetchString(1, code, sizeof code);
        int bp = rs.FetchInt(2);
        g_AwardIds.SetValue(code, id);
        g_AwardBasePoints.SetValue(code, bp);
    }
}

stock void Bizzy_Awards_Fire(int client, const char[] code, int delta = 1)
{
    if (!Bizzy_IsValidPlayer(client)) return;
    if (g_Clients[client].playerId == 0) return;
    if (g_DB == null) return;

    int awardId;
    if (!g_AwardIds.GetValue(code, awardId))
    {
        // Lazy load + retry: don't drop the event silently.
        if (g_AwardIds.Size == 0)
        {
            LoadCatalog();
            DataPack dp = new DataPack();
            dp.WriteCell(GetClientUserId(client));
            dp.WriteString(code);
            dp.WriteCell(delta);
            CreateTimer(0.5, RetryAwardFire, dp, TIMER_FLAG_NO_MAPCHANGE);
        }
        else
        {
            LogError("[bizzymod-stats] unknown award code '%s' — add it to the awards table.", code);
        }
        return;
    }

    int bp = 0;
    g_AwardBasePoints.GetValue(code, bp);

    char sql[512];
    FormatEx(sql, sizeof sql,
        "INSERT INTO player_awards (player_id, award_id, gamemode_id, count, first_at, last_at) "
        ... "VALUES (%d, %d, %d, %d, NOW(), NOW()) "
        ... "ON DUPLICATE KEY UPDATE count = count + VALUES(count), last_at = NOW()",
        g_Clients[client].playerId, awardId, view_as<int>(g_CurrentMode), delta);
    Bizzy_DB_Exec(sql);

    Bizzy_Versus_AccumAward(client);

    if (bp != 0)
        Bizzy_Score(client, bp * delta, code);
}

static Action RetryAwardFire(Handle timer, DataPack dp)
{
    dp.Reset();
    int uid = dp.ReadCell();
    char code[64];
    dp.ReadString(code, sizeof code);
    int delta = dp.ReadCell();
    delete dp;
    int client = GetClientOfUserId(uid);
    if (client > 0) Bizzy_Awards_Fire(client, code, delta);
    return Plugin_Stop;
}

stock void Bizzy_Awards_LogEvent(int client, const char[] code, int points)
{
    if (g_DB == null || g_Clients[client].playerId == 0) return;
    int awardId;
    if (!g_AwardIds.GetValue(code, awardId)) return;

    char sql[512];
    FormatEx(sql, sizeof sql,
        "INSERT INTO award_events (player_id, award_id, server_id, session_id, points, at) "
        ... "VALUES (%d, %d, %d, NULLIF(%d, 0), %d, NOW())",
        g_Clients[client].playerId, awardId, g_ServerId,
        g_Clients[client].sessionId, points);
    Bizzy_DB_Exec(sql);
}
