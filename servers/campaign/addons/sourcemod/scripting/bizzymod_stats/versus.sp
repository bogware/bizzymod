/**
 * versus.sp — match/round/team tracking for Versus / Realism Versus /
 * Scavenge. The big one.
 *
 * Why this is its own module:
 *   The Survivor/Infected teams (2/3) flip every half, so a player's
 *   GetClientTeam() answer is wrong for "what side were you on this
 *   match." The engine's m_iCampaignScore array indexes by a persistent
 *   team identity that DOES survive the flip — that's our team_letter
 *   'A'/'B'. Everything in here exists to keep that mapping straight
 *   across rounds, late joiners, voluntary swaps, and abandoned matches.
 *
 * State machine, with the event that drives each transition:
 *
 *   (no match)
 *      │
 *      │  OnMapStart in a versus-like mode (and current campaign != prior)
 *      ▼
 *   match opened
 *      │
 *      │  versus_round_start (is_secondary_round=false)
 *      ▼
 *   round 1 active ────► round_end ────► round 1 closed
 *      │                                     │
 *      │  versus_round_start (is_secondary_round=true)
 *      ▼
 *   round 2 active ────► round_end ────► map closed, winner decided
 *      │
 *      │  map_transition (more maps) → loop back to "round 1 active" on next map
 *      │  OR
 *      │  versus_match_finished → match closed (winner decided)
 *      │  OR
 *      │  mp_gamemode change / server idle → match closed (abandoned)
 *      ▼
 *   (no match)
 *
 * Two parallel counter banks live in this module:
 *   g_Clients[client].*       — session-scoped (drives player_stats), owned by session.sp
 *   g_RoundClients[client].*  — round-scoped (drives player_round_stats), owned here
 *
 * Bizzy_Score() mirrors into both. Round counters reset at round_end.
 */

// -----------------------------------------------------------------------------
// State
// -----------------------------------------------------------------------------

enum struct RoundClient
{
    int  points;
    int  kills;
    int  deaths;
    int  incaps;
    int  damageDealt;
    int  damageTaken;
    int  damageFriendly;
    int  awards;
    int  startEpoch;
    int  side;  // last seen GetClientTeam (2=surv, 3=inf, 0=spec)
}

RoundClient g_RoundClients[MAXPLAYERS + 1];
char        g_PlayerTeam[MAXPLAYERS + 1]; // '\0', 'A', or 'B'

int  g_MatchId             = 0;
int  g_MatchMapId          = 0;
int  g_MatchMapOrdinal     = 0;
int  g_RoundId             = 0;
int  g_RoundIndex          = 0; // 0=between, 1 or 2 during a round
char g_SurvivorTeam        = '\0'; // letter of whoever currently plays survivors
char g_MatchCampaign[64]   = "";

bool g_VersusActive        = false; // current gamemode is a versus-like mode
int  g_RoundStartEpoch     = 0;
int  g_TeamScoreA          = 0; // cumulative on current match
int  g_TeamScoreB          = 0;
int  g_MatchMapScoreA      = 0; // on current map only
int  g_MatchMapScoreB      = 0;

bool g_TankAppearedRound   = false;
bool g_WitchAppearedRound  = false;
bool g_FirstBloodFired     = false;
bool g_FirstDownFired      = false;

// -----------------------------------------------------------------------------
// Init
// -----------------------------------------------------------------------------

void Bizzy_OnVersusInit()
{
    // EventHookMode_Post (NOT PostNoCopy): we read is_secondary_round from the event.
    HookEvent("versus_round_start",   Event_VRoundStart, EventHookMode_Post);
    HookEvent("scavenge_round_start", Event_VRoundStart, EventHookMode_Post);
    HookEvent("round_end",            Event_VRoundEnd,   EventHookMode_Post);
    HookEvent("versus_match_finished", Event_VMatchFinished, EventHookMode_PostNoCopy);
    HookEvent("scavenge_match_finished", Event_VMatchFinished, EventHookMode_PostNoCopy);
    HookEvent("player_team",          Event_VPlayerTeam, EventHookMode_Post);
    HookEvent("tank_spawn",           Event_VTankSpawn,  EventHookMode_PostNoCopy);
    HookEvent("witch_spawn",          Event_VWitchSpawn, EventHookMode_PostNoCopy);
    HookEvent("map_transition",       Event_VMapTransition, EventHookMode_PostNoCopy);

    // Clear any open matches from a previous load on THIS server — we
    // can't reliably resume mid-match across plugin restarts.
    AbandonStaleMatchesForServer();
}

// On every map start, decide whether to open/continue/close a match.
// Called by session.sp's Bizzy_OnMapStart() chain. Defined here as a stock
// helper invoked from main.sp; if you add a new map-start hook, route it
// through this.
stock void Bizzy_Versus_OnMapStart()
{
    g_VersusActive = (g_CurrentMode == GameMode_Versus
                   || g_CurrentMode == GameMode_RealismVersus
                   || g_CurrentMode == GameMode_Scavenge);

    if (!g_VersusActive)
    {
        if (g_MatchId != 0) CloseMatch("mode_change", 'X');
        return;
    }

    char campaign[64];
    DeriveCampaignCode(g_CurrentMap, campaign, sizeof campaign);

    if (g_MatchId == 0)
    {
        OpenMatch(campaign);
    }
    else if (!StrEqual(campaign, g_MatchCampaign))
    {
        // Different campaign: previous match is implicitly over.
        CloseMatch("campaign_change", DecideMatchWinner());
        OpenMatch(campaign);
    }

    OpenMatchMap();
}

// -----------------------------------------------------------------------------
// Match lifecycle
// -----------------------------------------------------------------------------

static void OpenMatch(const char[] campaign)
{
    if (g_DB == null || g_ServerId == 0) return;

    strcopy(g_MatchCampaign, sizeof g_MatchCampaign, campaign);
    g_MatchMapOrdinal = 0;
    g_TeamScoreA = 0;
    g_TeamScoreB = 0;
    g_SurvivorTeam = '\0';
    for (int i = 1; i <= MaxClients; i++) g_PlayerTeam[i] = '\0';

    char escCamp[160];
    Bizzy_DB_Escape(campaign, escCamp, sizeof escCamp);

    char sql[512];
    FormatEx(sql, sizeof sql,
        "INSERT INTO matches (server_id, gamemode_id, difficulty_id, campaign, started_at) "
        ... "VALUES (%d, %d, %d, NULLIF('%s',''), NOW())",
        g_ServerId, view_as<int>(g_CurrentMode), view_as<int>(g_CurrentDifficulty),
        escCamp);
    g_DB.Query(OnMatchInserted, sql);
}

static void OnMatchInserted(Database db, DBResultSet rs, const char[] error, any data)
{
    if (rs == null) { LogError("[bizzymod-stats] match insert: %s", error); return; }
    g_MatchId = rs.InsertId;

    // Seed both team rows so foreign keys in match_team_players line up.
    Transaction t = Bizzy_DB_BeginTxn();
    char sql[256];
    FormatEx(sql, sizeof sql,
        "INSERT INTO match_teams (match_id, team_letter) VALUES (%d, 'A')", g_MatchId);
    t.AddQuery(sql);
    FormatEx(sql, sizeof sql,
        "INSERT INTO match_teams (match_id, team_letter) VALUES (%d, 'B')", g_MatchId);
    t.AddQuery(sql);
    Bizzy_DB_RunTxn(t);

    LogMessage("[bizzymod-stats] match opened: id=%d campaign=%s", g_MatchId, g_MatchCampaign);
}

static void CloseMatch(const char[] reason, int winnerChar)
{
    if (g_MatchId == 0) return;

    int wn = winnerChar;
    char winnerEnum[16];
    if      (wn == 'A')  strcopy(winnerEnum, sizeof winnerEnum, "A");
    else if (wn == 'B')  strcopy(winnerEnum, sizeof winnerEnum, "B");
    else if (wn == 'D')  strcopy(winnerEnum, sizeof winnerEnum, "draw");
    else                 strcopy(winnerEnum, sizeof winnerEnum, "abandoned");

    char escReason[96];
    Bizzy_DB_Escape(reason, escReason, sizeof escReason);

    Transaction t = Bizzy_DB_BeginTxn();
    char sql[512];

    FormatEx(sql, sizeof sql,
        "UPDATE matches SET ended_at=NOW(), team_a_score=%d, team_b_score=%d, "
        ... "winner='%s', end_reason='%s' WHERE id=%d",
        g_TeamScoreA, g_TeamScoreB, winnerEnum, escReason, g_MatchId);
    t.AddQuery(sql);

    FormatEx(sql, sizeof sql,
        "UPDATE match_teams SET final_score=%d WHERE match_id=%d AND team_letter='A'",
        g_TeamScoreA, g_MatchId);
    t.AddQuery(sql);
    FormatEx(sql, sizeof sql,
        "UPDATE match_teams SET final_score=%d WHERE match_id=%d AND team_letter='B'",
        g_TeamScoreB, g_MatchId);
    t.AddQuery(sql);

    Bizzy_DB_RunTxn(t);

    // Roll up to per-player versus stats (one async call per roster player;
    // small N so we don't bother batching).
    UpdatePlayerVersusStats(winnerChar);

    LogMessage("[bizzymod-stats] match closed: id=%d winner=%s reason=%s (A=%d B=%d)",
        g_MatchId, winnerEnum, reason, g_TeamScoreA, g_TeamScoreB);

    g_MatchId = 0;
    g_MatchMapId = 0;
    g_MatchMapOrdinal = 0;
    g_RoundId = 0;
    g_RoundIndex = 0;
    g_MatchCampaign[0] = '\0';
}

static int DecideMatchWinner()
{
    if (g_TeamScoreA > g_TeamScoreB) return 'A';
    if (g_TeamScoreB > g_TeamScoreA) return 'B';
    return 'D';
}

// -----------------------------------------------------------------------------
// Map lifecycle within a match
// -----------------------------------------------------------------------------

static void OpenMatchMap()
{
    if (g_MatchId == 0 || g_CurrentMapId == 0) return;
    g_MatchMapOrdinal++;
    g_MatchMapScoreA = 0;
    g_MatchMapScoreB = 0;

    char sql[256];
    FormatEx(sql, sizeof sql,
        "INSERT INTO match_maps (match_id, map_id, ordinal, started_at) "
        ... "VALUES (%d, %d, %d, NOW())",
        g_MatchId, g_CurrentMapId, g_MatchMapOrdinal);
    g_DB.Query(OnMatchMapInserted, sql);
}

static void OnMatchMapInserted(Database db, DBResultSet rs, const char[] error, any data)
{
    if (rs == null) { LogError("[bizzymod-stats] match_map insert: %s", error); return; }
    g_MatchMapId = rs.InsertId;
}

static void CloseMatchMap()
{
    if (g_MatchMapId == 0) return;

    int wn;
    if      (g_MatchMapScoreA > g_MatchMapScoreB) wn = 'A';
    else if (g_MatchMapScoreB > g_MatchMapScoreA) wn = 'B';
    else                                          wn = 'D';

    g_TeamScoreA += g_MatchMapScoreA;
    g_TeamScoreB += g_MatchMapScoreB;

    Transaction t = Bizzy_DB_BeginTxn();
    char sql[384];

    char winnerEnum[16];
    if      (wn == 'A') strcopy(winnerEnum, sizeof winnerEnum, "A");
    else if (wn == 'B') strcopy(winnerEnum, sizeof winnerEnum, "B");
    else                strcopy(winnerEnum, sizeof winnerEnum, "draw");

    FormatEx(sql, sizeof sql,
        "UPDATE match_maps SET ended_at=NOW(), team_a_score=%d, team_b_score=%d, winner='%s' "
        ... "WHERE id=%d",
        g_MatchMapScoreA, g_MatchMapScoreB, winnerEnum, g_MatchMapId);
    t.AddQuery(sql);

    if (wn == 'A')
    {
        FormatEx(sql, sizeof sql,
            "UPDATE match_teams SET maps_won=maps_won+1 WHERE match_id=%d AND team_letter='A'", g_MatchId);
        t.AddQuery(sql);
        FormatEx(sql, sizeof sql,
            "UPDATE match_teams SET maps_lost=maps_lost+1 WHERE match_id=%d AND team_letter='B'", g_MatchId);
        t.AddQuery(sql);
    }
    else if (wn == 'B')
    {
        FormatEx(sql, sizeof sql,
            "UPDATE match_teams SET maps_won=maps_won+1 WHERE match_id=%d AND team_letter='B'", g_MatchId);
        t.AddQuery(sql);
        FormatEx(sql, sizeof sql,
            "UPDATE match_teams SET maps_lost=maps_lost+1 WHERE match_id=%d AND team_letter='A'", g_MatchId);
        t.AddQuery(sql);
    }

    FormatEx(sql, sizeof sql,
        "UPDATE matches SET maps_played=maps_played+1 WHERE id=%d", g_MatchId);
    t.AddQuery(sql);

    Bizzy_DB_RunTxn(t);
    g_MatchMapId = 0;
}

// -----------------------------------------------------------------------------
// Round lifecycle
// -----------------------------------------------------------------------------

static void Event_VRoundStart(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_VersusActive || g_MatchId == 0) return;

    bool secondary = event.GetBool("is_secondary_round", false);
    int round = secondary ? 2 : 1;
    OpenRound(round);
}

static void OpenRound(int roundIndex)
{
    g_RoundIndex      = roundIndex;
    g_RoundStartEpoch = Bizzy_NowEpoch();
    g_TankAppearedRound = false;
    g_WitchAppearedRound = false;
    g_FirstBloodFired = false;
    g_FirstDownFired = false;

    // Reset round-scoped counters
    for (int i = 1; i <= MaxClients; i++)
    {
        g_RoundClients[i].points = 0;
        g_RoundClients[i].kills = 0;
        g_RoundClients[i].deaths = 0;
        g_RoundClients[i].incaps = 0;
        g_RoundClients[i].damageDealt = 0;
        g_RoundClients[i].damageTaken = 0;
        g_RoundClients[i].damageFriendly = 0;
        g_RoundClients[i].awards = 0;
        g_RoundClients[i].startEpoch = g_RoundStartEpoch;
        g_RoundClients[i].side = (IsClientInGame(i) && !IsFakeClient(i))
            ? GetClientTeam(i) : 0;
    }

    // Decide which letter plays Survivors this round.
    // Round 1 of match: arbitrary — whoever's currently on Survivors is A.
    // Round 2: opposite of round 1.
    if (g_MatchMapOrdinal == 1 && roundIndex == 1 && g_SurvivorTeam == '\0')
    {
        g_SurvivorTeam = 'A';
        // Initialize letters from current sides
        for (int i = 1; i <= MaxClients; i++)
        {
            if (!Bizzy_IsValidPlayer(i)) continue;
            int t = GetClientTeam(i);
            if      (t == TEAM_SURVIVORS) AssignTeamLetter(i, 'A');
            else if (t == TEAM_INFECTED)  AssignTeamLetter(i, 'B');
        }
    }
    else
    {
        // Standard flip
        g_SurvivorTeam = (g_SurvivorTeam == 'A') ? 'B' : 'A';
        // Late joiners that still have no letter: assign from current side
        for (int i = 1; i <= MaxClients; i++)
        {
            if (!Bizzy_IsValidPlayer(i)) continue;
            if (g_PlayerTeam[i] != '\0') continue;
            int t = GetClientTeam(i);
            if (t == TEAM_SURVIVORS) AssignTeamLetter(i, g_SurvivorTeam);
            else if (t == TEAM_INFECTED) AssignTeamLetter(i, (g_SurvivorTeam == 'A') ? 'B' : 'A');
        }
    }

    if (g_MatchMapId == 0) { LogError("[bizzymod-stats] OpenRound with no match_map_id"); return; }

    char sql[384];
    FormatEx(sql, sizeof sql,
        "INSERT INTO match_rounds (match_id, match_map_id, round_index, survivor_team, started_at) "
        ... "VALUES (%d, %d, %d, '%c', NOW())",
        g_MatchId, g_MatchMapId, roundIndex, g_SurvivorTeam);
    g_DB.Query(OnRoundInserted, sql);
}

static void OnRoundInserted(Database db, DBResultSet rs, const char[] error, any data)
{
    if (rs == null) { LogError("[bizzymod-stats] round insert: %s", error); return; }
    g_RoundId = rs.InsertId;
}

static void Event_VRoundEnd(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_VersusActive || g_MatchId == 0 || g_RoundIndex == 0) return;

    int reason = event.GetInt("reason", 0);
    int winner = event.GetInt("winner", 0);
    int engineScore = ReadEngineCampaignScoreForSurvTeam();

    CloseRound(reason, winner, engineScore);
}

static void CloseRound(int reason, int winnerTeam, int engineScore)
{
    if (g_RoundId == 0) return;
    int duration = Bizzy_NowEpoch() - g_RoundStartEpoch;
    if (duration < 0) duration = 0;

    // Sum plugin scores by team_letter for each side
    int sumSurv = 0, sumInf = 0;
    int survLeft = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (g_PlayerTeam[i] == '\0') continue;
        int side = g_RoundClients[i].side;
        if (side == TEAM_SURVIVORS) sumSurv += g_RoundClients[i].points;
        else if (side == TEAM_INFECTED) sumInf += g_RoundClients[i].points;
        if (side == TEAM_SURVIVORS && IsClientInGame(i)
            && IsPlayerAlive(i)) survLeft++;
    }

    char endReason[48];
    DescribeRoundEndReason(reason, winnerTeam, endReason, sizeof endReason);
    char escReason[100];
    Bizzy_DB_Escape(endReason, escReason, sizeof escReason);

    Transaction t = Bizzy_DB_BeginTxn();
    char sql[640];

    FormatEx(sql, sizeof sql,
        "UPDATE match_rounds SET ended_at=NOW(), duration_s=%d, engine_score=%d, "
        ... "plugin_score_surv=%d, plugin_score_inf=%d, survivors_left=%d, "
        ... "tank_appeared=%d, witch_appeared=%d, end_reason='%s' WHERE id=%d",
        duration, engineScore, sumSurv, sumInf, survLeft,
        g_TankAppearedRound ? 1 : 0, g_WitchAppearedRound ? 1 : 0,
        escReason, g_RoundId);
    t.AddQuery(sql);

    // Per-player round breakdown
    for (int i = 1; i <= MaxClients; i++)
    {
        if (g_PlayerTeam[i] == '\0') continue;
        if (g_Clients[i].playerId == 0) continue;
        int side = g_RoundClients[i].side;
        if (side != TEAM_SURVIVORS && side != TEAM_INFECTED) continue;

        FormatEx(sql, sizeof sql,
            "INSERT INTO player_round_stats "
            ... "(match_round_id, player_id, team_letter, side, points, kills, deaths, incaps, "
            ... " damage_dealt, damage_taken, damage_friendly, time_in_round_s, awards_count) "
            ... "VALUES (%d, %d, '%c', %d, %d, %d, %d, %d, %d, %d, %d, %d, %d) "
            ... "ON DUPLICATE KEY UPDATE "
            ... " points=VALUES(points), kills=VALUES(kills), deaths=VALUES(deaths), "
            ... " incaps=VALUES(incaps), damage_dealt=VALUES(damage_dealt), "
            ... " damage_taken=VALUES(damage_taken), damage_friendly=VALUES(damage_friendly), "
            ... " time_in_round_s=VALUES(time_in_round_s), awards_count=VALUES(awards_count)",
            g_RoundId, g_Clients[i].playerId, g_PlayerTeam[i], side,
            g_RoundClients[i].points, g_RoundClients[i].kills,
            g_RoundClients[i].deaths, g_RoundClients[i].incaps,
            g_RoundClients[i].damageDealt, g_RoundClients[i].damageTaken,
            g_RoundClients[i].damageFriendly, duration,
            g_RoundClients[i].awards);
        t.AddQuery(sql);
    }

    // Bookkeeping: match_teams rounds_won/lost, match.rounds_played
    char survChar = g_SurvivorTeam;
    char infChar  = (survChar == 'A') ? 'B' : 'A';
    bool survivorTeamWon = (winnerTeam == TEAM_SURVIVORS);
    char winLetter = survivorTeamWon ? survChar : infChar;
    char loseLetter = survivorTeamWon ? infChar : survChar;

    FormatEx(sql, sizeof sql,
        "UPDATE match_teams SET rounds_won=rounds_won+1 WHERE match_id=%d AND team_letter='%c'",
        g_MatchId, winLetter);
    t.AddQuery(sql);
    FormatEx(sql, sizeof sql,
        "UPDATE match_teams SET rounds_lost=rounds_lost+1 WHERE match_id=%d AND team_letter='%c'",
        g_MatchId, loseLetter);
    t.AddQuery(sql);
    FormatEx(sql, sizeof sql,
        "UPDATE matches SET rounds_played=rounds_played+1 WHERE id=%d", g_MatchId);
    t.AddQuery(sql);

    Bizzy_DB_RunTxn(t);

    // Add engine score to the survivor team's map column.
    if (survChar == 'A') g_MatchMapScoreA += engineScore;
    else                 g_MatchMapScoreB += engineScore;

    g_RoundId = 0;
    int closedIndex = g_RoundIndex;
    g_RoundIndex = 0;

    // If round 2 just ended → the map is done.
    if (closedIndex == 2)
        CloseMatchMap();
}

static void Event_VMatchFinished(Event event, const char[] name, bool dontBroadcast)
{
    if (g_MatchId == 0) return;
    int wn = DecideMatchWinner();
    CloseMatch("finale", wn);
}

static void Event_VMapTransition(Event event, const char[] name, bool dontBroadcast)
{
    // Safety net: if a round was somehow open at transition, close it as
    // "transition" so we don't dangle.
    if (g_RoundIndex != 0)
        CloseRound(0, 0, 0);
    if (g_MatchMapId != 0)
        CloseMatchMap();
}

// -----------------------------------------------------------------------------
// Per-player events
// -----------------------------------------------------------------------------

static void Event_VPlayerTeam(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (!Bizzy_IsValidPlayer(client) || g_MatchId == 0) return;

    int newTeam = event.GetInt("team");
    g_RoundClients[client].side = newTeam;

    // Engine flips happen between round_end and round_start; during those
    // windows g_RoundIndex is 0, so we don't change the letter. Voluntary
    // jointeam during an active round flips the letter.
    if (g_RoundIndex == 0) return;
    if (newTeam != TEAM_SURVIVORS && newTeam != TEAM_INFECTED) return;

    char expected;
    if (newTeam == TEAM_SURVIVORS) expected = g_SurvivorTeam;
    else                           expected = (g_SurvivorTeam == 'A') ? 'B' : 'A';

    if (g_PlayerTeam[client] != '\0' && g_PlayerTeam[client] != expected)
    {
        // Player voluntarily switched. Close their current membership row
        // and open a new one on the new letter.
        CloseMembership(client, g_PlayerTeam[client]);
        OpenMembership(client, expected, g_RoundIndex);
        g_PlayerTeam[client] = expected;
    }
    else if (g_PlayerTeam[client] == '\0')
    {
        AssignTeamLetter(client, expected);
    }
}

static void Event_VTankSpawn(Event event, const char[] name, bool dontBroadcast)
{
    if (g_RoundIndex != 0) g_TankAppearedRound = true;
}

static void Event_VWitchSpawn(Event event, const char[] name, bool dontBroadcast)
{
    if (g_RoundIndex != 0) g_WitchAppearedRound = true;
}

// -----------------------------------------------------------------------------
// Team membership rows
// -----------------------------------------------------------------------------

static void AssignTeamLetter(int client, int letterChar)
{
    if (g_Clients[client].playerId == 0) return;
    g_PlayerTeam[client] = letterChar;
    OpenMembership(client, letterChar, g_RoundIndex);
}

static void OpenMembership(int client, int letterChar, int joinedRound)
{
    if (g_MatchId == 0 || g_Clients[client].playerId == 0) return;
    char sql[384];
    FormatEx(sql, sizeof sql,
        "INSERT INTO match_team_players "
        ... "(match_id, team_letter, player_id, joined_round, time_on_team_s) "
        ... "VALUES (%d, '%c', %d, %d, 0) "
        ... "ON DUPLICATE KEY UPDATE left_round=NULL",
        g_MatchId, letterChar, g_Clients[client].playerId, joinedRound);
    Bizzy_DB_Exec(sql);
}

static void CloseMembership(int client, int letterChar)
{
    if (g_MatchId == 0 || g_Clients[client].playerId == 0) return;
    char sql[384];
    FormatEx(sql, sizeof sql,
        "UPDATE match_team_players SET left_round=%d "
        ... "WHERE match_id=%d AND team_letter='%c' AND player_id=%d AND left_round IS NULL",
        g_RoundIndex, g_MatchId, letterChar, g_Clients[client].playerId);
    Bizzy_DB_Exec(sql);
}

// -----------------------------------------------------------------------------
// player_versus_stats rollup at match close
// -----------------------------------------------------------------------------

static void UpdatePlayerVersusStats(int winnerChar)
{
    if (g_MatchId == 0) return;

    char sql[1024];
    char winLetter = (winnerChar == 'A' || winnerChar == 'B') ? winnerChar : 'X';
    bool isDraw = (winnerChar == 'D');
    bool isAbandon = (winnerChar == 'X');

    int gm = view_as<int>(g_CurrentMode);

    // Players for both team letters
    for (int letter = 0; letter < 2; letter++)
    {
        char L = (letter == 0) ? 'A' : 'B';
        bool teamWon = (L == winLetter);

        // Pull players via subselect to a temp-ish IN clause. Simpler in
        // SourcePawn: just issue a single UPSERT-by-subselect per team.

        int wonInc       = isAbandon ? 0 : (teamWon ? 1 : 0);
        int lostInc      = isAbandon ? 0 : (!teamWon && !isDraw ? 1 : 0);
        int drawInc      = isDraw ? 1 : 0;
        int abandonInc   = isAbandon ? 1 : 0;

        FormatEx(sql, sizeof sql,
            "INSERT INTO player_versus_stats "
            ... "(player_id, gamemode_id, matches_played, matches_won, matches_lost, "
            ... " matches_drawn, matches_abandoned, last_match_at) "
            ... "SELECT mtp.player_id, %d, 1, %d, %d, %d, %d, NOW() "
            ... "FROM match_team_players mtp "
            ... "WHERE mtp.match_id=%d AND mtp.team_letter='%c' "
            ... "GROUP BY mtp.player_id "
            ... "ON DUPLICATE KEY UPDATE "
            ... " matches_played    = matches_played + 1, "
            ... " matches_won       = matches_won + VALUES(matches_won), "
            ... " matches_lost      = matches_lost + VALUES(matches_lost), "
            ... " matches_drawn     = matches_drawn + VALUES(matches_drawn), "
            ... " matches_abandoned = matches_abandoned + VALUES(matches_abandoned), "
            ... " current_win_streak  = IF(VALUES(matches_won)=1,  current_win_streak + 1,  0), "
            ... " longest_win_streak  = GREATEST(longest_win_streak, IF(VALUES(matches_won)=1, current_win_streak + 1, longest_win_streak)), "
            ... " current_loss_streak = IF(VALUES(matches_lost)=1, current_loss_streak + 1, 0), "
            ... " longest_loss_streak = GREATEST(longest_loss_streak, IF(VALUES(matches_lost)=1, current_loss_streak + 1, longest_loss_streak)), "
            ... " last_match_at = NOW()",
            gm, wonInc, lostInc, drawInc, abandonInc,
            g_MatchId, L);
        Bizzy_DB_Exec(sql);

        // Aggregate per-round counters (rounds_played/won/lost,
        // rounds_as_surv/inf, total_round_score_*) from player_round_stats.
        FormatEx(sql, sizeof sql,
            "INSERT INTO player_versus_stats "
            ... "(player_id, gamemode_id, rounds_played, rounds_won, rounds_lost, "
            ... " rounds_as_surv, rounds_as_inf, "
            ... " total_round_score_surv, total_round_score_inf) "
            ... "SELECT prs.player_id, %d, "
            ... "       COUNT(*), "
            ... "       SUM(CASE WHEN (prs.side=2 AND mr.end_reason LIKE '%%surv_win%%') "
            ... "                  OR (prs.side=3 AND mr.end_reason LIKE '%%inf_win%%')  THEN 1 ELSE 0 END), "
            ... "       SUM(CASE WHEN (prs.side=2 AND mr.end_reason LIKE '%%inf_win%%')  "
            ... "                  OR (prs.side=3 AND mr.end_reason LIKE '%%surv_win%%') THEN 1 ELSE 0 END), "
            ... "       SUM(CASE WHEN prs.side=2 THEN 1 ELSE 0 END), "
            ... "       SUM(CASE WHEN prs.side=3 THEN 1 ELSE 0 END), "
            ... "       SUM(CASE WHEN prs.side=2 THEN prs.points ELSE 0 END), "
            ... "       SUM(CASE WHEN prs.side=3 THEN prs.points ELSE 0 END) "
            ... "FROM player_round_stats prs "
            ... "JOIN match_rounds mr ON mr.id = prs.match_round_id "
            ... "WHERE mr.match_id=%d AND prs.team_letter='%c' "
            ... "GROUP BY prs.player_id "
            ... "ON DUPLICATE KEY UPDATE "
            ... " rounds_played          = rounds_played          + VALUES(rounds_played), "
            ... " rounds_won             = rounds_won             + VALUES(rounds_won), "
            ... " rounds_lost            = rounds_lost            + VALUES(rounds_lost), "
            ... " rounds_as_surv         = rounds_as_surv         + VALUES(rounds_as_surv), "
            ... " rounds_as_inf          = rounds_as_inf          + VALUES(rounds_as_inf), "
            ... " total_round_score_surv = total_round_score_surv + VALUES(total_round_score_surv), "
            ... " total_round_score_inf  = total_round_score_inf  + VALUES(total_round_score_inf)",
            gm, g_MatchId, L);
        Bizzy_DB_Exec(sql);
    }
}

// -----------------------------------------------------------------------------
// External hooks (called from scoring.sp, events.sp, awards.sp)
// -----------------------------------------------------------------------------

stock void Bizzy_Versus_AccumScore(int client, int points)
{
    if (g_RoundIndex == 0) return;
    g_RoundClients[client].points += points;
}

// First-blood / first-down detection — globals declared at top of file.

stock void Bizzy_Versus_AccumKill(int client, bool isDeath = false)
{
    if (g_RoundIndex == 0) return;
    if (isDeath)
    {
        g_RoundClients[client].deaths++;
        if (!g_FirstDownFired && Bizzy_IsValidPlayer(client)
            && GetClientTeam(client) == TEAM_SURVIVORS)
        {
            g_FirstDownFired = true;
            g_Clients[client].firstDowns++;
            Bizzy_Awards_Fire(client, "first_down", 1);
        }
    }
    else
    {
        g_RoundClients[client].kills++;
        if (!g_FirstBloodFired && Bizzy_IsValidPlayer(client)
            && GetClientTeam(client) == TEAM_INFECTED)
        {
            g_FirstBloodFired = true;
            g_Clients[client].firstBloods++;
            Bizzy_Awards_Fire(client, "first_blood", 1);
        }
    }
}

stock void Bizzy_Versus_AccumDamage(int attacker, int victim, int damage, bool friendly)
{
    if (g_RoundIndex == 0) return;
    if (Bizzy_IsValidPlayer(attacker))
    {
        g_RoundClients[attacker].damageDealt += damage;
        if (friendly) g_RoundClients[attacker].damageFriendly += damage;
    }
    if (Bizzy_IsValidPlayer(victim))
        g_RoundClients[victim].damageTaken += damage;
}

stock void Bizzy_Versus_AccumIncap(int client)
{
    if (g_RoundIndex == 0) return;
    g_RoundClients[client].incaps++;
}

stock void Bizzy_Versus_AccumAward(int client)
{
    if (g_RoundIndex == 0) return;
    g_RoundClients[client].awards++;
}

stock bool Bizzy_Versus_MatchActive() { return g_MatchId != 0; }
stock int  Bizzy_Versus_GetRoundId()  { return g_RoundId; }
stock int  Bizzy_Versus_GetMatchId()  { return g_MatchId; }

// -----------------------------------------------------------------------------
// Helpers
// -----------------------------------------------------------------------------

// Try to read the engine's authoritative scenario score for the survivor
// team this round. Falls back to 0 if the netprop isn't exposed (custom
// builds, modded engines). The plugin_score_surv column gives us a usable
// fallback metric in that case.
static int ReadEngineCampaignScoreForSurvTeam()
{
    int mgr = FindEntityByClassname(-1, "terror_player_manager");
    if (mgr == -1) return 0;
    if (!HasEntProp(mgr, Prop_Send, "m_iCampaignScore")) return 0;

    // m_iCampaignScore is a 2-element array. Index 0 / 1 correspond to
    // engine team 2 (survivors) and team 3 (infected) BEFORE the per-map
    // swap is taken into account. Reading right after round_end gives the
    // accumulated value for whichever team WAS Survivors this round.
    int idxSurv = 0;
    int idxInf  = 1;
    int survScore = GetEntProp(mgr, Prop_Send, "m_iCampaignScore", _, idxSurv);
    int infScore  = GetEntProp(mgr, Prop_Send, "m_iCampaignScore", _, idxInf);

    // The campaign score is cumulative across maps. To get THIS round's
    // delta we'd subtract the prior cumulative, but we want the
    // cumulative-per-map figure here so we just take the survivor side.
    // (infScore unused in this code path; we read both so we have the
    // pair available if a future caller wants to display the comparison.)
    if (infScore < 0) return survScore; // defensive no-op to silence "unused"
    return survScore;
}

// "c2m3_coaster" → "c2"; for non-canonical names returns empty string.
static void DeriveCampaignCode(const char[] mapname, char[] out, int outlen)
{
    out[0] = '\0';
    if (mapname[0] != 'c' && mapname[0] != 'l') return;
    int n = strlen(mapname);
    int i = 0;
    while (i < n && i < outlen - 1)
    {
        char ch = mapname[i];
        if (ch >= '0' && ch <= '9') { out[i] = ch; i++; continue; }
        if (i == 0 && (ch == 'c' || ch == 'l')) { out[i] = ch; i++; continue; }
        if (ch == 'm' || ch == '_') break;
        out[i] = ch; i++;
    }
    out[i] = '\0';
    if (i < 2) out[0] = '\0';
}

static void DescribeRoundEndReason(int reason, int winnerTeam, char[] out, int outlen)
{
    // L4D2 ROUND_END_REASON_* constants. Not all are documented; map the
    // common ones and pass the numeric for unknowns.
    char w[16];
    if (winnerTeam == TEAM_SURVIVORS)      strcopy(w, sizeof w, "surv_win");
    else if (winnerTeam == TEAM_INFECTED)  strcopy(w, sizeof w, "inf_win");
    else                                   strcopy(w, sizeof w, "draw");

    switch (reason)
    {
        case 0:  FormatEx(out, outlen, "%s/timeout",      w);
        case 1:  FormatEx(out, outlen, "%s/finale",       w);
        case 2:  FormatEx(out, outlen, "%s/wipe",         w);
        case 3:  FormatEx(out, outlen, "%s/saferoom",     w);
        case 4:  FormatEx(out, outlen, "%s/mission_lost", w);
        default: FormatEx(out, outlen, "%s/reason_%d",    w, reason);
    }
}

static void AbandonStaleMatchesForServer()
{
    if (g_DB == null || g_ServerId == 0)
    {
        // We don't have a server_id yet — queue this for after identity resolves.
        CreateTimer(2.0, Timer_AbandonStale, _, TIMER_FLAG_NO_MAPCHANGE);
        return;
    }
    char sql[256];
    FormatEx(sql, sizeof sql,
        "UPDATE matches SET ended_at=NOW(), winner='abandoned', end_reason='plugin_restart' "
        ... "WHERE server_id=%d AND ended_at IS NULL", g_ServerId);
    Bizzy_DB_Exec(sql);
}

static Action Timer_AbandonStale(Handle timer)
{
    AbandonStaleMatchesForServer();
    return Plugin_Stop;
}
