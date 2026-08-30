/**
 * coordination.sp — revive chains, save-of-save, crescendo and finale
 * wave records. Inserts to revive_events / crescendo_events / finale_waves.
 *
 * Revive chain detection:
 *   On each revive_success: insert a row in revive_events.
 *   If the revived player themselves performed a revive_success within
 *   CHAIN_WINDOW_S seconds before this event, link this revive to that
 *   one's chain_root (or start a new chain rooted at the prior one).
 *
 * Save-of-save: a player who was just saved (within window) saves
 * someone -> credit save_of_saves on the original saver.
 */

#define CHAIN_WINDOW_S        60
#define SAVE_OF_SAVE_WINDOW_S 60

// Tracks most-recent revive *by* each player (their userid) to support
// chain detection. Per-victim "you were saved" timestamp also tracked.
static int g_LastReviveByUid[MAXPLAYERS + 1];      // last GetTime() they revived someone
static int g_LastReviveByChainRoot[MAXPLAYERS + 1]; // chain_root id their last revive was part of
static int g_LastSavedTimeOfUid[MAXPLAYERS + 1];   // last time this player was saved
static int g_LastSavedBy[MAXPLAYERS + 1];          // userid of saver

void Bizzy_OnCoordinationInit() { /* state-only */ }

stock void Bizzy_Coord_OnRevive(int reviver, int revived, bool viaDefib)
{
    if (g_DB == null) return;
    if (!Bizzy_IsValidPlayer(reviver) || !Bizzy_IsValidPlayer(revived)) return;
    if (g_Clients[reviver].playerId == 0 || g_Clients[revived].playerId == 0) return;

    int now = GetTime();

    // Was the reviver recently saved themselves? Then credit save-of-save
    // to whoever saved them.
    if (g_LastSavedTimeOfUid[reviver] != 0
        && (now - g_LastSavedTimeOfUid[reviver]) <= SAVE_OF_SAVE_WINDOW_S)
    {
        int savior = GetClientOfUserId(g_LastSavedBy[reviver]);
        if (Bizzy_IsValidPlayer(savior))
        {
            g_Clients[savior].saveOfSaves++;
            Bizzy_Awards_Fire(savior, "save_of_save", 1);
        }
    }

    // Determine chain_root: did the *revived* player perform a revive
    // recently? If yes, link to that chain.
    int chainRoot = 0;
    int chainDepth = 1;
    if (g_LastReviveByUid[revived] != 0
        && (now - g_LastReviveByUid[revived]) <= CHAIN_WINDOW_S)
    {
        chainRoot = g_LastReviveByChainRoot[revived];
        chainDepth = 2;
        // could increment further by tracing back; keep depth at 2 for now
        g_Clients[reviver].reviveChainsPartOf++;
        g_Clients[revived].reviveChainsPartOf++;
    }
    else
    {
        // Fresh chain
        g_Clients[reviver].reviveChainsStarted++;
    }

    // Record save metadata for future chain detection from this event
    g_LastSavedTimeOfUid[revived] = now;
    g_LastSavedBy[revived] = GetClientUserId(reviver);

    char sql[512];
    FormatEx(sql, sizeof sql,
        "INSERT INTO revive_events "
        ... "(server_id, match_round_id, reviver_id, revived_id, at, via_defib, chain_root, chain_depth) "
        ... "VALUES (%d, NULLIF(%d, 0), %d, %d, NOW(), %d, NULLIF(%d, 0), %d)",
        g_ServerId, Bizzy_Versus_GetRoundId(),
        g_Clients[reviver].playerId, g_Clients[revived].playerId,
        viaDefib ? 1 : 0, chainRoot, chainDepth);

    DataPack dp = new DataPack();
    dp.WriteCell(GetClientUserId(reviver));
    dp.WriteCell(GetClientUserId(revived));
    dp.WriteCell(chainRoot);
    g_DB.Query(OnReviveInserted, sql, dp);

    if (chainDepth >= 3)
        Bizzy_Awards_Fire(reviver, "chain_revive", 1);
}

static void OnReviveInserted(Database db, DBResultSet rs, const char[] error, DataPack dp)
{
    dp.Reset();
    int reviverUid = dp.ReadCell();
    int revivedUid = dp.ReadCell();
    int chainRoot  = dp.ReadCell();
    delete dp;
    if (rs == null) return;

    int newId = rs.InsertId;
    int reviver = GetClientOfUserId(reviverUid);
    if (Bizzy_IsValidPlayer(reviver))
    {
        g_LastReviveByUid[reviver] = GetTime();
        g_LastReviveByChainRoot[reviver] = (chainRoot != 0) ? chainRoot : newId;
    }
}

// -----------------------------------------------------------------------------
// Crescendo events
// -----------------------------------------------------------------------------

static int g_CrescendoOpenId = 0;
static int g_CrescendoOpenEpoch = 0;
static int g_CrescendoSurvivorsDown = 0;
static int g_CrescendoSurvivorsDied = 0;

stock void Bizzy_Coord_CrescendoStart(const char[] kind)
{
    if (g_DB == null || g_ServerId == 0) return;
    char kindEsc[48];
    Bizzy_DB_Escape(kind, kindEsc, sizeof kindEsc);
    g_CrescendoOpenEpoch = GetTime();
    g_CrescendoSurvivorsDown = 0;
    g_CrescendoSurvivorsDied = 0;

    char sql[384];
    FormatEx(sql, sizeof sql,
        "INSERT INTO crescendo_events "
        ... "(server_id, match_round_id, map_id, kind, started_at) "
        ... "VALUES (%d, NULLIF(%d, 0), %d, '%s', NOW())",
        g_ServerId, Bizzy_Versus_GetRoundId(), g_CurrentMapId, kindEsc);

    g_DB.Query(OnCrescendoInserted, sql);
}

static void OnCrescendoInserted(Database db, DBResultSet rs, const char[] error, any data)
{
    if (rs == null) return;
    g_CrescendoOpenId = rs.InsertId;
}

stock void Bizzy_Coord_CrescendoFinish()
{
    if (g_CrescendoOpenId == 0) return;
    int dur = GetTime() - g_CrescendoOpenEpoch;
    if (dur < 0) dur = 0;

    char outcome[16];
    if      (g_CrescendoSurvivorsDied >= 4) strcopy(outcome, sizeof outcome, "wiped");
    else if (g_CrescendoSurvivorsDied > 0)  strcopy(outcome, sizeof outcome, "partial");
    else                                    strcopy(outcome, sizeof outcome, "cleared");

    char sql[384];
    FormatEx(sql, sizeof sql,
        "UPDATE crescendo_events SET ended_at=NOW(), duration_s=%d, "
        ... "survivors_down=%d, survivors_died=%d, outcome='%s' "
        ... "WHERE id=%d",
        dur, g_CrescendoSurvivorsDown, g_CrescendoSurvivorsDied,
        outcome, g_CrescendoOpenId);
    Bizzy_DB_Exec(sql);

    // Per-player crescendo bookkeeping
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!Bizzy_IsValidPlayer(i)) continue;
        if (GetClientTeam(i) != TEAM_SURVIVORS) continue;
        if (StrEqual(outcome, "cleared"))
        {
            g_Clients[i].crescendosCleared++;
            Bizzy_Awards_Fire(i, "crescendo_cleared", 1);
        }
        else if (StrEqual(outcome, "wiped"))
        {
            g_Clients[i].crescendosWiped++;
        }
    }

    g_CrescendoOpenId = 0;
}

stock void Bizzy_Coord_OnIncapDuringCrescendo()
{
    if (g_CrescendoOpenId != 0) g_CrescendoSurvivorsDown++;
}

stock void Bizzy_Coord_OnDeathDuringCrescendo()
{
    if (g_CrescendoOpenId != 0) g_CrescendoSurvivorsDied++;
}

// -----------------------------------------------------------------------------
// Finale waves
// -----------------------------------------------------------------------------

static int g_WaveOpenId = 0;
static int g_WaveOpenEpoch = 0;
static int g_WaveSurvAtStart = 0;
static int g_WaveNumber = 0;

stock void Bizzy_Coord_WaveStart()
{
    if (g_DB == null || g_ServerId == 0) return;
    g_WaveNumber++;
    g_WaveOpenEpoch = GetTime();
    g_WaveSurvAtStart = CountAliveSurvivors();

    char sql[384];
    FormatEx(sql, sizeof sql,
        "INSERT INTO finale_waves "
        ... "(server_id, match_round_id, map_id, wave_number, started_at, survivors_alive_start) "
        ... "VALUES (%d, NULLIF(%d, 0), %d, %d, NOW(), %d)",
        g_ServerId, Bizzy_Versus_GetRoundId(), g_CurrentMapId,
        g_WaveNumber, g_WaveSurvAtStart);
    g_DB.Query(OnWaveInserted, sql);
}

static void OnWaveInserted(Database db, DBResultSet rs, const char[] error, any data)
{
    if (rs != null) g_WaveOpenId = rs.InsertId;
}

stock void Bizzy_Coord_WaveFinish()
{
    if (g_WaveOpenId == 0) return;
    int dur = GetTime() - g_WaveOpenEpoch;
    if (dur < 0) dur = 0;
    int aliveEnd = CountAliveSurvivors();
    bool survived = (aliveEnd > 0);

    char sql[384];
    FormatEx(sql, sizeof sql,
        "UPDATE finale_waves SET ended_at=NOW(), duration_s=%d, "
        ... "survivors_alive_end=%d, outcome='%s' WHERE id=%d",
        dur, aliveEnd, survived ? "survived" : "died", g_WaveOpenId);
    Bizzy_DB_Exec(sql);

    if (survived)
    {
        for (int i = 1; i <= MaxClients; i++)
        {
            if (!Bizzy_IsValidPlayer(i)) continue;
            if (GetClientTeam(i) != TEAM_SURVIVORS) continue;
            g_Clients[i].finaleWavesCleared++;
            Bizzy_Awards_Fire(i, "finale_wave_survived", 1);
        }
    }
    g_WaveOpenId = 0;
}

stock void Bizzy_Coord_ResetFinaleState()
{
    g_WaveOpenId = 0;
    g_WaveNumber = 0;
}

static int CountAliveSurvivors()
{
    int n = 0;
    for (int i = 1; i <= MaxClients; i++)
        if (IsClientInGame(i) && GetClientTeam(i) == TEAM_SURVIVORS && IsPlayerAlive(i))
            n++;
    return n;
}
