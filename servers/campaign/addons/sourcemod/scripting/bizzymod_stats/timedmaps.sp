/**
 * timedmaps.sp — per-map timing for single-team gamemodes.
 *
 * On map start, record the start timestamp. On map transition / mission
 * win / mission lost, compute the duration and UPSERT into timed_maps.
 * Survival keeps the *longest* time; everything else keeps the *shortest*.
 */

static int g_MapStartEpochMs = 0;

void Bizzy_OnTimedMapsInit()
{
    // Pluggable: timing only enabled outside versus modes.
}

stock void Bizzy_TimedMaps_Start()
{
    g_MapStartEpochMs = GetTime() * 1000;
}

stock void Bizzy_TimedMaps_Finish(bool survivorsWon)
{
    if (g_MapStartEpochMs == 0 || g_CurrentMapId == 0) return;
    int durMs = GetTime() * 1000 - g_MapStartEpochMs;
    if (durMs <= 0) return;

    bool keepLongest = (g_CurrentMode == GameMode_Survival);

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!g_Clients[i].inUse) continue;
        if (g_Clients[i].playerId == 0) continue;
        UpsertBestTime(g_Clients[i].playerId, durMs, keepLongest);
    }

    g_MapStartEpochMs = 0;
    // survivorsWon currently unused — left as a parameter so callers don't
    // need to change when win/lose-specific bookkeeping is added later.
    if (survivorsWon) {}
}

static void UpsertBestTime(int playerId, int durMs, bool keepLongest)
{
    char op[8];
    strcopy(op, sizeof op, keepLongest ? ">" : "<");
    char sql[512];
    FormatEx(sql, sizeof sql,
        "INSERT INTO timed_maps "
        ... "(map_id, gamemode_id, difficulty_id, player_id, mutation, best_time_ms, plays, players) "
        ... "VALUES (%d, %d, %d, %d, '', %d, 1, %d) "
        ... "ON DUPLICATE KEY UPDATE "
        ... "  best_time_ms = IF(%d %s best_time_ms, %d, best_time_ms), "
        ... "  plays = plays + 1, "
        ... "  updated_at = NOW()",
        g_CurrentMapId, view_as<int>(g_CurrentMode), view_as<int>(g_CurrentDifficulty),
        playerId, durMs, GetSurvivorCount(),
        durMs, op, durMs);
    Bizzy_DB_Exec(sql);
}

static int GetSurvivorCount()
{
    int n = 0;
    for (int i = 1; i <= MaxClients; i++)
        if (IsClientInGame(i) && GetClientTeam(i) == TEAM_SURVIVORS)
            n++;
    return n;
}
