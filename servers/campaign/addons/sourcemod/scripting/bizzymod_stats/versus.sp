/**
 * versus.sp — match/map/round tracking for Versus / Realism Versus / Scavenge.
 *
 * Terminology (this is where people trip up):
 *   match  = one whole campaign (all chapters). Rarely finishes — players leave.
 *   map    = one CHAPTER, i.e. BOTH halves (you play Survivor once and Infected
 *            once). This is what a player colloquially calls "a round of versus",
 *            and it reliably completes because you must finish it to progress.
 *   round  = one HALF (one team on Survivors). Two per map.
 *
 * Because whole matches almost never finish, per-player versus stats are rolled
 * up PER MAP (per chapter) at chapter close — not at match close.
 *
 * ── Async coordination (this build resolves ids via async DB callbacks) ──
 * g_CurrentMapId is resolved by a 2-hop async chain (INSERT maps -> SELECT id ->
 * OnMapLookup) and is STALE during the synchronous OnMapStart handler. So chapter
 * boundaries are detected on the synchronously-fresh engine map NAME (g_CurrentMap
 * vs g_ChapterMapName), but the match_maps row is only opened once the id is
 * actually resolved. The open is driven by TryOpenPendingChapter(), called from
 * BOTH OnMapLookup (id ready) and OnMatchInserted (match id ready) — whichever
 * lands last opens the chapter. Latches (g_ChapterPending / g_RoundLivePending /
 * g_ChapterOpening / g_MapIdFresh) bridge the async gaps so no chapter or half is
 * dropped because an id hadn't landed yet.
 *
 * ── Round liveness (real half vs phantom) ──
 * mutation12 fires spurious round_starts during ready-up / the scenario restart
 * BETWEEN a chapter's two survivor runs. A round_start only opens a CANDIDATE
 * window; it is counted as a real half (ordinal + match_rounds row) only once it
 * goes LIVE — survivors leave the saferoom (player_left_start_area) or real combat
 * happens. A phantom never goes live, so at round_end it is discarded without
 * consuming the chapter's 2-half quota — which is what lets the real SECOND
 * survivor run be captured instead of being blocked.
 *
 * ── Chapter boundaries (map NAME) ──
 * On mutation12 the engine fires OnMapStart more than once per chapter (a scenario
 * restart between the halves, and often another after them). A new match_map opens
 * ONLY when the engine map NAME changes; same-map restarts are ignored, and the
 * two halves are gated by g_MapRoundOrdinal (<2). This kills the ghost/duplicate
 * match_maps.
 *
 * ── Sides / survivor team (settled sides + forced alternation) ──
 * The engine's per-half side swap RACES round_start inconsistently on this build,
 * so a round_start-time side read is unreliable. The two halves of a chapter ALWAYS
 * alternate which team plays Survivors, so we ANCHOR the chapter's first-half
 * survivor letter from the settled round_end sides (stable at a chapter's start)
 * and FORCE the second half to the opposite letter. Team letters (persistent A/B)
 * are anchored once from the match's first half; a player's SIDE flips each half,
 * their LETTER never does. Per-player side is then DERIVED from (letter ==
 * survivor-letter-this-half), which is robust to the swap-timing race, and the
 * letter is cleared on disconnect so a reused client slot can't inherit it.
 *
 * Two parallel counter banks:
 *   g_Clients[client].*       — session-scoped (drives player_stats), owned by session.sp
 *   g_RoundClients[client].*  — round(half)-scoped (drives player_round_stats), owned here
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
    int  side;  // last seen GetClientTeam (2=surv, 3=inf, 0=spec) — used to detect "played"
}

RoundClient g_RoundClients[MAXPLAYERS + 1];
char        g_PlayerTeam[MAXPLAYERS + 1]; // '\0', 'A', or 'B' (persistent team letter)

int  g_MatchId             = 0;
bool g_MatchOpening        = false; // matches INSERT dispatched, awaiting OnMatchInserted
bool g_MatchAnchored       = false; // team letters anchored from the match's first half
int  g_MatchMapId          = 0;
bool g_ChapterOpening      = false; // match_maps INSERT dispatched, awaiting OnMatchMapInserted
bool g_ChapterPending      = false; // a chapter should (re)open once match_id + map_id are ready
bool g_MapIdFresh          = false; // g_CurrentMapId is resolved for the CURRENT engine map
char g_ChapterMapName[128] = "";    // engine map NAME of the open chapter (boundary key)
int  g_MatchMapOrdinal     = 0;     // chapter number within the match (1..N)
int  g_MatchCompleteChapters = 0;   // chapters that finished BOTH halves (gates match W/L)
int  g_MapRoundOrdinal     = 0;     // halves opened on the CURRENT chapter (0,1,2)
int  g_RoundId             = 0;
int  g_RoundIndex          = 0;     // LIVE half index (1 or 2); 0 = no live half open
bool g_RoundActive         = false; // a round_start fired; inside the round_start..round_end window
bool g_RoundLive           = false; // survivors went LIVE (left saferoom / real combat) = a real half
bool g_RoundLivePending    = false; // went live before the chapter's match_map id was ready
char g_SurvivorTeam        = '\0';  // letter on Survivors THIS half
char g_ChapterFirstHalfSurv = '\0'; // survivor letter of the chapter's first half (for forced flip)
char g_MatchCampaign[64]   = "";

bool g_VersusActive        = false; // current gamemode is a versus-like mode
int  g_RoundStartEpoch     = 0;
int  g_RoundLiveEpoch      = 0;     // epoch the round went LIVE; duration_s is measured from here (not round_start) so it excludes the pre-round ready-up window
int  g_TeamScoreA          = 0; // cumulative on current match
int  g_TeamScoreB          = 0;
int  g_MatchMapPluginA     = 0; // plugin Survivor points on current chapter (drives the winner)
int  g_MatchMapPluginB     = 0;

// ReadyUp's IsInReady() native — forward-declared and marked OPTIONAL in
// AskPluginLoad2 so this multi-mode plugin still loads on coop servers that don't
// run readyup.smx. Used only to suppress the combat liveness fallback during the
// ready-up window between a chapter's two runs (see MaybeMarkLiveFromCombat).
native bool IsInReady();

bool g_TankAppearedRound   = false;
bool g_WitchAppearedRound  = false;
bool g_FirstBloodFired     = false;
bool g_FirstDownFired      = false;

// -----------------------------------------------------------------------------
// Init
// -----------------------------------------------------------------------------

void Bizzy_OnVersusInit()
{
    HookEventEx("round_start",           Event_VRoundStart, EventHookMode_PostNoCopy);
    HookEventEx("round_end",             Event_VRoundEnd,   EventHookMode_Post);
    HookEventEx("versus_match_finished", Event_VMatchFinished, EventHookMode_PostNoCopy);
    HookEventEx("scavenge_match_finished", Event_VMatchFinished, EventHookMode_PostNoCopy);
    HookEventEx("player_team",           Event_VPlayerTeam, EventHookMode_Post);
    HookEventEx("tank_spawn",            Event_VTankSpawn,  EventHookMode_PostNoCopy);
    HookEventEx("witch_spawn",           Event_VWitchSpawn, EventHookMode_PostNoCopy);
    HookEventEx("map_transition",        Event_VMapTransition, EventHookMode_PostNoCopy);
    // "Round went LIVE" signal: survivors leaving the start saferoom. A ready-up /
    // scenario-restart phantom round_start never fires this, so it's how we tell a
    // real half from a phantom (combat is the fallback — see MarkRoundLive).
    HookEventEx("player_left_start_area",  Event_VRoundWentLive, EventHookMode_PostNoCopy);
    HookEventEx("player_left_safe_area",   Event_VRoundWentLive, EventHookMode_PostNoCopy);

    AbandonStaleMatchesForServer();
}

// On every map start, decide whether to open/continue/close a match.
// Called by session.sp's Bizzy_OnMapStart() chain, SYNCHRONOUSLY — so g_CurrentMap
// (the NAME) is fresh but g_CurrentMapId (the DB id) is NOT yet resolved.
stock void Bizzy_Versus_OnMapStart()
{
    g_VersusActive = (g_CurrentMode == GameMode_Versus
                   || g_CurrentMode == GameMode_RealismVersus
                   || g_CurrentMode == GameMode_Scavenge);

    // g_CurrentMapId is stale until this map's OnMapLookup callback lands.
    g_MapIdFresh = false;

    if (!g_VersusActive)
    {
        if (g_MatchId != 0) CloseMatch("mode_change");
        g_ChapterPending = false;
        return;
    }

    char campaign[64];
    DeriveCampaignCode(g_CurrentMap, campaign, sizeof campaign);

    if (g_MatchId == 0)
    {
        if (!g_MatchOpening) OpenMatch(campaign);
        g_ChapterPending = true;
    }
    else if (campaign[0] != '\0' && !StrEqual(campaign, g_MatchCampaign))
    {
        // Different campaign — previous match is over. (Empty campaign = unknown
        // map name; do NOT force a change on it, that would split one match.)
        CloseMatch("campaign_change");
        OpenMatch(campaign);
        g_ChapterPending = true;
    }
    else
    {
        // Same match — TryOpenPendingChapter (fired once the id resolves) decides
        // by NAME whether this is a genuinely new chapter or a same-map reload.
        g_ChapterPending = true;
    }
    // Do not open here: g_MapIdFresh is false. The chapter opens from OnMapLookup
    // (id ready) and/or OnMatchInserted (match id ready).
}

// Called from identity.sp OnMapLookup once g_CurrentMapId is resolved for this map.
void Bizzy_Versus_OnMapIdResolved()
{
    g_MapIdFresh = true;
    TryOpenPendingChapter();
}

// Called from OnClientDisconnect: drop the client's persistent team letter so a
// reused slot can't inherit it (letters are slot-keyed).
void Bizzy_Versus_OnClientDisconnect(int client)
{
    if (client >= 1 && client <= MaxClients)
    {
        g_PlayerTeam[client] = '\0';
        g_RoundClients[client].side = 0;
    }
}

// -----------------------------------------------------------------------------
// Match lifecycle
// -----------------------------------------------------------------------------

static void OpenMatch(const char[] campaign)
{
    if (g_DB == null || g_ServerId == 0) return;

    strcopy(g_MatchCampaign, sizeof g_MatchCampaign, campaign);
    g_MatchOpening = true;
    g_MatchAnchored = false;
    g_ChapterOpening = false;
    g_MatchMapId = 0;
    g_ChapterMapName[0] = '\0';
    g_ChapterFirstHalfSurv = '\0';
    g_MatchMapOrdinal = 0;
    g_MatchCompleteChapters = 0;
    g_MapRoundOrdinal = 0;
    g_RoundId = 0;
    g_RoundIndex = 0;
    g_RoundActive = false;
    g_RoundLive = false;
    g_RoundLivePending = false;
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
    g_MatchOpening = false;
    if (rs == null) { LogError("[bizzymod-stats] match insert: %s", error); return; }
    g_MatchId = rs.InsertId;

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

    // Open the first chapter once BOTH match_id and map_id are ready (this may be
    // that point, or OnMapLookup may complete it).
    TryOpenPendingChapter();
}

static void CloseMatch(const char[] reason)
{
    if (g_MatchId == 0) return;

    // Commit a still-open half, then flush the still-open chapter, BEFORE deciding
    // the winner so the final chapter is captured and folded into the score (and
    // g_MatchCompleteChapters reflects the final count).
    if (g_RoundActive)
        CloseRound(0, 0, 0);
    if (g_MatchMapId != 0)
        FlushOpenMap();

    // A match produces a WIN/LOSS only if at least 2 chapters completed both halves
    // — then the winner is the cumulative survivor-score lead across the campaign.
    // Fewer than 2 completed chapters => 'abandoned' (no W/L), regardless of why it
    // ended. Whole campaigns rarely finish, so gating on chapters (not the finale)
    // gives match W/L a usable hit rate while keeping it meaningful. The pure
    // per-chapter aggregate (maps_won / maps_lost = the user-facing "Round" W/L) is
    // credited independently at each chapter close.
    int wn = (g_MatchCompleteChapters >= 2) ? DecideMatchWinner() : 'X';
    char winnerEnum[16];
    if      (wn == 'A')  strcopy(winnerEnum, sizeof winnerEnum, "A");
    else if (wn == 'B')  strcopy(winnerEnum, sizeof winnerEnum, "B");
    else if (wn == 'D')  strcopy(winnerEnum, sizeof winnerEnum, "draw");
    else                 strcopy(winnerEnum, sizeof winnerEnum, "abandoned");

    char escReason[96];
    Bizzy_DB_Escape(reason, escReason, sizeof escReason);

    int teamA = (g_TeamScoreA < 0) ? 0 : g_TeamScoreA;
    int teamB = (g_TeamScoreB < 0) ? 0 : g_TeamScoreB;

    Transaction t = Bizzy_DB_BeginTxn();
    char sql[512];

    FormatEx(sql, sizeof sql,
        "UPDATE matches SET ended_at=NOW(), team_a_score=%d, team_b_score=%d, "
        ... "winner='%s', end_reason='%s' WHERE id=%d",
        teamA, teamB, winnerEnum, escReason, g_MatchId);
    t.AddQuery(sql);

    FormatEx(sql, sizeof sql,
        "UPDATE match_teams SET final_score=%d WHERE match_id=%d AND team_letter='A'",
        teamA, g_MatchId);
    t.AddQuery(sql);
    FormatEx(sql, sizeof sql,
        "UPDATE match_teams SET final_score=%d WHERE match_id=%d AND team_letter='B'",
        teamB, g_MatchId);
    t.AddQuery(sql);

    Bizzy_DB_RunTxn(t);

    UpdatePlayerVersusMatchTotals(wn);

    LogMessage("[bizzymod-stats] match closed: id=%d winner=%s reason=%s (A=%d B=%d)",
        g_MatchId, winnerEnum, reason, teamA, teamB);

    g_MatchId = 0;
    g_MatchOpening = false;
    g_MatchAnchored = false;
    g_ChapterOpening = false;
    g_ChapterPending = false;
    g_MapIdFresh = false;
    g_MatchMapId = 0;
    g_ChapterMapName[0] = '\0';
    g_ChapterFirstHalfSurv = '\0';
    g_MatchMapOrdinal = 0;
    g_MatchCompleteChapters = 0;
    g_MapRoundOrdinal = 0;
    g_RoundId = 0;
    g_RoundIndex = 0;
    g_RoundActive = false;
    g_RoundLive = false;
    g_RoundLivePending = false;
    g_MatchCampaign[0] = '\0';
}

static int DecideMatchWinner()
{
    if (g_TeamScoreA > g_TeamScoreB) return 'A';
    if (g_TeamScoreB > g_TeamScoreA) return 'B';
    return 'D';
}

// -----------------------------------------------------------------------------
// Map (chapter) lifecycle within a match
// -----------------------------------------------------------------------------

// The single entry point that actually opens a chapter. Safe to call from any
// async callback: it no-ops until match_id + a FRESH map_id are both available,
// and opens a new match_map only when the engine map NAME differs from the open
// chapter's (a same-name reload is a within-chapter restart).
static void TryOpenPendingChapter()
{
    if (!g_ChapterPending) return;
    if (g_MatchId == 0 || !g_MapIdFresh || g_CurrentMapId == 0) return;

    if (StrEqual(g_CurrentMap, g_ChapterMapName))
    {
        // Same chapter reloading (scenario restart) — nothing to open.
        g_ChapterPending = false;
        return;
    }

    // A prior chapter's INSERT is still in flight — wait; OnMatchMapInserted will
    // re-drive this once the id (and any flush) can proceed.
    if (g_ChapterOpening) return;

    // Genuine new chapter. Close a dangling half + the previous chapter first so we
    // never leak an open round across the boundary (mirrors Event_VMapTransition).
    // Only close a round that actually went LIVE — the map-id resolves ASYNC ~1s
    // after OnMapStart, by which point the NEW map's own first Round_Start has
    // already opened a fresh (not-yet-live) candidate here. Discarding that would
    // kill the new chapter's real first survivor run (the second-half-loss bug); a
    // genuine leftover half from the previous chapter is g_RoundLive=true.
    if (g_RoundActive && g_RoundLive)
        CloseRound(0, 0, 0);
    if (g_MatchMapId != 0)
        FlushOpenMap();

    OpenMatchMap();
    g_ChapterPending = false;
}

static void OpenMatchMap()
{
    if (g_MatchId == 0 || g_CurrentMapId == 0) return;

    g_MatchMapOrdinal++;
    g_MapRoundOrdinal = 0;
    strcopy(g_ChapterMapName, sizeof g_ChapterMapName, g_CurrentMap);
    g_ChapterFirstHalfSurv = '\0';
    g_MatchMapId = 0;
    g_ChapterOpening = true;
    g_MatchMapPluginA = 0;
    g_MatchMapPluginB = 0;

    char sql[256];
    FormatEx(sql, sizeof sql,
        "INSERT INTO match_maps (match_id, map_id, ordinal, started_at) "
        ... "VALUES (%d, %d, %d, NOW())",
        g_MatchId, g_CurrentMapId, g_MatchMapOrdinal);
    // Tag the dispatch with the owning match_id so a callback that lands after a
    // match close+reopen (multi-second DB stall) is ignored, not mis-bound.
    g_DB.Query(OnMatchMapInserted, sql, g_MatchId);
}

static void OnMatchMapInserted(Database db, DBResultSet rs, const char[] error, any data)
{
    // Stale callback from an already-closed match — ignore entirely (don't touch
    // the live match's g_ChapterOpening / g_MatchMapId).
    if (data != g_MatchId) return;

    g_ChapterOpening = false;

    if (rs == null)
    {
        LogError("[bizzymod-stats] match_map insert: %s", error);
        // Make the chapter re-openable: clear the name guard + any latched round so
        // the next OnMapStart/OnMapLookup (a mutation12 scenario restart) retries.
        g_ChapterMapName[0] = '\0';
        g_RoundLivePending = false;
        g_ChapterPending = true;
        return;
    }
    g_MatchMapId = rs.InsertId;

    // A round that went LIVE before the chapter id landed was latched (ordinal already
    // consumed in MarkRoundLive) — insert its match_rounds row now.
    if (g_RoundLivePending && g_RoundLive)
        InsertLiveRound();

    // A newer chapter may have been waiting on this insert to complete.
    TryOpenPendingChapter();
}

// Chapter winner from accumulated per-team survivor scores (engine distance netprop
// reads 0 on this build; see ReadEngineCampaignScoreForSurvTeam).
static int DecideMapWinner()
{
    if (g_MatchMapPluginA != g_MatchMapPluginB)
        return (g_MatchMapPluginA > g_MatchMapPluginB) ? 'A' : 'B';
    return 'D';
}

// Append the chapter close + per-player rollup to an OPEN transaction. A chapter
// that did not complete BOTH halves is 'incomplete': it still credits the rounds
// its players actually played, but no chapter winner / maps_won / maps_lost /
// streaks are awarded (there is no fair winner off a single survivor half).
static void AppendMapCloseAndRollup(Transaction t)
{
    if (g_MatchMapId == 0) return;

    bool complete = (g_MapRoundOrdinal >= 2);
    int wn = complete ? DecideMapWinner() : 0;

    char winnerEnum[16];
    if      (!complete) strcopy(winnerEnum, sizeof winnerEnum, "incomplete");
    else if (wn == 'A') strcopy(winnerEnum, sizeof winnerEnum, "A");
    else if (wn == 'B') strcopy(winnerEnum, sizeof winnerEnum, "B");
    else                strcopy(winnerEnum, sizeof winnerEnum, "draw");

    // Only fold a COMPLETE chapter's scores into the cumulative match total — a
    // half-played chapter would add one team's survivor points and not the other's,
    // biasing DecideMatchWinner. (The per-map row still stores what was played.)
    if (complete)
    {
        g_TeamScoreA += g_MatchMapPluginA;
        g_TeamScoreB += g_MatchMapPluginB;
    }
    int scoreA = (g_MatchMapPluginA < 0) ? 0 : g_MatchMapPluginA;
    int scoreB = (g_MatchMapPluginB < 0) ? 0 : g_MatchMapPluginB;

    char sql[384];
    FormatEx(sql, sizeof sql,
        "UPDATE match_maps SET ended_at=NOW(), team_a_score=%d, team_b_score=%d, winner='%s' "
        ... "WHERE id=%d",
        scoreA, scoreB, winnerEnum, g_MatchMapId);
    t.AddQuery(sql);

    // Chapter win/loss tallies + maps_played only for a COMPLETE chapter.
    if (complete && wn == 'A')
    {
        FormatEx(sql, sizeof sql,
            "UPDATE match_teams SET maps_won=maps_won+1 WHERE match_id=%d AND team_letter='A'", g_MatchId);
        t.AddQuery(sql);
        FormatEx(sql, sizeof sql,
            "UPDATE match_teams SET maps_lost=maps_lost+1 WHERE match_id=%d AND team_letter='B'", g_MatchId);
        t.AddQuery(sql);
    }
    else if (complete && wn == 'B')
    {
        FormatEx(sql, sizeof sql,
            "UPDATE match_teams SET maps_won=maps_won+1 WHERE match_id=%d AND team_letter='B'", g_MatchId);
        t.AddQuery(sql);
        FormatEx(sql, sizeof sql,
            "UPDATE match_teams SET maps_lost=maps_lost+1 WHERE match_id=%d AND team_letter='A'", g_MatchId);
        t.AddQuery(sql);
    }

    if (complete)
    {
        g_MatchCompleteChapters++;
        FormatEx(sql, sizeof sql,
            "UPDATE matches SET maps_played=maps_played+1 WHERE id=%d", g_MatchId);
        t.AddQuery(sql);
    }

    // wn==0 (incomplete) -> the rollup credits rounds/scores but no maps_won/lost/streaks.
    AppendPlayerVersusRollupForMap(t, g_MatchMapId, wn);
}

// Roll each player's completed-chapter contribution into player_versus_stats.
static void AppendPlayerVersusRollupForMap(Transaction t, int mapId, int winnerChar)
{
    int gm = view_as<int>(g_CurrentMode);

    for (int letter = 0; letter < 2; letter++)
    {
        char L = (letter == 0) ? 'A' : 'B';
        int wonInc  = (winnerChar == L) ? 1 : 0;
        int lostInc = (winnerChar != L && (winnerChar == 'A' || winnerChar == 'B')) ? 1 : 0;

        char sql[2048];
        FormatEx(sql, sizeof sql,
            "INSERT INTO player_versus_stats "
            ... "(player_id, gamemode_id, maps_won, maps_lost, rounds_played, "
            ... " rounds_as_surv, rounds_as_inf, total_round_score_surv, total_round_score_inf, "
            ... " current_win_streak, longest_win_streak, current_loss_streak, longest_loss_streak, last_match_at) "
            ... "SELECT prs.player_id, %d, %d, %d, COUNT(*), "
            ... "       SUM(prs.side=2), SUM(prs.side=3), "
            ... "       SUM(IF(prs.side=2, prs.points, 0)), SUM(IF(prs.side=3, prs.points, 0)), "
            ... "       %d, %d, %d, %d, NOW() "
            ... "FROM player_round_stats prs "
            ... "JOIN match_rounds mr ON mr.id = prs.match_round_id "
            ... "WHERE mr.match_map_id=%d AND prs.team_letter='%c' "
            ... "GROUP BY prs.player_id "
            ... "ON DUPLICATE KEY UPDATE "
            ... " maps_won               = maps_won               + VALUES(maps_won), "
            ... " maps_lost              = maps_lost              + VALUES(maps_lost), "
            ... " rounds_played          = rounds_played          + VALUES(rounds_played), "
            ... " rounds_as_surv         = rounds_as_surv         + VALUES(rounds_as_surv), "
            ... " rounds_as_inf          = rounds_as_inf          + VALUES(rounds_as_inf), "
            ... " total_round_score_surv = total_round_score_surv + VALUES(total_round_score_surv), "
            ... " total_round_score_inf  = total_round_score_inf  + VALUES(total_round_score_inf), "
            ... " current_win_streak  = IF(%d=1, current_win_streak + 1, IF(%d=1, 0, current_win_streak)), "
            ... " longest_win_streak  = GREATEST(longest_win_streak, current_win_streak), "
            ... " current_loss_streak = IF(%d=1, current_loss_streak + 1, IF(%d=1, 0, current_loss_streak)), "
            ... " longest_loss_streak = GREATEST(longest_loss_streak, current_loss_streak), "
            ... " last_match_at = NOW()",
            gm, wonInc, lostInc,
            wonInc, wonInc, lostInc, lostInc,
            mapId, L,
            wonInc, lostInc,
            lostInc, wonInc);
        t.AddQuery(sql);
    }
}

static void FlushOpenMap()
{
    if (g_MatchMapId == 0) return;
    Transaction t = Bizzy_DB_BeginTxn();
    AppendMapCloseAndRollup(t);
    Bizzy_DB_RunTxn(t);
    g_MatchMapId = 0;
    g_MapRoundOrdinal = 0;
    g_ChapterFirstHalfSurv = '\0';
}

// -----------------------------------------------------------------------------
// Round (half) lifecycle
// -----------------------------------------------------------------------------

// A round_start opens a CANDIDATE window. It is NOT counted as a real half (no DB
// row, no ordinal consumed) until it goes LIVE — survivors leave the saferoom
// (primary) or real combat happens (fallback). mutation12 fires spurious
// round_starts during ready-up / scenario restarts between the two survivor runs;
// those never go live, so they no longer eat the chapter's 2-half quota or drop the
// real second run.
static void Event_VRoundStart(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_VersusActive) return;
    // The matches INSERT is async: on a match's FIRST map, g_MatchId is still 0 when
    // that map's first Round_Start fires. Dropping it here lost the match's very first
    // survivor run. OpenMatch sets g_MatchOpening synchronously in OnMapStart (before
    // any Round_Start), so allow the candidate to open while the INSERT is in flight;
    // it binds to the chapter when OnMatchInserted / OnMatchMapInserted lands.
    if (g_MatchId == 0 && !g_MatchOpening) return;
    if (g_RoundActive) return;   // already inside a round window (duplicate round_start)

    g_RoundActive        = true;
    g_RoundLive          = false;
    g_RoundLivePending   = false;
    g_RoundId            = 0;
    g_RoundStartEpoch    = Bizzy_NowEpoch();
    g_RoundLiveEpoch     = 0;
    g_TankAppearedRound  = false;
    g_WitchAppearedRound = false;
    g_FirstBloodFired    = false;
    g_FirstDownFired     = false;

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
}

// The saferoom-leave events fire when survivors go live.
static void Event_VRoundWentLive(Event event, const char[] name, bool dontBroadcast)
{
    if (g_VersusActive && g_MatchId != 0)
        Bizzy_Versus_MarkRoundLive();
}

// Promote the current candidate round to a REAL half: consume an ordinal slot and
// insert its match_rounds row. Idempotent; called from the saferoom-leave events
// and (fallback) from the first real combat in the round. A phantom never reaches
// here, so it stays uncounted and gets discarded at round_end.
void Bizzy_Versus_MarkRoundLive()
{
    if (!g_RoundActive || g_RoundLive) return;
    if (g_MapRoundOrdinal >= 2) return;   // chapter already has its two live halves

    g_RoundLive  = true;
    g_RoundLiveEpoch = Bizzy_NowEpoch();    // measure duration_s from live, not from round_start (excludes ready-up)
    g_MapRoundOrdinal++;
    g_RoundIndex = g_MapRoundOrdinal;      // 1 or 2

    if (g_MatchMapId == 0)
    {
        // Chapter's match_map id hasn't resolved yet — insert when it lands
        // (OnMatchMapInserted honors g_RoundLivePending).
        g_RoundLivePending = true;
        return;
    }
    InsertLiveRound();
}

// Combat is a FALLBACK "went live" signal (used only if the saferoom-leave events
// don't fire on this build). Gate it on a minimum elapsed time: a between-runs
// phantom lives and dies in ~0 seconds, so an instant / stray / queued combat event
// (saferoom FF, a delayed player_hurt from the previous run, a molotov tick) inside
// a phantom window must NOT promote it — that would re-drop the real second run. A
// real half runs for minutes with continuous combat, so it still promotes (~15s in)
// even when the saferoom-leave event is missing. Survivors leaving the saferoom
// (Event_VRoundWentLive) is airtight and promotes immediately, without this gate.
// True while the server is in the ready-up window (readyup.smx). Coop-safe: the
// native is optional, so on a server without readyup this returns false and the
// fallback behaves exactly as before.
static bool Bizzy_Versus_InReadyUp()
{
    return GetFeatureStatus(FeatureType_Native, "IsInReady") == FeatureStatus_Available
        && IsInReady();
}

static void MaybeMarkLiveFromCombat()
{
    if (!g_RoundActive || g_RoundLive) return;
    // Ready-up is exactly the window where between-runs phantoms live. Real halves
    // only go live AFTER ready-up ends (survivors then leave the saferoom — the
    // airtight primary signal). So never let combat during ready-up promote a
    // candidate: saferoom friendly-fire, a stray/queued hit from the previous run,
    // or an FF kill can otherwise eat the chapter's 2nd slot and re-drop the real
    // second run — the very bug the liveness gate exists to prevent.
    if (Bizzy_Versus_InReadyUp()) return;
    if (Bizzy_NowEpoch() - g_RoundStartEpoch < 15) return;   // too soon — could still be a phantom
    Bizzy_Versus_MarkRoundLive();
}

static void InsertLiveRound()
{
    if (g_MatchMapId == 0) return;
    g_RoundLivePending = false;

    // Provisional survivor_team for the INSERT; CloseRound rewrites it from the
    // settled sides. The two halves alternate, so half 2's guess flips half 1's.
    char guess;
    if (!g_MatchAnchored)
        guess = 'A';
    else if (g_RoundIndex == 2 && g_ChapterFirstHalfSurv != '\0')
        guess = (g_ChapterFirstHalfSurv == 'A') ? 'B' : 'A';
    else
    {
        guess = LiveSurvivorLetter();
        if (guess == '\0')
        {
            if (g_SurvivorTeam != '\0') guess = g_SurvivorTeam;
            else                        guess = 'A';
        }
    }
    g_SurvivorTeam = guess;

    LogMessage("[bizzymod-stats] round LIVE: match=%d chapter=%d half=%d surv~%c",
        g_MatchId, g_MatchMapOrdinal, g_RoundIndex, guess);

    char sql[384];
    FormatEx(sql, sizeof sql,
        "INSERT INTO match_rounds (match_id, match_map_id, round_index, survivor_team, started_at) "
        ... "VALUES (%d, %d, %d, '%c', NOW())",
        g_MatchId, g_MatchMapId, g_RoundIndex, g_SurvivorTeam);
    g_DB.Query(OnRoundInserted, sql);
}

// Which persistent letter holds the Survivor side right now (live GetClientTeam).
static char LiveSurvivorLetter()
{
    int a = 0, b = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (g_PlayerTeam[i] == '\0' || !IsClientInGame(i)) continue;
        if (GetClientTeam(i) != TEAM_SURVIVORS) continue;
        if      (g_PlayerTeam[i] == 'A') a++;
        else if (g_PlayerTeam[i] == 'B') b++;
    }
    if (a > b) return 'A';
    if (b > a) return 'B';
    return '\0';
}

// Which persistent letter holds Survivors, from a settled per-client side array.
static char SurvivorLetterFromSides(const int[] curSide)
{
    int a = 0, b = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (g_PlayerTeam[i] == '\0') continue;
        if (curSide[i] != TEAM_SURVIVORS) continue;
        if      (g_PlayerTeam[i] == 'A') a++;
        else if (g_PlayerTeam[i] == 'B') b++;
    }
    if (a > b) return 'A';
    if (b > a) return 'B';
    return '\0';
}

static void OnRoundInserted(Database db, DBResultSet rs, const char[] error, any data)
{
    if (rs == null) { LogError("[bizzymod-stats] round insert: %s", error); return; }
    g_RoundId = rs.InsertId;
}

static void Event_VRoundEnd(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_VersusActive || g_MatchId == 0 || !g_RoundActive) return;

    int reason = event.GetInt("reason", 0);
    int winner = event.GetInt("winner", 0);
    int engineScore = ReadEngineCampaignScoreForSurvTeam();

    CloseRound(reason, winner, engineScore);
}

static void CloseRound(int reason, int winnerTeam, int engineScore)
{
    if (!g_RoundActive) return;   // no round window open

    // PHANTOM: a candidate round that never went live (ready-up / scenario restart).
    // It consumed no ordinal and inserted no row, so just close the window. This is
    // exactly what lets the real second survivor run land instead of being blocked.
    if (!g_RoundLive)
    {
        LogMessage("[bizzymod-stats] round discarded (never went live): match=%d chapter=%d",
            g_MatchId, g_MatchMapOrdinal);
        g_RoundActive = false;
        return;
    }

    int closedIndex = g_RoundIndex;

    if (g_RoundId == 0)
    {
        // Live half whose match_rounds INSERT hasn't landed (livePending never
        // resolved to a chapter id, or a same-second race). Don't wedge; keep the
        // chapter consistent.
        if (g_RoundLivePending)
        {
            // Never inserted — give its ordinal slot back so the chapter isn't
            // wrongly "complete", and preserve half-1's letter for the flip.
            if (closedIndex == 1 && g_ChapterFirstHalfSurv == '\0')
            {
                if (g_SurvivorTeam != '\0') g_ChapterFirstHalfSurv = g_SurvivorTeam;
                else                        g_ChapterFirstHalfSurv = 'A';
            }
            if (g_MapRoundOrdinal > 0) g_MapRoundOrdinal--;
        }
        else if (closedIndex == 2)
        {
            // Half-2's row was dispatched but its id never landed (a multi-minute DB
            // stall spanning the whole half — realistically unreachable). Best-effort:
            // still close + roll up the chapter off whatever landed, rather than
            // orphaning an open match_maps row and losing the W/L credit.
            FlushOpenMap();
        }
        else if (closedIndex == 1 && g_ChapterFirstHalfSurv == '\0')
        {
            if (g_SurvivorTeam != '\0') g_ChapterFirstHalfSurv = g_SurvivorTeam;
            else                        g_ChapterFirstHalfSurv = 'A';
        }
        g_RoundActive = false;
        g_RoundLive = false;
        g_RoundLivePending = false;
        g_RoundIndex = 0;
        return;
    }

    int durEpoch = (g_RoundLiveEpoch != 0) ? g_RoundLiveEpoch : g_RoundStartEpoch;
    int duration = Bizzy_NowEpoch() - durEpoch;
    if (duration < 0) duration = 0;

    // Settled per-client sides at round_end (fresh read; cache fallback for a
    // client who left). Used to anchor letters + letter late joiners + decide who
    // actually PLAYED; the TEAM (A/B) side is derived below for robustness.
    int curSide[MAXPLAYERS + 1];
    for (int i = 1; i <= MaxClients; i++)
    {
        int s = 0;
        if (Bizzy_IsValidPlayer(i)) s = GetClientTeam(i);
        if (s != TEAM_SURVIVORS && s != TEAM_INFECTED) s = g_RoundClients[i].side;
        curSide[i] = s;
    }

    // Anchor persistent letters from the match's first half (stable sides).
    if (!g_MatchAnchored)
    {
        for (int i = 1; i <= MaxClients; i++)
        {
            if (!Bizzy_IsValidPlayer(i)) continue;
            if      (curSide[i] == TEAM_SURVIVORS) AssignTeamLetter(i, 'A');
            else if (curSide[i] == TEAM_INFECTED)  AssignTeamLetter(i, 'B');
        }
        g_MatchAnchored = true;
    }

    // Survivor letter this half. First half: read the settled sides (reliable at a
    // chapter's start). Second half: FORCE the flip of the first half — the two
    // halves always alternate, so we don't trust a possibly-stale round_end read.
    char survLetter;
    if (closedIndex == 1)
    {
        survLetter = SurvivorLetterFromSides(curSide);
        if (survLetter == '\0')
        {
            if (g_SurvivorTeam != '\0') survLetter = g_SurvivorTeam;
            else                        survLetter = 'A';
        }
        g_ChapterFirstHalfSurv = survLetter;
    }
    else
    {
        if (g_ChapterFirstHalfSurv != '\0')
        {
            survLetter = (g_ChapterFirstHalfSurv == 'A') ? 'B' : 'A';
        }
        else
        {
            survLetter = SurvivorLetterFromSides(curSide);
            if (survLetter == '\0') survLetter = 'A';
        }
    }
    g_SurvivorTeam = survLetter;
    char infLetter = (survLetter == 'A') ? 'B' : 'A';

    // Letter any unlettered connected players from their actual side this half.
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!Bizzy_IsValidPlayer(i) || g_PlayerTeam[i] != '\0') continue;
        if      (curSide[i] == TEAM_SURVIVORS) AssignTeamLetter(i, survLetter);
        else if (curSide[i] == TEAM_INFECTED)  AssignTeamLetter(i, infLetter);
    }

    // Per-player side is DERIVED from (letter == survivor letter this half), which
    // is robust to the swap-timing race; a player only counts if they actually
    // played (had a survivor/infected side this half).
    int sumSurv = 0, sumInf = 0, survLeft = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (g_PlayerTeam[i] == '\0') continue;
        if (curSide[i] != TEAM_SURVIVORS && curSide[i] != TEAM_INFECTED) continue;
        if (g_PlayerTeam[i] == survLetter)
        {
            sumSurv += g_RoundClients[i].points;
            if (IsClientInGame(i) && IsPlayerAlive(i)) survLeft++;
        }
        else
            sumInf += g_RoundClients[i].points;
    }

    char endReason[48];
    DescribeRoundEndReason(reason, winnerTeam, endReason, sizeof endReason);
    char escReason[100];
    Bizzy_DB_Escape(endReason, escReason, sizeof escReason);

    Transaction t = Bizzy_DB_BeginTxn();
    char sql[1024];

    FormatEx(sql, sizeof sql,
        "UPDATE match_rounds SET ended_at=NOW(), duration_s=%d, engine_score=%d, "
        ... "survivor_team='%c', plugin_score_surv=%d, plugin_score_inf=%d, survivors_left=%d, "
        ... "tank_appeared=%d, witch_appeared=%d, end_reason='%s' WHERE id=%d",
        duration, engineScore, survLetter, sumSurv, sumInf, survLeft,
        g_TankAppearedRound ? 1 : 0, g_WitchAppearedRound ? 1 : 0,
        escReason, g_RoundId);
    t.AddQuery(sql);

    for (int i = 1; i <= MaxClients; i++)
    {
        if (g_PlayerTeam[i] == '\0') continue;
        if (g_Clients[i].playerId == 0) continue;
        if (curSide[i] != TEAM_SURVIVORS && curSide[i] != TEAM_INFECTED) continue;
        int side = (g_PlayerTeam[i] == survLetter) ? TEAM_SURVIVORS : TEAM_INFECTED;

        FormatEx(sql, sizeof sql,
            "INSERT INTO player_round_stats "
            ... "(match_round_id, player_id, team_letter, side, points, kills, deaths, incaps, "
            ... " damage_dealt, damage_taken, damage_friendly, time_in_round_s, awards_count) "
            ... "VALUES (%d, %d, '%c', %d, %d, %d, %d, %d, %d, %d, %d, %d, %d) "
            ... "ON DUPLICATE KEY UPDATE "
            ... " team_letter=VALUES(team_letter), side=VALUES(side), "
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

    FormatEx(sql, sizeof sql,
        "UPDATE matches SET rounds_played=rounds_played+1 WHERE id=%d", g_MatchId);
    t.AddQuery(sql);

    if (survLetter == 'A') g_MatchMapPluginA += sumSurv;
    else                   g_MatchMapPluginB += sumSurv;

    // Round 2 just ended → chapter complete. Roll up in THIS transaction so the
    // rollup SELECT sees the round-2 player_round_stats queued above.
    if (closedIndex == 2)
        AppendMapCloseAndRollup(t);

    Bizzy_DB_RunTxn(t);

    LogMessage("[bizzymod-stats] round closed: match=%d chapter=%d half=%d surv_team=%c surv_pts=%d inf_pts=%d survleft=%d dur=%d",
        g_MatchId, g_MatchMapOrdinal, closedIndex, survLetter, sumSurv, sumInf, survLeft, duration);

    g_RoundActive = false;
    g_RoundLive = false;
    g_RoundLivePending = false;
    g_RoundId = 0;
    g_RoundIndex = 0;
    if (closedIndex == 2)
    {
        g_MatchMapId = 0;
        g_MapRoundOrdinal = 0;
        g_ChapterFirstHalfSurv = '\0';
    }
}

static void Event_VMatchFinished(Event event, const char[] name, bool dontBroadcast)
{
    if (g_MatchId == 0) return;
    CloseMatch("finale");
}

static void Event_VMapTransition(Event event, const char[] name, bool dontBroadcast)
{
    if (g_RoundActive)
        CloseRound(0, 0, 0);
    if (g_MatchMapId != 0)
        FlushOpenMap();
}

// -----------------------------------------------------------------------------
// Per-player events
// -----------------------------------------------------------------------------

static void Event_VPlayerTeam(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (!Bizzy_IsValidPlayer(client) || g_MatchId == 0) return;

    // Cache the current side only (round_end fallback for a client who leaves).
    // Team letters are anchored once and never reassigned on the per-half swap.
    g_RoundClients[client].side = event.GetInt("team");
}

static void Event_VTankSpawn(Event event, const char[] name, bool dontBroadcast)
{
    if (g_RoundActive) g_TankAppearedRound = true;
}

static void Event_VWitchSpawn(Event event, const char[] name, bool dontBroadcast)
{
    if (g_RoundActive) g_WitchAppearedRound = true;
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

// -----------------------------------------------------------------------------
// player_versus_stats: MATCH-level totals at match close.
// -----------------------------------------------------------------------------

static void UpdatePlayerVersusMatchTotals(int winnerChar)
{
    if (g_MatchId == 0) return;

    char winLetter = (winnerChar == 'A' || winnerChar == 'B') ? winnerChar : 'X';
    bool isDraw    = (winnerChar == 'D');
    bool isAbandon = (winnerChar == 'X');
    int gm = view_as<int>(g_CurrentMode);

    for (int letter = 0; letter < 2; letter++)
    {
        char L = (letter == 0) ? 'A' : 'B';
        bool teamWon = (L == winLetter);

        int wonInc     = isAbandon ? 0 : (teamWon ? 1 : 0);
        int lostInc    = isAbandon ? 0 : (!teamWon && !isDraw ? 1 : 0);
        int drawInc    = isDraw ? 1 : 0;
        int abandonInc = isAbandon ? 1 : 0;

        char sql[1024];
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
            ... " last_match_at = NOW()",
            gm, wonInc, lostInc, drawInc, abandonInc,
            g_MatchId, L);
        Bizzy_DB_Exec(sql);
    }
}

// -----------------------------------------------------------------------------
// External hooks (called from scoring.sp, events.sp, awards.sp)
// -----------------------------------------------------------------------------

stock void Bizzy_Versus_AccumScore(int client, int points)
{
    if (!g_RoundActive) return;
    g_RoundClients[client].points += points;
}

stock void Bizzy_Versus_AccumKill(int client, bool isDeath = false)
{
    if (!g_RoundActive) return;
    MaybeMarkLiveFromCombat();   // fallback liveness signal (elapsed-gated vs phantoms)
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
    if (!g_RoundActive) return;
    // Friendly fire is never proof a round is live — survivors can shoot each other
    // in the saferoom during ready-up. Only real (cross-team) damage counts toward
    // the combat liveness fallback; FF is still accumulated for stats below.
    if (!friendly) MaybeMarkLiveFromCombat();   // fallback liveness signal (elapsed-gated + ready-up-gated vs phantoms)
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
    if (!g_RoundActive) return;
    g_RoundClients[client].incaps++;
}

stock void Bizzy_Versus_AccumAward(int client)
{
    if (!g_RoundActive) return;
    g_RoundClients[client].awards++;
}

stock bool Bizzy_Versus_MatchActive() { return g_MatchId != 0; }
stock int  Bizzy_Versus_GetRoundId()  { return g_RoundId; }
stock int  Bizzy_Versus_GetMatchId()  { return g_MatchId; }

// -----------------------------------------------------------------------------
// Helpers
// -----------------------------------------------------------------------------

static int ReadEngineCampaignScoreForSurvTeam()
{
    return 0;
}

static void StripTrailingDigits(char[] s)
{
    int n = strlen(s);
    while (n > 0 && s[n-1] >= '0' && s[n-1] <= '9') { s[n-1] = '\0'; n--; }
}

// Campaign code, stable across a campaign's chapters and distinct between
// campaigns (used only for match campaign-change detection):
//   c2m3_coaster             -> "c2"           (official L4D2)
//   l4d_hospital01_apartment -> "l4d_hospital" (L4D1 port: game prefix + campaign)
//   l4d2_bts01_forest        -> "l4d2_bts"
//   dcr_m1_hotel             -> "dcr"           (custom: campaign is the 1st segment)
// Returns "" only when nothing usable — caller must NOT force a campaign change on "".
static void DeriveCampaignCode(const char[] mapname, char[] out, int outlen)
{
    out[0] = '\0';
    int n = strlen(mapname);
    if (n == 0) return;

    // Official L4D2 "c<digits>m..." -> "c<digits>"
    if (mapname[0] == 'c' && n > 1 && mapname[1] >= '0' && mapname[1] <= '9')
    {
        int k = 0;
        out[k++] = 'c';
        for (int i = 1; i < n && k < outlen - 1 && mapname[i] >= '0' && mapname[i] <= '9'; i++)
            out[k++] = mapname[i];
        out[k] = '\0';
        return;
    }

    // First two '_'-segments.
    int u1 = -1, u2 = -1;
    for (int i = 0; i < n; i++)
        if (mapname[i] == '_') { if (u1 < 0) u1 = i; else { u2 = i; break; } }

    if (u1 < 0)
    {
        strcopy(out, outlen, mapname);
        StripTrailingDigits(out);
        return;
    }

    char seg1[64];
    strcopy(seg1, (u1 + 1 < sizeof seg1) ? u1 + 1 : sizeof seg1, mapname);

    bool gamePrefix = StrEqual(seg1, "l4d") || StrEqual(seg1, "l4d2");
    if (gamePrefix)
    {
        int s2end = (u2 >= 0) ? u2 : n;
        char seg2[64];
        int k = 0;
        for (int i = u1 + 1; i < s2end && k < sizeof seg2 - 1; i++) seg2[k++] = mapname[i];
        seg2[k] = '\0';
        StripTrailingDigits(seg2);
        if (seg2[0] != '\0') { Format(out, outlen, "%s_%s", seg1, seg2); return; }
    }
    strcopy(out, outlen, seg1);
}

static void DescribeRoundEndReason(int reason, int winnerTeam, char[] out, int outlen)
{
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
        CreateTimer(2.0, Timer_AbandonStale, _, TIMER_FLAG_NO_MAPCHANGE);
        return;
    }
    char sql[256];
    FormatEx(sql, sizeof sql,
        "UPDATE matches SET ended_at=NOW(), winner='abandoned', end_reason='plugin_restart' "
        ... "WHERE server_id=%d AND ended_at IS NULL", g_ServerId);
    Bizzy_DB_Exec(sql);

    FormatEx(sql, sizeof sql,
        "UPDATE match_maps mm JOIN matches m ON m.id=mm.match_id "
        ... "SET mm.ended_at=NOW() "
        ... "WHERE m.server_id=%d AND mm.ended_at IS NULL", g_ServerId);
    Bizzy_DB_Exec(sql);
}

static Action Timer_AbandonStale(Handle timer)
{
    AbandonStaleMatchesForServer();
    return Plugin_Stop;
}
