/**
 * session.sp — per-player session lifecycle.
 *
 * A session = one continuous (player, server) presence. We open one on
 * client auth completion, flush rollups + close it on disconnect or map
 * change. The in-memory per-client counters in ClientState aggregate
 * during the session and are flushed in one transaction at close.
 */

void Bizzy_OnSessionInit() { /* nothing yet */ }

stock void Bizzy_BeginClientSession(int client)
{
    if (!Bizzy_IsValidPlayer(client)) return;
    if (g_Clients[client].inUse) return;

    g_Clients[client].inUse            = true;
    g_Clients[client].sessionStartTime = Bizzy_NowEpoch();
    g_Clients[client].team             = GetClientTeam(client);

    // ResolvePlayer -> Session_Open chains via callbacks; we just kick it off.
    Bizzy_Identity_ResolvePlayer(client);
}

stock void Bizzy_Session_Open(int client)
{
    if (!Bizzy_IsValidPlayer(client) || g_Clients[client].playerId == 0)
        return;
    if (g_Clients[client].sessionId != 0) return;

    char sql[512];
    FormatEx(sql, sizeof sql,
        "INSERT INTO sessions (player_id, server_id, gamemode_id, difficulty_id, map_id, started_at, team) "
        ... "VALUES (%d, %d, %d, %d, NULLIF(%d, 0), NOW(), %d)",
        g_Clients[client].playerId, g_ServerId,
        view_as<int>(g_CurrentMode), view_as<int>(g_CurrentDifficulty),
        g_CurrentMapId, g_Clients[client].team);

    DataPack dp = new DataPack();
    dp.WriteCell(GetClientUserId(client));
    g_DB.Query(OnSessionInserted, sql, dp);

    if (g_cvAnnounceJoin.BoolValue && !g_Clients[client].muted)
        AnnounceJoiningPlayer(client);
}

static void OnSessionInserted(Database db, DBResultSet rs, const char[] error, DataPack dp)
{
    dp.Reset();
    int uid = dp.ReadCell();
    delete dp;
    if (error[0] != '\0') { LogError("[bizzymod-stats] session insert: %s", error); return; }
    int client = GetClientOfUserId(uid);
    if (client == 0) return;
    g_Clients[client].sessionId = rs.InsertId;
}

stock void Bizzy_EndClientSession(int client)
{
    if (!g_Clients[client].inUse) return;
    int duration = Bizzy_NowEpoch() - g_Clients[client].sessionStartTime;
    if (duration < 0) duration = 0;

    Bizzy_Session_Flush(client, duration);
    Bizzy_ResetClientState(client);
}

/**
 * Flush in-memory counters to player_stats + close the open session row.
 * Atomic per-client transaction.
 */
stock void Bizzy_Session_Flush(int client, int duration)
{
    if (g_DB == null || g_Clients[client].playerId == 0) return;

    Transaction txn = Bizzy_DB_BeginTxn();

    // Final time-alive: if still alive, add the trailing span.
    if (g_Clients[client].aliveSinceEpoch != 0)
    {
        int alive = Bizzy_NowEpoch() - g_Clients[client].aliveSinceEpoch;
        if (alive > 0) g_Clients[client].timeAliveS += alive;
        g_Clients[client].aliveSinceEpoch = 0;
    }
    // Final kill-streak peak
    if (g_Clients[client].killStreak > g_Clients[client].killStreakMax)
        g_Clients[client].killStreakMax = g_Clients[client].killStreak;

    // 1) Upsert rollup row in player_stats.
    char sql[2048];
    FormatEx(sql, sizeof sql,
        "INSERT INTO player_stats "
        ... "(player_id, gamemode_id, difficulty_id, server_id, "
        ... " points, playtime_s, sessions, "
        ... " shots_fired, shots_hit, headshots, "
        ... " damage_dealt, damage_taken, damage_friendly, "
        ... " kills_common, incaps, deaths, "
        ... " pipe_bombs_thrown, pipe_bombs_kills, "
        ... " molotovs_thrown, molotovs_kills, molotov_burn_damage, "
        ... " bile_bombs_thrown, bile_bombs_hits, "
        ... " damage_to_tank, damage_to_witch, damage_to_special, "
        ... " time_alive_s, time_dead_s, time_incapped_s, "
        ... " pinned_by_smoker, pinned_by_hunter, pinned_by_jockey, pinned_by_charger, "
        ... " vomited_on, self_escapes, distance_units) "
        ... "VALUES (%d, %d, %d, 0, "
        ... " %d, %d, 1, "
        ... " %d, %d, %d, "
        ... " %d, %d, %d, "
        ... " %d, %d, %d, "
        ... " %d, %d, "
        ... " %d, %d, %d, "
        ... " %d, %d, "
        ... " %d, %d, %d, "
        ... " %d, %d, %d, "
        ... " %d, %d, %d, %d, "
        ... " %d, %d, %d) "
        ... "ON DUPLICATE KEY UPDATE "
        ... " points              = points              + VALUES(points), "
        ... " playtime_s          = playtime_s          + VALUES(playtime_s), "
        ... " sessions            = sessions            + 1, "
        ... " shots_fired         = shots_fired         + VALUES(shots_fired), "
        ... " shots_hit           = shots_hit           + VALUES(shots_hit), "
        ... " headshots           = headshots           + VALUES(headshots), "
        ... " damage_dealt        = damage_dealt        + VALUES(damage_dealt), "
        ... " damage_taken        = damage_taken        + VALUES(damage_taken), "
        ... " damage_friendly     = damage_friendly     + VALUES(damage_friendly), "
        ... " kills_common        = kills_common        + VALUES(kills_common), "
        ... " incaps              = incaps              + VALUES(incaps), "
        ... " deaths              = deaths              + VALUES(deaths), "
        ... " pipe_bombs_thrown   = pipe_bombs_thrown   + VALUES(pipe_bombs_thrown), "
        ... " pipe_bombs_kills    = pipe_bombs_kills    + VALUES(pipe_bombs_kills), "
        ... " molotovs_thrown     = molotovs_thrown     + VALUES(molotovs_thrown), "
        ... " molotovs_kills      = molotovs_kills      + VALUES(molotovs_kills), "
        ... " molotov_burn_damage = molotov_burn_damage + VALUES(molotov_burn_damage), "
        ... " bile_bombs_thrown   = bile_bombs_thrown   + VALUES(bile_bombs_thrown), "
        ... " bile_bombs_hits     = bile_bombs_hits     + VALUES(bile_bombs_hits), "
        ... " damage_to_tank      = damage_to_tank      + VALUES(damage_to_tank), "
        ... " damage_to_witch     = damage_to_witch     + VALUES(damage_to_witch), "
        ... " damage_to_special   = damage_to_special   + VALUES(damage_to_special), "
        ... " time_alive_s        = time_alive_s        + VALUES(time_alive_s), "
        ... " time_dead_s         = time_dead_s         + VALUES(time_dead_s), "
        ... " time_incapped_s     = time_incapped_s     + VALUES(time_incapped_s), "
        ... " pinned_by_smoker    = pinned_by_smoker    + VALUES(pinned_by_smoker), "
        ... " pinned_by_hunter    = pinned_by_hunter    + VALUES(pinned_by_hunter), "
        ... " pinned_by_jockey    = pinned_by_jockey    + VALUES(pinned_by_jockey), "
        ... " pinned_by_charger   = pinned_by_charger   + VALUES(pinned_by_charger), "
        ... " vomited_on          = vomited_on          + VALUES(vomited_on), "
        ... " self_escapes        = self_escapes        + VALUES(self_escapes), "
        ... " distance_units      = distance_units      + VALUES(distance_units)",
        g_Clients[client].playerId,
        view_as<int>(g_CurrentMode), view_as<int>(g_CurrentDifficulty),
        g_Clients[client].pointsThisSession, duration,
        g_Clients[client].shotsFired, g_Clients[client].shotsHit,
        g_Clients[client].headshots,
        g_Clients[client].damageDealt, g_Clients[client].damageTaken,
        g_Clients[client].damageFriendly,
        g_Clients[client].kills, g_Clients[client].incaps,
        g_Clients[client].deaths,
        g_Clients[client].pipeBombsThrown, g_Clients[client].pipeBombsKills,
        g_Clients[client].molotovsThrown, g_Clients[client].molotovsKills,
        g_Clients[client].molotovBurnDamage,
        g_Clients[client].bileBombsThrown, g_Clients[client].bileBombsHits,
        g_Clients[client].damageToTank, g_Clients[client].damageToWitch,
        g_Clients[client].damageToSpecial,
        g_Clients[client].timeAliveS, g_Clients[client].timeDeadS,
        g_Clients[client].timeIncappedS,
        g_Clients[client].pinnedBySmoker, g_Clients[client].pinnedByHunter,
        g_Clients[client].pinnedByJockey, g_Clients[client].pinnedByCharger,
        g_Clients[client].vomitedOn, g_Clients[client].selfEscapes,
        g_Clients[client].distanceUnits);
    txn.AddQuery(sql);

    // 1b) Career bests — single-row GREATEST update per player.
    FormatEx(sql, sizeof sql,
        "INSERT INTO career_bests "
        ... "(player_id, most_points_in_session, most_kills_in_session, "
        ... " most_headshots_in_session, longest_kill_streak, "
        ... " biggest_tank_punch_damage) "
        ... "VALUES (%d, %d, %d, %d, %d, %d) "
        ... "ON DUPLICATE KEY UPDATE "
        ... " most_points_in_session    = GREATEST(most_points_in_session,    VALUES(most_points_in_session)), "
        ... " most_kills_in_session     = GREATEST(most_kills_in_session,     VALUES(most_kills_in_session)), "
        ... " most_headshots_in_session = GREATEST(most_headshots_in_session, VALUES(most_headshots_in_session)), "
        ... " longest_kill_streak       = GREATEST(longest_kill_streak,       VALUES(longest_kill_streak)), "
        ... " biggest_tank_punch_damage = GREATEST(biggest_tank_punch_damage, VALUES(biggest_tank_punch_damage))",
        g_Clients[client].playerId,
        g_Clients[client].pointsThisSession,
        g_Clients[client].kills,
        g_Clients[client].headshots,
        g_Clients[client].killStreakMax,
        g_Clients[client].biggestTankPunch);
    txn.AddQuery(sql);

    // 2) Combat granularity (mig 008) — UPSERT into the same player_stats row.
    FormatEx(sql, sizeof sql,
        "INSERT INTO player_stats "
        ... "(player_id, gamemode_id, difficulty_id, server_id, "
        ... " dmg_hitgroup_head, dmg_hitgroup_chest, dmg_hitgroup_stomach, "
        ... " dmg_hitgroup_limb, dmg_hitgroup_other, "
        ... " damage_taken_bw, damage_environment, damage_self, fall_deaths, "
        ... " ff_kills_caused, reloads, "
        ... " multikill_2, multikill_3, multikill_4, multikill_5plus, "
        ... " kill_assists_special, kill_assists_tank, kill_assists_witch) "
        ... "VALUES (%d, %d, %d, 0, "
        ... " %d, %d, %d, %d, %d, "
        ... " %d, %d, %d, %d, "
        ... " %d, %d, "
        ... " %d, %d, %d, %d, "
        ... " %d, %d, %d) "
        ... "ON DUPLICATE KEY UPDATE "
        ... " dmg_hitgroup_head    = dmg_hitgroup_head    + VALUES(dmg_hitgroup_head), "
        ... " dmg_hitgroup_chest   = dmg_hitgroup_chest   + VALUES(dmg_hitgroup_chest), "
        ... " dmg_hitgroup_stomach = dmg_hitgroup_stomach + VALUES(dmg_hitgroup_stomach), "
        ... " dmg_hitgroup_limb    = dmg_hitgroup_limb    + VALUES(dmg_hitgroup_limb), "
        ... " dmg_hitgroup_other   = dmg_hitgroup_other   + VALUES(dmg_hitgroup_other), "
        ... " damage_taken_bw      = damage_taken_bw      + VALUES(damage_taken_bw), "
        ... " damage_environment   = damage_environment   + VALUES(damage_environment), "
        ... " damage_self          = damage_self          + VALUES(damage_self), "
        ... " fall_deaths          = fall_deaths          + VALUES(fall_deaths), "
        ... " ff_kills_caused      = ff_kills_caused      + VALUES(ff_kills_caused), "
        ... " reloads              = reloads              + VALUES(reloads), "
        ... " multikill_2          = multikill_2          + VALUES(multikill_2), "
        ... " multikill_3          = multikill_3          + VALUES(multikill_3), "
        ... " multikill_4          = multikill_4          + VALUES(multikill_4), "
        ... " multikill_5plus      = multikill_5plus      + VALUES(multikill_5plus), "
        ... " kill_assists_special = kill_assists_special + VALUES(kill_assists_special), "
        ... " kill_assists_tank    = kill_assists_tank    + VALUES(kill_assists_tank), "
        ... " kill_assists_witch   = kill_assists_witch   + VALUES(kill_assists_witch)",
        g_Clients[client].playerId,
        view_as<int>(g_CurrentMode), view_as<int>(g_CurrentDifficulty),
        g_Clients[client].dmgHitHead, g_Clients[client].dmgHitChest,
        g_Clients[client].dmgHitStomach, g_Clients[client].dmgHitLimb,
        g_Clients[client].dmgHitOther,
        g_Clients[client].damageTakenBW, g_Clients[client].damageEnvironment,
        g_Clients[client].damageSelf, g_Clients[client].fallDeaths,
        g_Clients[client].ffKillsCaused, g_Clients[client].reloads,
        g_Clients[client].multikill2, g_Clients[client].multikill3,
        g_Clients[client].multikill4, g_Clients[client].multikill5plus,
        g_Clients[client].killAssistsSpecial, g_Clients[client].killAssistsTank,
        g_Clients[client].killAssistsWitch);
    txn.AddQuery(sql);

    // 3) Health & inventory (mig 010). The weapon-tier counters divide by 4
    //    to convert quarter-second samples → seconds.
    int wT1 = g_Clients[client].weaponT1TimeS / 4;
    int wT2 = g_Clients[client].weaponT2TimeS / 4;
    int wM  = g_Clients[client].weaponMeleeTimeS / 4;
    int wSn = g_Clients[client].weaponSniperTimeS / 4;
    FormatEx(sql, sizeof sql,
        "INSERT INTO player_stats "
        ... "(player_id, gamemode_id, difficulty_id, server_id, "
        ... " hp_at_saferoom_sum, hp_at_saferoom_count, "
        ... " hp_at_pills_sum, hp_at_pills_count, "
        ... " hp_at_adrenaline_sum, hp_at_adrenaline_count, "
        ... " hp_at_medkit_sum, hp_at_medkit_count, "
        ... " bw_entries, bw_time_s, "
        ... " pills_hoarded, adrenaline_hoarded, medkits_hoarded, "
        ... " throwables_hoarded, defibs_hoarded, defib_target_points_sum, "
        ... " weapon_t1_time_s, weapon_t2_time_s, "
        ... " weapon_melee_time_s, weapon_sniper_time_s) "
        ... "VALUES (%d, %d, %d, 0, "
        ... " %d, %d, %d, %d, %d, %d, %d, %d, "
        ... " %d, %d, "
        ... " %d, %d, %d, %d, %d, %d, "
        ... " %d, %d, %d, %d) "
        ... "ON DUPLICATE KEY UPDATE "
        ... " hp_at_saferoom_sum     = hp_at_saferoom_sum     + VALUES(hp_at_saferoom_sum), "
        ... " hp_at_saferoom_count   = hp_at_saferoom_count   + VALUES(hp_at_saferoom_count), "
        ... " hp_at_pills_sum        = hp_at_pills_sum        + VALUES(hp_at_pills_sum), "
        ... " hp_at_pills_count      = hp_at_pills_count      + VALUES(hp_at_pills_count), "
        ... " hp_at_adrenaline_sum   = hp_at_adrenaline_sum   + VALUES(hp_at_adrenaline_sum), "
        ... " hp_at_adrenaline_count = hp_at_adrenaline_count + VALUES(hp_at_adrenaline_count), "
        ... " hp_at_medkit_sum       = hp_at_medkit_sum       + VALUES(hp_at_medkit_sum), "
        ... " hp_at_medkit_count     = hp_at_medkit_count     + VALUES(hp_at_medkit_count), "
        ... " bw_entries             = bw_entries             + VALUES(bw_entries), "
        ... " bw_time_s              = bw_time_s              + VALUES(bw_time_s), "
        ... " pills_hoarded          = pills_hoarded          + VALUES(pills_hoarded), "
        ... " adrenaline_hoarded     = adrenaline_hoarded     + VALUES(adrenaline_hoarded), "
        ... " medkits_hoarded        = medkits_hoarded        + VALUES(medkits_hoarded), "
        ... " throwables_hoarded     = throwables_hoarded     + VALUES(throwables_hoarded), "
        ... " defibs_hoarded         = defibs_hoarded         + VALUES(defibs_hoarded), "
        ... " defib_target_points_sum = defib_target_points_sum + VALUES(defib_target_points_sum), "
        ... " weapon_t1_time_s       = weapon_t1_time_s       + VALUES(weapon_t1_time_s), "
        ... " weapon_t2_time_s       = weapon_t2_time_s       + VALUES(weapon_t2_time_s), "
        ... " weapon_melee_time_s    = weapon_melee_time_s    + VALUES(weapon_melee_time_s), "
        ... " weapon_sniper_time_s   = weapon_sniper_time_s   + VALUES(weapon_sniper_time_s)",
        g_Clients[client].playerId,
        view_as<int>(g_CurrentMode), view_as<int>(g_CurrentDifficulty),
        g_Clients[client].hpAtSaferoomSum, g_Clients[client].hpAtSaferoomCount,
        g_Clients[client].hpAtPillsSum,    g_Clients[client].hpAtPillsCount,
        g_Clients[client].hpAtAdrenSum,    g_Clients[client].hpAtAdrenCount,
        g_Clients[client].hpAtMedkitSum,   g_Clients[client].hpAtMedkitCount,
        g_Clients[client].bwEntries, g_Clients[client].bwTimeS,
        g_Clients[client].pillsHoarded, g_Clients[client].adrenalineHoarded,
        g_Clients[client].medkitsHoarded, g_Clients[client].throwablesHoarded,
        g_Clients[client].defibsHoarded, g_Clients[client].defibTargetPointsSum,
        wT1, wT2, wM, wSn);
    txn.AddQuery(sql);

    // 4) Movement (mig 011). time_alone_s divides by 4 (sample → seconds);
    //    max_team_spread_units uses GREATEST. avg_team_spread_units left
    //    untouched for now (needs a sum/count schema split — known v0.6 gap).
    int timeAlone = g_Clients[client].timeAloneS / 4;
    FormatEx(sql, sizeof sql,
        "INSERT INTO player_stats "
        ... "(player_id, gamemode_id, difficulty_id, server_id, "
        ... " time_alone_s, breaks_from_group, fall_damage_taken, max_team_spread_units) "
        ... "VALUES (%d, %d, %d, 0, %d, %d, %d, %d) "
        ... "ON DUPLICATE KEY UPDATE "
        ... " time_alone_s          = time_alone_s          + VALUES(time_alone_s), "
        ... " breaks_from_group     = breaks_from_group     + VALUES(breaks_from_group), "
        ... " fall_damage_taken     = fall_damage_taken     + VALUES(fall_damage_taken), "
        ... " max_team_spread_units = GREATEST(max_team_spread_units, VALUES(max_team_spread_units))",
        g_Clients[client].playerId,
        view_as<int>(g_CurrentMode), view_as<int>(g_CurrentDifficulty),
        timeAlone, g_Clients[client].breaksFromGroup,
        g_Clients[client].fallDamageTaken, g_Clients[client].maxTeamSpreadUnits);
    txn.AddQuery(sql);

    // 5) Coordination (mig 012) + round-shaping (mig 013).
    FormatEx(sql, sizeof sql,
        "INSERT INTO player_stats "
        ... "(player_id, gamemode_id, difficulty_id, server_id, "
        ... " revive_chains_started, revive_chains_part_of, save_of_saves, "
        ... " first_bloods, first_downs, saferoom_door_closes, "
        ... " crescendos_cleared, crescendos_wiped, finale_waves_cleared, "
        ... " tank_kill_participations, tank_solo_kills) "
        ... "VALUES (%d, %d, %d, 0, %d, %d, %d, %d, %d, %d, %d, %d, %d, %d, %d) "
        ... "ON DUPLICATE KEY UPDATE "
        ... " revive_chains_started     = revive_chains_started     + VALUES(revive_chains_started), "
        ... " revive_chains_part_of     = revive_chains_part_of     + VALUES(revive_chains_part_of), "
        ... " save_of_saves             = save_of_saves             + VALUES(save_of_saves), "
        ... " first_bloods              = first_bloods              + VALUES(first_bloods), "
        ... " first_downs               = first_downs               + VALUES(first_downs), "
        ... " saferoom_door_closes      = saferoom_door_closes      + VALUES(saferoom_door_closes), "
        ... " crescendos_cleared        = crescendos_cleared        + VALUES(crescendos_cleared), "
        ... " crescendos_wiped          = crescendos_wiped          + VALUES(crescendos_wiped), "
        ... " finale_waves_cleared      = finale_waves_cleared      + VALUES(finale_waves_cleared), "
        ... " tank_kill_participations  = tank_kill_participations  + VALUES(tank_kill_participations), "
        ... " tank_solo_kills           = tank_solo_kills           + VALUES(tank_solo_kills)",
        g_Clients[client].playerId,
        view_as<int>(g_CurrentMode), view_as<int>(g_CurrentDifficulty),
        g_Clients[client].reviveChainsStarted, g_Clients[client].reviveChainsPartOf,
        g_Clients[client].saveOfSaves,
        g_Clients[client].firstBloods, g_Clients[client].firstDowns,
        g_Clients[client].saferoomDoorCloses,
        g_Clients[client].crescendosCleared, g_Clients[client].crescendosWiped,
        g_Clients[client].finaleWavesCleared,
        g_Clients[client].tankKillParticipations, g_Clients[client].tankSoloKills);
    txn.AddQuery(sql);

    // 6) Career bests — extend with all the new GREATEST/LEAST peaks.
    FormatEx(sql, sizeof sql,
        "INSERT INTO career_bests "
        ... "(player_id, peak_dps, longest_kill_units, biggest_single_hit, "
        ... " biggest_multikill, biggest_pounce_damage, longest_jockey_ride_s, "
        ... " lowest_hp_survival) "
        ... "VALUES (%d, %d, %d, %d, %d, %d, %d, %d) "
        ... "ON DUPLICATE KEY UPDATE "
        ... " peak_dps              = GREATEST(peak_dps,              VALUES(peak_dps)), "
        ... " longest_kill_units    = GREATEST(longest_kill_units,    VALUES(longest_kill_units)), "
        ... " biggest_single_hit    = GREATEST(biggest_single_hit,    VALUES(biggest_single_hit)), "
        ... " biggest_multikill     = GREATEST(biggest_multikill,     VALUES(biggest_multikill)), "
        ... " biggest_pounce_damage = GREATEST(biggest_pounce_damage, VALUES(biggest_pounce_damage)), "
        ... " longest_jockey_ride_s = GREATEST(longest_jockey_ride_s, VALUES(longest_jockey_ride_s)), "
        ... " lowest_hp_survival    = LEAST(lowest_hp_survival,       VALUES(lowest_hp_survival))",
        g_Clients[client].playerId,
        g_Clients[client].peakDpsThisSession,
        g_Clients[client].longestKillUnits,
        g_Clients[client].biggestSingleHit,
        g_Clients[client].biggestMultikill,
        g_Clients[client].biggestPounceDamage,
        g_Clients[client].longestJockeyRideS,
        g_Clients[client].lowestHpSurvival);
    txn.AddQuery(sql);

    // 7) Close the open session row.
    if (g_Clients[client].sessionId != 0)
    {
        FormatEx(sql, sizeof sql,
            "UPDATE sessions SET ended_at=NOW(), duration_s=%d, "
            ... "points=%d, kills=%d, deaths=%d WHERE id=%d",
            duration,
            g_Clients[client].pointsThisSession,
            g_Clients[client].kills, g_Clients[client].deaths,
            g_Clients[client].sessionId);
        txn.AddQuery(sql);
    }

    // 8) Update players.last_seen.
    FormatEx(sql, sizeof sql,
        "UPDATE players SET last_seen=NOW(), last_gamemode=%d WHERE id=%d",
        view_as<int>(g_CurrentMode), g_Clients[client].playerId);
    txn.AddQuery(sql);

    Bizzy_DB_RunTxn(txn);
}

/**
 * Clear all in-memory counters that get flushed to player_stats, while
 * preserving identity (inUse, playerId, sessionId, steamid, name, muted,
 * team) and active timer state (aliveSinceEpoch, bwEnteredEpoch, etc).
 * Called by Bizzy_OnMapEnd after the flush completes.
 */
static void ResetSessionCounters(int client)
{
    // Core combat
    g_Clients[client].pointsThisSession = 0;
    g_Clients[client].shotsFired = 0;
    g_Clients[client].shotsHit = 0;
    g_Clients[client].headshots = 0;
    g_Clients[client].damageDealt = 0;
    g_Clients[client].damageTaken = 0;
    g_Clients[client].damageFriendly = 0;
    g_Clients[client].kills = 0;
    g_Clients[client].incaps = 0;
    g_Clients[client].deaths = 0;

    // 007
    g_Clients[client].pipeBombsThrown = 0;
    g_Clients[client].pipeBombsKills = 0;
    g_Clients[client].molotovsThrown = 0;
    g_Clients[client].molotovsKills = 0;
    g_Clients[client].molotovBurnDamage = 0;
    g_Clients[client].bileBombsThrown = 0;
    g_Clients[client].bileBombsHits = 0;
    g_Clients[client].damageToTank = 0;
    g_Clients[client].damageToWitch = 0;
    g_Clients[client].damageToSpecial = 0;
    g_Clients[client].timeAliveS = 0;
    g_Clients[client].timeDeadS = 0;
    g_Clients[client].timeIncappedS = 0;
    g_Clients[client].pinnedBySmoker = 0;
    g_Clients[client].pinnedByHunter = 0;
    g_Clients[client].pinnedByJockey = 0;
    g_Clients[client].pinnedByCharger = 0;
    g_Clients[client].vomitedOn = 0;
    g_Clients[client].selfEscapes = 0;
    g_Clients[client].distanceUnits = 0;
    g_Clients[client].killStreak = 0;
    g_Clients[client].killStreakMax = 0;
    g_Clients[client].biggestPounceDamage = 0;
    g_Clients[client].biggestTankPunch = 0;
    g_Clients[client].longestJockeyRideS = 0;

    // 008
    g_Clients[client].dmgHitHead = 0;
    g_Clients[client].dmgHitChest = 0;
    g_Clients[client].dmgHitStomach = 0;
    g_Clients[client].dmgHitLimb = 0;
    g_Clients[client].dmgHitOther = 0;
    g_Clients[client].damageTakenBW = 0;
    g_Clients[client].damageEnvironment = 0;
    g_Clients[client].damageSelf = 0;
    g_Clients[client].fallDeaths = 0;
    g_Clients[client].ffKillsCaused = 0;
    g_Clients[client].reloads = 0;
    g_Clients[client].multikill2 = 0;
    g_Clients[client].multikill3 = 0;
    g_Clients[client].multikill4 = 0;
    g_Clients[client].multikill5plus = 0;
    g_Clients[client].killAssistsSpecial = 0;
    g_Clients[client].killAssistsTank = 0;
    g_Clients[client].killAssistsWitch = 0;
    g_Clients[client].peakDpsThisSession = 0;
    g_Clients[client].dpsWindowStartMs = 0;
    g_Clients[client].dpsWindowDamage = 0;
    g_Clients[client].longestKillUnits = 0;
    g_Clients[client].biggestSingleHit = 0;
    g_Clients[client].biggestMultikill = 0;

    // 010
    g_Clients[client].hpAtSaferoomSum = 0;
    g_Clients[client].hpAtSaferoomCount = 0;
    g_Clients[client].hpAtPillsSum = 0;
    g_Clients[client].hpAtPillsCount = 0;
    g_Clients[client].hpAtAdrenSum = 0;
    g_Clients[client].hpAtAdrenCount = 0;
    g_Clients[client].hpAtMedkitSum = 0;
    g_Clients[client].hpAtMedkitCount = 0;
    g_Clients[client].bwEntries = 0;
    g_Clients[client].bwTimeS = 0;
    g_Clients[client].pillsHoarded = 0;
    g_Clients[client].adrenalineHoarded = 0;
    g_Clients[client].medkitsHoarded = 0;
    g_Clients[client].throwablesHoarded = 0;
    g_Clients[client].defibsHoarded = 0;
    g_Clients[client].defibTargetPointsSum = 0;
    g_Clients[client].weaponT1TimeS = 0;
    g_Clients[client].weaponT2TimeS = 0;
    g_Clients[client].weaponMeleeTimeS = 0;
    g_Clients[client].weaponSniperTimeS = 0;
    g_Clients[client].lowestHpSurvival = 100;

    // 011
    g_Clients[client].timeAloneS = 0;
    g_Clients[client].timeLeadingS = 0;
    g_Clients[client].timeTrailingS = 0;
    g_Clients[client].breaksFromGroup = 0;
    g_Clients[client].fallDamageTaken = 0;
    g_Clients[client].maxTeamSpreadUnits = 0;
    g_Clients[client].avgTeamSpreadSum = 0;
    g_Clients[client].avgTeamSpreadCount = 0;
    // Keep samplerLast{X,Y,Z} so distance deltas don't spike on next sample
    g_Clients[client].samplerWasAlone = false;

    // 012
    g_Clients[client].reviveChainsStarted = 0;
    g_Clients[client].reviveChainsPartOf = 0;
    g_Clients[client].saveOfSaves = 0;

    // 013
    g_Clients[client].firstBloods = 0;
    g_Clients[client].firstDowns = 0;
    g_Clients[client].saferoomDoorCloses = 0;
    g_Clients[client].lastInSafe = 0;
    g_Clients[client].crescendosCleared = 0;
    g_Clients[client].crescendosWiped = 0;
    g_Clients[client].finaleWavesCleared = 0;
    g_Clients[client].tankKillParticipations = 0;
    g_Clients[client].tankSoloKills = 0;

    // session bookkeeping
    g_Clients[client].sessionId = 0;
    g_Clients[client].sessionStartTime = Bizzy_NowEpoch();
}

stock void Bizzy_OnMapStart()
{
    Bizzy_Identity_ResolveMap();
}

stock void Bizzy_OnMapEnd()
{
    // Flush all open sessions; they reopen on next map.
    for (int i = 1; i <= MaxClients; i++)
    {
        if (g_Clients[i].inUse)
        {
            int duration = Bizzy_NowEpoch() - g_Clients[i].sessionStartTime;
            Bizzy_Session_Flush(i, duration);
            // Full counter reset — preserves identity (inUse, playerId,
            // steamid, name, muted, team) but zeroes every accumulator so
            // the next map's flush doesn't double-count.
            ResetSessionCounters(i);
        }
    }
}

static void AnnounceJoiningPlayer(int client)
{
    if (g_Clients[client].playerId == 0) return;
    // Rank lookup is async; we PrintToChatAll inside the callback.
    DataPack dp = new DataPack();
    dp.WriteCell(GetClientUserId(client));

    char sql[512];
    FormatEx(sql, sizeof sql,
        "SELECT 1 + (SELECT COUNT(*) FROM v_player_totals t2 "
        ... "             WHERE t2.points > t1.points) AS rank, "
        ... "       t1.points "
        ... "FROM v_player_totals t1 WHERE t1.player_id = %d",
        g_Clients[client].playerId);
    g_DB.Query(OnAnnounceRankLookup, sql, dp);
}

static void OnAnnounceRankLookup(Database db, DBResultSet rs, const char[] error, DataPack dp)
{
    dp.Reset();
    int uid = dp.ReadCell();
    delete dp;
    if (rs == null || !rs.FetchRow()) return;
    int client = GetClientOfUserId(uid);
    if (client == 0) return;
    int rank   = rs.FetchInt(0);
    int points = rs.FetchInt(1);
    PrintToChatAll("\x04[bizzymod-stats]\x01 %N joined the game! (Rank: %d, Points: %d)",
        client, rank, points);
}
