/**
 * events.sp — game event hooks. The bridge between SourceMod events and
 * Bizzy_Score / Bizzy_Awards_Fire / Bizzy_Weapons_RecordKill.
 *
 * This file is the primary place to add new stat capture. Every hook is
 * a thin shim — the actual numbers and award codes live in scoring.sp
 * and awards.sp. To track a new stat:
 *   1) Add a column to player_stats / player_si_stats (new migration)
 *   2) Hook the event here
 *   3) Increment via Bizzy_Score / Bizzy_Awards_Fire
 *   4) Surface it in session.sp's flush SQL
 */

void Bizzy_OnEventsInit()
{
    HookEvent("player_death",         Event_PlayerDeath,        EventHookMode_Post);
    HookEvent("player_hurt",          Event_PlayerHurt,         EventHookMode_Post);
    HookEvent("player_incapacitated", Event_PlayerIncap,        EventHookMode_Post);
    HookEvent("revive_success",       Event_ReviveSuccess,      EventHookMode_Post);
    HookEvent("heal_success",         Event_HealSuccess,        EventHookMode_Post);
    HookEvent("pills_used",           Event_PillsUsed,          EventHookMode_Post);
    HookEvent("defibrillator_used",   Event_DefibUsed,          EventHookMode_Post);
    HookEvent("witch_killed",         Event_WitchKilled,        EventHookMode_Post);
    HookEvent("witch_harasser_set",   Event_WitchDisturbed,     EventHookMode_Post);
    HookEvent("tank_killed",          Event_TankKilled,         EventHookMode_Post);
    HookEvent("infected_death",       Event_InfectedDeath,      EventHookMode_Post);
    HookEvent("triggered_car_alarm",  Event_CarAlarm,           EventHookMode_Post);
    HookEvent("gascan_pour_completed", Event_GascanPoured,      EventHookMode_Post);
    HookEvent("upgrade_pack_used",    Event_AmmoUpgrade,        EventHookMode_Post);
    HookEvent("lunge_pounce",         Event_HunterPounce,       EventHookMode_Post);
    HookEvent("pounce_stopped",       Event_PounceStopped,      EventHookMode_Post);
    HookEvent("jockey_ride",          Event_JockeyRide,         EventHookMode_Post);
    HookEvent("jockey_ride_end",      Event_JockeyRideEnd,      EventHookMode_Post);
    HookEvent("charger_charge_start", Event_ChargerStart,       EventHookMode_Post);
    HookEvent("charger_impact",       Event_ChargerImpact,      EventHookMode_Post);
    HookEvent("tank_spawn",           Event_TankSpawn,          EventHookMode_Post);
    HookEvent("zombie_ignited",       Event_ZombieIgnited,      EventHookMode_Post);
    HookEvent("finale_win",           Event_FinaleWin,          EventHookMode_Post);
    HookEvent("map_transition",       Event_MapTransition,      EventHookMode_Post);
    HookEvent("mission_lost",         Event_MissionLost,        EventHookMode_Post);
    HookEvent("round_end",            Event_RoundEnd,           EventHookMode_Post);
    HookEvent("player_team",          Event_PlayerTeam,         EventHookMode_Post);
    HookEvent("player_spawn",         Event_PlayerSpawn,        EventHookMode_Post);
    HookEvent("weapon_fire",          Event_WeaponFire,         EventHookMode_Post);
    HookEvent("weapon_zoom",          Event_WeaponZoom,         EventHookMode_Post);

    // 008+: deeper captures
    HookEvent("weapon_reload",        Event_WeaponReload,       EventHookMode_Post);
    HookEvent("revive_begin",         Event_ReviveBegin,        EventHookMode_Post);
    HookEvent("heal_begin",           Event_HealBegin,          EventHookMode_Post);
    HookEvent("pills_used_fail",      Event_PillsFail,          EventHookMode_Post);
    HookEvent("entered_checkpoint",   Event_EnteredSafe,        EventHookMode_Post);
    HookEvent("door_close",           Event_DoorClose,          EventHookMode_Post);
    HookEvent("witch_spawn",          Event_WitchSpawn,         EventHookMode_Post);
    HookEvent("witch_killed",         Event_WitchKilledExt,     EventHookMode_Post);
    HookEvent("panic_event_start",    Event_PanicStart,         EventHookMode_Post);
    HookEvent("panic_event_finished", Event_PanicEnd,           EventHookMode_Post);
    HookEvent("gauntlet_finale_start", Event_PanicStart,        EventHookMode_Post);
    HookEvent("finale_start",         Event_FinaleStart,        EventHookMode_Post);
    HookEvent("finale_radio_start",   Event_FinaleStart,        EventHookMode_Post);
    HookEvent("zombie_spawned",       Event_ZombieSpawned,      EventHookMode_Post);

    // SI ability tracking
    HookEvent("tongue_release",       Event_TongueRelease,      EventHookMode_Post);
    HookEvent("smoker_self_revealed", Event_SmokerSelfClear,    EventHookMode_Post);

    // Versus first-blood / first-down
    // (handled inside Event_PlayerDeath / Event_PlayerIncap via versus.sp helpers)

    // Scavenge per-gascan
    HookEvent("gascan_pour_blocked",  Event_GascanInterrupted,  EventHookMode_Post);
    HookEvent("gascan_dropped",       Event_GascanInterrupted,  EventHookMode_Post);

    // 007: extended captures
    HookEvent("ability_use",          Event_AbilityUse,         EventHookMode_Post);
    HookEvent("tongue_grab",          Event_TongueGrab,         EventHookMode_Post);
    HookEvent("choke_start",          Event_ChokeStart,         EventHookMode_Post);
    HookEvent("jockey_ride",          Event_PinJockey,          EventHookMode_Post);
    HookEvent("charger_pummel_start", Event_PinChargerPummel,   EventHookMode_Post);
    HookEvent("charger_carry_start",  Event_PinChargerCarry,    EventHookMode_Post);
    HookEvent("boomer_exploded",      Event_BoomerExploded,     EventHookMode_Post);
    HookEvent("player_now_it",        Event_VomitedOn,          EventHookMode_Post);
    HookEvent("pipe_bomb_used",       Event_PipeUsed,           EventHookMode_Post);
    HookEvent("molotov_thrown",       Event_MolotovThrown,      EventHookMode_Post);
    HookEvent("vomitjar_thrown",      Event_BileThrown,         EventHookMode_Post);
}

// -----------------------------------------------------------------------------
// Combat
// -----------------------------------------------------------------------------

static void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
    int victim   = GetClientOfUserId(event.GetInt("userid"));
    int attacker = GetClientOfUserId(event.GetInt("attacker"));
    bool hs      = event.GetBool("headshot");
    char weapon[64];
    event.GetString("weapon", weapon, sizeof weapon);

    if (Bizzy_IsValidPlayer(victim))
    {
        g_Clients[victim].deaths++;
        Bizzy_Versus_AccumKill(victim, true);

        // Time-alive accounting
        if (g_Clients[victim].aliveSinceEpoch != 0)
        {
            int alive = GetTime() - g_Clients[victim].aliveSinceEpoch;
            if (alive > 0) g_Clients[victim].timeAliveS += alive;
            g_Clients[victim].aliveSinceEpoch = 0;
        }
        // Kill streak ends on death; record peak.
        if (g_Clients[victim].killStreak > g_Clients[victim].killStreakMax)
            g_Clients[victim].killStreakMax = g_Clients[victim].killStreak;
        g_Clients[victim].killStreak = 0;

        // FF-kills-caused: check if the most recent damage was friendly fire
        if (GetClientTeam(victim) == TEAM_SURVIVORS)
            Bizzy_Combat_OnDeathFFCheck(victim);

        // Fall death tracking
        if (StrEqual(weapon, "world") || StrEqual(weapon, "worldspawn"))
            g_Clients[victim].fallDeaths++;

        // Crescendo bookkeeping if there's an open one
        if (GetClientTeam(victim) == TEAM_SURVIVORS)
            Bizzy_Coord_OnDeathDuringCrescendo();
    }

    // Tank death: handle separately
    if (victim > 0 && victim <= MaxClients && IsClientInGame(victim)
        && GetClientTeam(victim) == TEAM_INFECTED)
    {
        SpecialInfected si = Bizzy_NormalizeZombieClass(Bizzy_ZombieClass(victim));
        if (si == SI_Tank)
        {
            Bizzy_TankWitch_TankKilled(victim, attacker, weapon);
            Bizzy_Combat_OnSIKill(victim, attacker, 1);
        }
        else if (si != SI_None)
        {
            // Hunter skeet detection: dying mid-pounce
            if (si == SI_Hunter && g_Clients[victim].siAbilityKind == 1
                && g_Clients[victim].siAbilityStartMs != 0)
            {
                int nowMs = RoundToFloor(GetEngineTime() * 1000.0);
                int durMs = nowMs - g_Clients[victim].siAbilityStartMs;
                Bizzy_SiStats_AccumPounce(victim, 0, durMs > 0 ? durMs : 0, true);
                if (Bizzy_IsValidPlayer(attacker))
                    Bizzy_Awards_Fire(attacker, "skeeted", 1);
                g_Clients[victim].siAbilityKind = 0;
            }
            Bizzy_Combat_OnSIKill(victim, attacker, 0);
        }
    }

    if (!Bizzy_IsValidPlayer(attacker)) return;
    Bizzy_RecordKill(attacker, victim, hs, weapon);

    // Kill-streak threshold awards (fire once at each milestone)
    g_Clients[attacker].killStreak++;
    int ks = g_Clients[attacker].killStreak;
    if      (ks == 10) Bizzy_Awards_Fire(attacker, "kill_streak_10", 1);
    else if (ks == 25) Bizzy_Awards_Fire(attacker, "kill_streak_25", 1);
    else if (ks == 50) Bizzy_Awards_Fire(attacker, "kill_streak_50", 1);

    // Throwable kill attribution: weapon is the throwable name
    if (StrEqual(weapon, "pipe_bomb"))
    {
        g_Clients[attacker].pipeBombsKills++;
        Bizzy_Awards_Fire(attacker, "pipe_kill", 1);
    }
    else if (StrEqual(weapon, "molotov") || StrEqual(weapon, "inferno") || StrEqual(weapon, "entityflame"))
    {
        g_Clients[attacker].molotovsKills++;
        Bizzy_Awards_Fire(attacker, "molotov_kill", 1);
    }
}

static void Event_PlayerHurt(Event event, const char[] name, bool dontBroadcast)
{
    int victim   = GetClientOfUserId(event.GetInt("userid"));
    int attacker = GetClientOfUserId(event.GetInt("attacker"));
    int dmg      = event.GetInt("dmg_health");
    char weapon[64];
    event.GetString("weapon", weapon, sizeof weapon);
    Bizzy_RecordDamage(attacker, victim, dmg, weapon);

    // 007: target-specific damage breakdown
    if (Bizzy_IsValidPlayer(attacker) && victim > 0 && victim <= MaxClients
        && IsClientInGame(victim) && GetClientTeam(victim) == TEAM_INFECTED)
    {
        int zc = Bizzy_ZombieClass(victim);
        SpecialInfected si = Bizzy_NormalizeZombieClass(zc);
        if (si == SI_Tank)
            g_Clients[attacker].damageToTank += dmg;
        else if (si == SI_Witch)
            g_Clients[attacker].damageToWitch += dmg;
        else if (si != SI_None)
            g_Clients[attacker].damageToSpecial += dmg;
    }

    // Tank punch tracking: if attacker is on infected team and the SI is Tank,
    // AND the victim is a survivor (i.e. an actual punch landed).
    if (Bizzy_IsValidPlayer(attacker) && GetClientTeam(attacker) == TEAM_INFECTED
        && Bizzy_NormalizeZombieClass(Bizzy_ZombieClass(attacker)) == SI_Tank
        && victim > 0 && victim <= MaxClients && IsClientInGame(victim)
        && GetClientTeam(victim) == TEAM_SURVIVORS)
    {
        if (dmg > g_Clients[attacker].biggestTankPunch)
            g_Clients[attacker].biggestTankPunch = dmg;
        Bizzy_TankWitch_TankPunch(attacker);
        Bizzy_TankWitch_TankDealt(attacker, dmg);
    }
    // Damage *received* by an active tank (survivor → tank)
    if (victim > 0 && victim <= MaxClients && IsClientInGame(victim)
        && GetClientTeam(victim) == TEAM_INFECTED
        && Bizzy_NormalizeZombieClass(Bizzy_ZombieClass(victim)) == SI_Tank)
    {
        Bizzy_TankWitch_TankReceived(victim, dmg);
    }

    // Molotov burn damage attribution: weapon name is "inferno" or "entityflame"
    if (Bizzy_IsValidPlayer(attacker)
        && (StrEqual(weapon, "inferno") || StrEqual(weapon, "entityflame")))
    {
        g_Clients[attacker].molotovBurnDamage += dmg;
    }
}

static void Event_PlayerIncap(Event event, const char[] name, bool dontBroadcast)
{
    int victim   = GetClientOfUserId(event.GetInt("userid"));
    int attacker = GetClientOfUserId(event.GetInt("attacker"));
    if (Bizzy_IsValidPlayer(victim))
    {
        g_Clients[victim].incaps++;
        Bizzy_Versus_AccumIncap(victim);
        if (GetClientTeam(victim) == TEAM_SURVIVORS)
            Bizzy_Coord_OnIncapDuringCrescendo();
    }
    if (Bizzy_IsValidPlayer(attacker) && GetClientTeam(attacker) == TEAM_INFECTED)
        Bizzy_Score(attacker, GetCV("bizzymod_stats_survivor_incap", 15), "incap_survivor");
}

// -----------------------------------------------------------------------------
// Survivor support
// -----------------------------------------------------------------------------

static void Event_ReviveSuccess(Event event, const char[] name, bool dontBroadcast)
{
    int reviver = GetClientOfUserId(event.GetInt("userid"));
    if (Bizzy_IsValidPlayer(reviver))
        Bizzy_Awards_Fire(reviver, "revive", 1);
}

static void Event_HealSuccess(Event event, const char[] name, bool dontBroadcast)
{
    int healer  = GetClientOfUserId(event.GetInt("userid"));
    int patient = GetClientOfUserId(event.GetInt("subject"));
    if (!Bizzy_IsValidPlayer(healer)) return;
    if (healer != patient)
        Bizzy_Score(healer, GetCV("bizzymod_stats_heal_other", 10), "medkit_other");
}

static void Event_PillsUsed(Event event, const char[] name, bool dontBroadcast)
{
    int giver   = GetClientOfUserId(event.GetInt("userid"));
    int patient = GetClientOfUserId(event.GetInt("subject"));
    if (!Bizzy_IsValidPlayer(giver)) return;
    if (giver != patient) Bizzy_Awards_Fire(giver, "pills_shared", 1);
}

static void Event_DefibUsed(Event event, const char[] name, bool dontBroadcast)
{
    int user    = GetClientOfUserId(event.GetInt("userid"));
    int subject = GetClientOfUserId(event.GetInt("subject"));
    if (Bizzy_IsValidPlayer(user)) Bizzy_Awards_Fire(user, "defib", 1);

    // Defib target priority — accumulate the resurrected player's session points
    if (Bizzy_IsValidPlayer(user) && Bizzy_IsValidPlayer(subject))
        g_Clients[user].defibTargetPointsSum += g_Clients[subject].pointsThisSession;
}

// -----------------------------------------------------------------------------
// Witch / tank
// -----------------------------------------------------------------------------

static void Event_WitchKilled(Event event, const char[] name, bool dontBroadcast)
{
    int killer   = GetClientOfUserId(event.GetInt("userid"));
    bool oneshot = event.GetBool("oneshot");
    if (Bizzy_IsValidPlayer(killer))
    {
        if (oneshot) Bizzy_Awards_Fire(killer, "witch_crowned", 1);
        Bizzy_Score(killer, GetCV("bizzymod_stats_witch_kill", 20), "witch_kill");
    }
}

static void Event_WitchKilledExt(Event event, const char[] name, bool dontBroadcast)
{
    int killer  = GetClientOfUserId(event.GetInt("userid"));
    int witchEnt = event.GetInt("witchid");
    bool oneshot = event.GetBool("oneshot");
    if (witchEnt > 0)
        Bizzy_TankWitch_WitchKilled(witchEnt, killer, oneshot);
}

static void Event_WitchDisturbed(Event event, const char[] name, bool dontBroadcast)
{
    int who = GetClientOfUserId(event.GetInt("userid"));
    if (Bizzy_IsValidPlayer(who)) Bizzy_Awards_Fire(who, "witch_disturb", 1);
}

static void Event_TankKilled(Event event, const char[] name, bool dontBroadcast)
{
    int killer    = GetClientOfUserId(event.GetInt("userid"));
    bool noDeaths = event.GetBool("solo");
    if (Bizzy_IsValidPlayer(killer))
    {
        Bizzy_Awards_Fire(killer, "tank_kill", 1);
        if (noDeaths) Bizzy_Awards_Fire(killer, "tank_kill_no_deaths", 1);
    }
}

// -----------------------------------------------------------------------------
// Infected scoring
// -----------------------------------------------------------------------------

static void Event_InfectedDeath(Event event, const char[] name, bool dontBroadcast)
{
    int attacker = GetClientOfUserId(event.GetInt("attacker"));
    if (!Bizzy_IsValidPlayer(attacker)) return;
    Bizzy_Score(attacker, GetCV("bizzymod_stats_common_kill", 1), "common_kill");
    Bizzy_Combat_OnInfectedKill(attacker); // multi-kill burst detection
}

static void Event_HunterPounce(Event event, const char[] name, bool dontBroadcast)
{
    int hunter = GetClientOfUserId(event.GetInt("userid"));
    int dmg    = event.GetInt("damage", 0);
    if (!Bizzy_IsValidPlayer(hunter)) return;
    if (dmg >= GetCV("bizzymod_stats_pounce_perfect_damage", 25))
        Bizzy_Awards_Fire(hunter, "pounce_perfect", 1);
    else if (dmg >= GetCV("bizzymod_stats_pounce_nice_damage", 15))
        Bizzy_Awards_Fire(hunter, "pounce_nice", 1);

    // Flight distance + duration from siAbilityStart snapshot
    if (g_Clients[hunter].siAbilityKind == 1 && g_Clients[hunter].siAbilityStartMs != 0)
    {
        float pos[3];
        GetClientAbsOrigin(hunter, pos);
        int dx = RoundToFloor(pos[0]) - g_Clients[hunter].siAbilityStartX;
        int dy = RoundToFloor(pos[1]) - g_Clients[hunter].siAbilityStartY;
        int dz = RoundToFloor(pos[2]) - g_Clients[hunter].siAbilityStartZ;
        int dist = RoundToFloor(SquareRoot(float(dx*dx + dy*dy + dz*dz)));
        int nowMs = RoundToFloor(GetEngineTime() * 1000.0);
        int durMs = nowMs - g_Clients[hunter].siAbilityStartMs;
        if (dist < 8000 && durMs > 0 && durMs < 10000)
            Bizzy_SiStats_AccumPounce(hunter, dist, durMs, false);
        g_Clients[hunter].siAbilityKind = 0;
        g_Clients[hunter].siAbilityStartMs = 0;
    }
}

static void Event_PounceStopped(Event event, const char[] name, bool dontBroadcast)
{
    int rescuer = GetClientOfUserId(event.GetInt("userid"));
    if (Bizzy_IsValidPlayer(rescuer))
        Bizzy_Awards_Fire(rescuer, "protect", 1);
}

static void Event_JockeyRide(Event event, const char[] name, bool dontBroadcast)
{
    int jockey = GetClientOfUserId(event.GetInt("userid"));
    if (Bizzy_IsValidPlayer(jockey))
        g_Clients[jockey].spawnStartTime = Bizzy_NowEpoch();
}

static void Event_JockeyRideEnd(Event event, const char[] name, bool dontBroadcast)
{
    // Duration could be flushed into player_si_stats; left as an extension point.
}

static void Event_ChargerStart(Event event, const char[] name, bool dontBroadcast)
{
    // No-op; we score on impact (with detail) instead.
}

static void Event_ChargerImpact(Event event, const char[] name, bool dontBroadcast)
{
    int charger = GetClientOfUserId(event.GetInt("userid"));
    if (!Bizzy_IsValidPlayer(charger)) return;
    int hits = event.GetInt("hits", 1);
    if (hits >= GetCV("bizzymod_stats_scatter_ram_hits", 4))
        Bizzy_Awards_Fire(charger, "scattering_ram", 1);
}

static void Event_TankSpawn(Event event, const char[] name, bool dontBroadcast)
{
    int tank = GetClientOfUserId(event.GetInt("userid"));
    if (tank > 0 && tank <= MaxClients && IsClientInGame(tank))
    {
        if (!IsFakeClient(tank))
            g_Clients[tank].siType = view_as<int>(SI_Tank);
        Bizzy_TankWitch_TankSpawn(tank);

        // Director placement log
        float pos[3];
        GetClientAbsOrigin(tank, pos);
        Bizzy_WriteDirectorPlacement("tank", pos);
    }
}

static void Event_WitchSpawn(Event event, const char[] name, bool dontBroadcast)
{
    int witchEnt = event.GetInt("witchid");
    if (witchEnt > 0)
    {
        Bizzy_TankWitch_WitchSpawn(witchEnt);
        if (IsValidEntity(witchEnt))
        {
            float pos[3];
            GetEntPropVector(witchEnt, Prop_Send, "m_vecOrigin", pos);
            Bizzy_WriteDirectorPlacement("witch", pos);
        }
    }
}

stock void Bizzy_WriteDirectorPlacement(const char[] kind, const float pos[3])
{
    if (g_DB == null || g_ServerId == 0 || g_CurrentMapId == 0) return;
    char escKind[16];
    Bizzy_DB_Escape(kind, escKind, sizeof escKind);
    char sql[384];
    FormatEx(sql, sizeof sql,
        "INSERT INTO director_placements "
        ... "(server_id, map_id, match_round_id, boss_kind, pos_x, pos_y, pos_z, placed_at) "
        ... "VALUES (%d, %d, NULLIF(%d, 0), '%s', %d, %d, %d, NOW())",
        g_ServerId, g_CurrentMapId, Bizzy_Versus_GetRoundId(), escKind,
        RoundToFloor(pos[0]), RoundToFloor(pos[1]), RoundToFloor(pos[2]));
    Bizzy_DB_Exec(sql);
}

static void Event_ZombieIgnited(Event event, const char[] name, bool dontBroadcast)
{
    int who = GetClientOfUserId(event.GetInt("userid"));
    if (Bizzy_IsValidPlayer(who))
        Bizzy_Score(who, GetCV("bizzymod_stats_burn", 1), "burn");
}

static void Event_CarAlarm(Event event, const char[] name, bool dontBroadcast)
{
    int who = GetClientOfUserId(event.GetInt("userid"));
    if (Bizzy_IsValidPlayer(who))
        Bizzy_Awards_Fire(who, "caralarm_triggered", 1);
}

static void Event_GascanPoured(Event event, const char[] name, bool dontBroadcast)
{
    int who = GetClientOfUserId(event.GetInt("userid"));
    if (Bizzy_IsValidPlayer(who)) Bizzy_Awards_Fire(who, "gas_pour", 1);
}

static void Event_AmmoUpgrade(Event event, const char[] name, bool dontBroadcast)
{
    int who = GetClientOfUserId(event.GetInt("userid"));
    if (Bizzy_IsValidPlayer(who)) Bizzy_Awards_Fire(who, "ammo_upgrade", 1);
}

// -----------------------------------------------------------------------------
// Round flow
// -----------------------------------------------------------------------------

static void Event_FinaleWin(Event event, const char[] name, bool dontBroadcast)
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!Bizzy_IsValidPlayer(i)) continue;
        if (GetClientTeam(i) != TEAM_SURVIVORS) continue;
        Bizzy_Awards_Fire(i, "campaign", 1);
    }
}

static void Event_MissionLost(Event event, const char[] name, bool dontBroadcast)
{
    // Optional: penalty to survivor team. Off by default.
}

static void Event_MapTransition(Event event, const char[] name, bool dontBroadcast)
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!Bizzy_IsValidPlayer(i)) continue;
        if (GetClientTeam(i) != TEAM_SURVIVORS) continue;
        Bizzy_Awards_Fire(i, "all_in_safehouse", 1);
    }
}

static void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
    // Mode-specific bookkeeping happens in timedmaps / sessions.
}

static void Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (Bizzy_IsValidPlayer(client))
        g_Clients[client].team = event.GetInt("team");
}

static void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (!Bizzy_IsValidPlayer(client)) return;
    if (GetClientTeam(client) == TEAM_INFECTED)
    {
        int zc = Bizzy_ZombieClass(client);
        g_Clients[client].siType = view_as<int>(Bizzy_NormalizeZombieClass(zc));
        g_Clients[client].spawnStartTime = Bizzy_NowEpoch();
    }
    if (GetClientTeam(client) == TEAM_SURVIVORS && IsPlayerAlive(client))
    {
        g_Clients[client].aliveSinceEpoch = GetTime();
    }
}

static void Event_WeaponFire(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (!Bizzy_IsValidPlayer(client)) return;
    char weapon[64];
    event.GetString("weapon", weapon, sizeof weapon);

    if (StrEqual(weapon, "pipe_bomb"))   g_Clients[client].pipeBombsThrown++;
    else if (StrEqual(weapon, "molotov")) g_Clients[client].molotovsThrown++;
    else if (StrEqual(weapon, "vomitjar")) g_Clients[client].bileBombsThrown++;
    else
    {
        g_Clients[client].shotsFired++;
        // Per-weapon shots_fired increment (separate from per-hit attribution).
        Bizzy_Weapons_RecordShot(client, weapon);
    }
}

// --- 007 extended event handlers ---

static void Event_AbilityUse(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (!Bizzy_IsValidPlayer(client)) return;

    char ability[48];
    event.GetString("ability", ability, sizeof ability);

    // Record start position + timestamp for flight/drag distance metrics.
    float pos[3];
    GetClientAbsOrigin(client, pos);
    g_Clients[client].siAbilityStartX = RoundToFloor(pos[0]);
    g_Clients[client].siAbilityStartY = RoundToFloor(pos[1]);
    g_Clients[client].siAbilityStartZ = RoundToFloor(pos[2]);
    g_Clients[client].siAbilityStartMs = RoundToFloor(GetEngineTime() * 1000.0);

    if      (StrContains(ability, "lunge", false) >= 0)
        g_Clients[client].siAbilityKind = 1;
    else if (StrContains(ability, "tongue", false) >= 0)
        g_Clients[client].siAbilityKind = 2;
    else if (StrContains(ability, "charge", false) >= 0)
        g_Clients[client].siAbilityKind = 3;
    else
        g_Clients[client].siAbilityKind = 0;

    Bizzy_SiSpawnRecord_AbilityUse(client);
}

static void Event_TongueGrab(Event event, const char[] name, bool dontBroadcast)
{
    int smoker = GetClientOfUserId(event.GetInt("userid"));
    int victim = GetClientOfUserId(event.GetInt("victim"));
    if (Bizzy_IsValidPlayer(victim))
        g_Clients[victim].pinnedBySmoker++;
    // Record drag start position for the smoker
    if (Bizzy_IsValidPlayer(smoker) && Bizzy_IsValidPlayer(victim))
    {
        float pos[3];
        GetClientAbsOrigin(victim, pos);
        g_Clients[smoker].smokerVictimUid = GetClientUserId(victim);
        g_Clients[smoker].smokerGrabX = RoundToFloor(pos[0]);
        g_Clients[smoker].smokerGrabY = RoundToFloor(pos[1]);
    }
}

static void Event_ChokeStart(Event event, const char[] name, bool dontBroadcast)
{
    int victim = GetClientOfUserId(event.GetInt("victim"));
    if (Bizzy_IsValidPlayer(victim))
        g_Clients[victim].pinnedBySmoker++;
}

static void Event_PinJockey(Event event, const char[] name, bool dontBroadcast)
{
    int victim = GetClientOfUserId(event.GetInt("victim"));
    if (Bizzy_IsValidPlayer(victim))
        g_Clients[victim].pinnedByJockey++;
}

static void Event_PinChargerPummel(Event event, const char[] name, bool dontBroadcast)
{
    int victim = GetClientOfUserId(event.GetInt("victim"));
    if (Bizzy_IsValidPlayer(victim))
        g_Clients[victim].pinnedByCharger++;
}

static void Event_PinChargerCarry(Event event, const char[] name, bool dontBroadcast)
{
    int victim = GetClientOfUserId(event.GetInt("victim"));
    if (Bizzy_IsValidPlayer(victim))
        g_Clients[victim].pinnedByCharger++;
}

static void Event_BoomerExploded(Event event, const char[] name, bool dontBroadcast)
{
    // Self-destruct from explosion; useful for survivor-side "boomer pop" stats
    // if we later add a column. Currently no-op.
}

static void Event_VomitedOn(Event event, const char[] name, bool dontBroadcast)
{
    int victim = GetClientOfUserId(event.GetInt("userid"));
    if (Bizzy_IsValidPlayer(victim))
        g_Clients[victim].vomitedOn++;
}

static void Event_PipeUsed(Event event, const char[] name, bool dontBroadcast)
{
    int who = GetClientOfUserId(event.GetInt("userid"));
    if (Bizzy_IsValidPlayer(who)) g_Clients[who].pipeBombsThrown++;
}

static void Event_MolotovThrown(Event event, const char[] name, bool dontBroadcast)
{
    int who = GetClientOfUserId(event.GetInt("userid"));
    if (Bizzy_IsValidPlayer(who)) g_Clients[who].molotovsThrown++;
}

static void Event_BileThrown(Event event, const char[] name, bool dontBroadcast)
{
    int who = GetClientOfUserId(event.GetInt("userid"));
    if (Bizzy_IsValidPlayer(who))
    {
        g_Clients[who].bileBombsThrown++;
        Bizzy_Awards_Fire(who, "bile_throw", 1);
    }
}

static void Event_WeaponZoom(Event event, const char[] name, bool dontBroadcast)
{
    // hook reserved for future per-weapon zoom-stat capture
}

// -----------------------------------------------------------------------------
// SI flight/drag terminal events
// -----------------------------------------------------------------------------

static void Event_TongueRelease(Event event, const char[] name, bool dontBroadcast)
{
    int smoker = GetClientOfUserId(event.GetInt("userid"));
    if (!Bizzy_IsValidPlayer(smoker)) return;
    if (g_Clients[smoker].smokerVictimUid == 0) return;

    int victim = GetClientOfUserId(g_Clients[smoker].smokerVictimUid);
    if (Bizzy_IsValidPlayer(victim))
    {
        float pos[3];
        GetClientAbsOrigin(victim, pos);
        int dx = RoundToFloor(pos[0]) - g_Clients[smoker].smokerGrabX;
        int dy = RoundToFloor(pos[1]) - g_Clients[smoker].smokerGrabY;
        int dragDist = RoundToFloor(SquareRoot(float(dx*dx + dy*dy)));
        if (dragDist < 8000) // teleport guard
            Bizzy_SiStats_AccumDrag(smoker, dragDist);
        if (dragDist >= 2000)
            Bizzy_Awards_Fire(smoker, "smoker_long_drag", 1);
    }
    g_Clients[smoker].smokerVictimUid = 0;
}

static void Event_SmokerSelfClear(Event event, const char[] name, bool dontBroadcast)
{
    // The survivor shot the smoker off themselves
    int victim = GetClientOfUserId(event.GetInt("victim"));
    int smoker = GetClientOfUserId(event.GetInt("userid"));
    if (Bizzy_IsValidPlayer(victim))
        g_Clients[victim].selfEscapes++;
    if (Bizzy_IsValidPlayer(smoker))
        Bizzy_SiStats_AccumSmokerSelfClear(smoker);
}

static void Event_GascanInterrupted(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (!Bizzy_IsValidPlayer(client)) return;
    // gascans_partial is a column on player_stats; we track via direct UPSERT
    // because there's no per-session counter for it (low-volume event).
    if (g_DB == null || g_Clients[client].playerId == 0) return;
    char sql[384];
    FormatEx(sql, sizeof sql,
        "INSERT INTO player_stats (player_id, gamemode_id, difficulty_id, server_id, gascans_partial) "
        ... "VALUES (%d, %d, %d, 0, 1) "
        ... "ON DUPLICATE KEY UPDATE gascans_partial = gascans_partial + 1",
        g_Clients[client].playerId, view_as<int>(g_CurrentMode),
        view_as<int>(g_CurrentDifficulty));
    Bizzy_DB_Exec(sql);
}

stock void Bizzy_SiStats_AccumDrag(int smoker, int distance)
{
    if (g_DB == null || g_Clients[smoker].playerId == 0) return;
    char sql[512];
    FormatEx(sql, sizeof sql,
        "INSERT INTO player_si_stats (player_id, gamemode_id, si_id, "
        ... "smoker_drag_total_units, smoker_max_drag_units) "
        ... "VALUES (%d, %d, %d, %d, %d) "
        ... "ON DUPLICATE KEY UPDATE "
        ... "  smoker_drag_total_units = smoker_drag_total_units + VALUES(smoker_drag_total_units), "
        ... "  smoker_max_drag_units   = GREATEST(smoker_max_drag_units, VALUES(smoker_max_drag_units))",
        g_Clients[smoker].playerId, view_as<int>(g_CurrentMode),
        view_as<int>(SI_Smoker), distance, distance);
    Bizzy_DB_Exec(sql);
}

stock void Bizzy_SiStats_AccumSmokerSelfClear(int smoker)
{
    if (g_DB == null || g_Clients[smoker].playerId == 0) return;
    char sql[384];
    FormatEx(sql, sizeof sql,
        "INSERT INTO player_si_stats (player_id, gamemode_id, si_id, smoker_self_clears) "
        ... "VALUES (%d, %d, %d, 1) "
        ... "ON DUPLICATE KEY UPDATE smoker_self_clears = smoker_self_clears + 1",
        g_Clients[smoker].playerId, view_as<int>(g_CurrentMode),
        view_as<int>(SI_Smoker));
    Bizzy_DB_Exec(sql);
}

stock void Bizzy_SiStats_AccumPounce(int hunter, int distance, int durationMs, bool wasSkeeted)
{
    if (g_DB == null || g_Clients[hunter].playerId == 0) return;
    char sql[768];
    FormatEx(sql, sizeof sql,
        "INSERT INTO player_si_stats (player_id, gamemode_id, si_id, "
        ... "hunter_pounce_total_units, hunter_pounce_max_units, "
        ... "hunter_pounce_total_time_ms, hunter_pounce_skeeted) "
        ... "VALUES (%d, %d, %d, %d, %d, %d, %d) "
        ... "ON DUPLICATE KEY UPDATE "
        ... "  hunter_pounce_total_units    = hunter_pounce_total_units + VALUES(hunter_pounce_total_units), "
        ... "  hunter_pounce_max_units      = GREATEST(hunter_pounce_max_units, VALUES(hunter_pounce_max_units)), "
        ... "  hunter_pounce_total_time_ms  = hunter_pounce_total_time_ms + VALUES(hunter_pounce_total_time_ms), "
        ... "  hunter_pounce_skeeted        = hunter_pounce_skeeted + VALUES(hunter_pounce_skeeted)",
        g_Clients[hunter].playerId, view_as<int>(g_CurrentMode),
        view_as<int>(SI_Hunter),
        distance, distance, durationMs, wasSkeeted ? 1 : 0);
    Bizzy_DB_Exec(sql);
}

stock void Bizzy_SiSpawnRecord_AbilityUse(int client)
{
    // Hook point — for future si_spawn_records granular logging.
    // Schema row is opened on SI spawn (player_spawn handler) and closed
    // on SI death.
}

// -----------------------------------------------------------------------------
// 008+: new event handlers
// -----------------------------------------------------------------------------

static void Event_WeaponReload(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (Bizzy_IsValidPlayer(client))
        Bizzy_Combat_OnReload(client);
}

static void Event_ReviveBegin(Event event, const char[] name, bool dontBroadcast)
{
    // info-only; the actual credit happens on revive_success
}

static void Event_HealBegin(Event event, const char[] name, bool dontBroadcast)
{
    // The healer's HP at heal time isn't directly relevant; the *patient*
    // HP is what we want. Heal_success carries it.
}

static void Event_PillsFail(Event event, const char[] name, bool dontBroadcast)
{
    // Pills consumed but full HP — no-op for now.
}

static int g_SaferoomOrdinalCounter = 0; // resets per map

static void Event_EnteredSafe(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (!Bizzy_IsValidPlayer(client)) return;
    if (GetClientTeam(client) != TEAM_SURVIVORS) return;
    int hp = GetClientHealth(client);
    g_Clients[client].hpAtSaferoomSum += hp;
    g_Clients[client].hpAtSaferoomCount++;

    g_SaferoomOrdinalCounter++;
    g_Clients[client].saferoomOrdinal = g_SaferoomOrdinalCounter;
    Bizzy_WriteSaferoomArrival(client, g_SaferoomOrdinalCounter, hp);

    // Hoarded items: count what's in inventory right now
    int pills = 0, adren = 0, kits = 0, thr = 0, defs = 0;
    CountHoarded(client, pills, adren, kits, thr, defs);
    g_Clients[client].pillsHoarded      += pills;
    g_Clients[client].adrenalineHoarded += adren;
    g_Clients[client].medkitsHoarded    += kits;
    g_Clients[client].throwablesHoarded += thr;
    g_Clients[client].defibsHoarded     += defs;

    if ((pills + adren + kits + thr + defs) >= 4)
        Bizzy_Awards_Fire(client, "hoarder", 1);

    // First-in / last-in awards
    if (g_Clients[client].saferoomOrdinal == 1)
        Bizzy_Awards_Fire(client, "first_in", 1);
}

stock void Bizzy_WriteSaferoomArrival(int client, int ordinal, int hp)
{
    if (g_DB == null || g_Clients[client].playerId == 0) return;
    if (g_CurrentMapId == 0 || g_ServerId == 0) return;
    char sql[512];
    FormatEx(sql, sizeof sql,
        "INSERT INTO saferoom_arrivals "
        ... "(server_id, player_id, map_id, match_id, arrived_at, order_idx, hp_at_arrival) "
        ... "VALUES (%d, %d, %d, NULLIF(%d, 0), NOW(), %d, %d)",
        g_ServerId, g_Clients[client].playerId, g_CurrentMapId,
        Bizzy_Versus_GetMatchId(), ordinal, hp);
    Bizzy_DB_Exec(sql);
}

stock void Bizzy_Events_ResetSaferoomOrdinal()
{
    g_SaferoomOrdinalCounter = 0;
}

static void Event_DoorClose(Event event, const char[] name, bool dontBroadcast)
{
    bool checkpoint = event.GetBool("checkpoint", false);
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (!checkpoint) return;
    if (Bizzy_IsValidPlayer(client) && GetClientTeam(client) == TEAM_SURVIVORS)
    {
        g_Clients[client].saferoomDoorCloses++;
        Bizzy_Awards_Fire(client, "saferoom_save", 1);
    }
}

static void Event_PanicStart(Event event, const char[] name, bool dontBroadcast)
{
    Bizzy_Coord_CrescendoStart(name);
}

static void Event_PanicEnd(Event event, const char[] name, bool dontBroadcast)
{
    Bizzy_Coord_CrescendoFinish();
}

static void Event_FinaleStart(Event event, const char[] name, bool dontBroadcast)
{
    Bizzy_Coord_ResetFinaleState();
}

static void Event_ZombieSpawned(Event event, const char[] name, bool dontBroadcast)
{
    // Reserved for tracking director spawn placement; we currently log
    // tank+witch placements at tank_spawn / witch_spawn via tank_witch.sp.
}

// -----------------------------------------------------------------------------
// Helpers
// -----------------------------------------------------------------------------

stock void CountHoarded(int client, int &pills, int &adren, int &kits, int &thr, int &defs)
{
    pills = adren = kits = thr = defs = 0;
    // L4D2 slot enums: 0=primary, 1=secondary, 2=throwable, 3=medkit, 4=pills
    // Best-effort: look at each weapon entity in the player's inventory
    for (int slot = 0; slot < 5; slot++)
    {
        int wpn = GetPlayerWeaponSlot(client, slot);
        if (wpn <= 0) continue;
        char cls[32];
        GetEntityClassname(wpn, cls, sizeof cls);
        if (StrEqual(cls, "weapon_pain_pills"))   pills++;
        else if (StrEqual(cls, "weapon_adrenaline")) adren++;
        else if (StrEqual(cls, "weapon_first_aid_kit")) kits++;
        else if (StrEqual(cls, "weapon_defibrillator")) defs++;
        else if (StrEqual(cls, "weapon_pipe_bomb") || StrEqual(cls, "weapon_molotov")
              || StrEqual(cls, "weapon_vomitjar"))
            thr++;
    }
}

// -----------------------------------------------------------------------------
// ConVar helper. Lazily looks up a CV by name, defaulting if missing so we
// don't fail closed when an optional tunable hasn't been registered.
// -----------------------------------------------------------------------------

static int GetCV(const char[] name, int defaultValue)
{
    ConVar c = FindConVar(name);
    if (c == null) return defaultValue;
    return c.IntValue;
}
