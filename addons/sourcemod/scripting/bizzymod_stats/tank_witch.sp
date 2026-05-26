/**
 * tank_witch.sp — per-tank-spawn and per-witch-encounter records.
 *
 * Each tank's life is one row in tank_records:
 *   - opens on tank_spawn
 *   - accumulates: distance, incaps caused, kills caused, damage dealt/received,
 *     controller hand-offs
 *   - closes on player_death (victim_class == tank) or round_end
 *
 * Each witch encounter is one row in witch_records: appeared -> startled
 * -> killed/crowned/avoided.
 *
 * Tank position sampling is driven by movement.sp's existing 4Hz timer.
 */

#define MAX_ACTIVE_TANKS   4
#define MAX_ACTIVE_WITCHES 8

enum struct TankRec
{
    bool   inUse;
    int    entRef;
    int    dbId;
    int    spawnEpoch;
    int    lastX;
    int    lastY;
    int    lastZ;
    int    distanceUnits;
    int    incapsCaused;
    int    killsCaused;
    int    damageDealt;
    int    damageReceived;
    int    rocksThrown;
    int    rocksHit;
    int    punchesLanded;
    int    controllerCount;
    int    finalControllerUid;
}

enum struct WitchRec
{
    bool   inUse;
    int    entRef;
    int    dbId;
    int    seenEpoch;
    int    startlerUid;
    int    incappedUid;
    int    state;       // 0=appeared, 1=startled, 2=resolved
}

TankRec  g_Tanks[MAX_ACTIVE_TANKS];
WitchRec g_Witches[MAX_ACTIVE_WITCHES];

void Bizzy_OnTankWitchInit() { /* state lives in g_Tanks / g_Witches */ }

// -----------------------------------------------------------------------------
// Tank lifecycle
// -----------------------------------------------------------------------------

stock void Bizzy_TankWitch_TankSpawn(int tankClient)
{
    if (!IsClientInGame(tankClient)) return;
    int slot = AllocTankSlot();
    if (slot < 0) return;

    g_Tanks[slot].inUse = true;
    g_Tanks[slot].entRef = EntIndexToEntRef(tankClient);
    g_Tanks[slot].spawnEpoch = GetTime();
    g_Tanks[slot].finalControllerUid = IsFakeClient(tankClient)
        ? 0 : GetClientUserId(tankClient);
    g_Tanks[slot].controllerCount = IsFakeClient(tankClient) ? 0 : 1;
    g_Tanks[slot].distanceUnits = 0;
    g_Tanks[slot].incapsCaused = 0;
    g_Tanks[slot].killsCaused = 0;
    g_Tanks[slot].damageDealt = 0;
    g_Tanks[slot].damageReceived = 0;
    g_Tanks[slot].rocksThrown = 0;
    g_Tanks[slot].rocksHit = 0;
    g_Tanks[slot].punchesLanded = 0;

    float pos[3];
    GetClientAbsOrigin(tankClient, pos);
    g_Tanks[slot].lastX = RoundToFloor(pos[0]);
    g_Tanks[slot].lastY = RoundToFloor(pos[1]);
    g_Tanks[slot].lastZ = RoundToFloor(pos[2]);

    if (g_DB == null || g_ServerId == 0) return;
    char sql[384];
    FormatEx(sql, sizeof sql,
        "INSERT INTO tank_records (server_id, match_round_id, map_id, spawned_at) "
        ... "VALUES (%d, NULLIF(%d, 0), %d, NOW())",
        g_ServerId, Bizzy_Versus_GetRoundId(), g_CurrentMapId);

    DataPack dp = new DataPack();
    dp.WriteCell(slot);
    g_DB.Query(OnTankInserted, sql, dp);
}

static void OnTankInserted(Database db, DBResultSet rs, const char[] error, DataPack dp)
{
    dp.Reset();
    int slot = dp.ReadCell();
    delete dp;
    if (rs == null) { LogError("[bizzymod-stats] tank insert: %s", error); return; }
    if (slot < 0 || slot >= MAX_ACTIVE_TANKS) return;
    g_Tanks[slot].dbId = rs.InsertId;
}

stock void Bizzy_TankWitch_SamplePositions()
{
    for (int i = 0; i < MAX_ACTIVE_TANKS; i++)
    {
        if (!g_Tanks[i].inUse) continue;
        int ent = EntRefToEntIndex(g_Tanks[i].entRef);
        if (ent <= 0 || !IsValidEntity(ent)) continue;
        float pos[3];
        GetEntPropVector(ent, Prop_Send, "m_vecOrigin", pos);
        int x = RoundToFloor(pos[0]);
        int y = RoundToFloor(pos[1]);
        int z = RoundToFloor(pos[2]);
        int dx = x - g_Tanks[i].lastX;
        int dy = y - g_Tanks[i].lastY;
        int dz = z - g_Tanks[i].lastZ;
        int dist = RoundToFloor(SquareRoot(float(dx*dx + dy*dy + dz*dz)));
        if (dist < 4000) g_Tanks[i].distanceUnits += dist;
        g_Tanks[i].lastX = x;
        g_Tanks[i].lastY = y;
        g_Tanks[i].lastZ = z;
    }
}

stock void Bizzy_TankWitch_TankIncap(int tankClient)
{
    int s = FindTankSlot(tankClient);
    if (s >= 0) g_Tanks[s].incapsCaused++;
}

stock void Bizzy_TankWitch_TankKilledSurvivor(int tankClient)
{
    int s = FindTankSlot(tankClient);
    if (s >= 0) g_Tanks[s].killsCaused++;
}

stock void Bizzy_TankWitch_TankDealt(int tankClient, int damage)
{
    int s = FindTankSlot(tankClient);
    if (s >= 0) g_Tanks[s].damageDealt += damage;
}

stock void Bizzy_TankWitch_TankReceived(int tankClient, int damage)
{
    int s = FindTankSlot(tankClient);
    if (s >= 0) g_Tanks[s].damageReceived += damage;
}

stock void Bizzy_TankWitch_TankRockHit(int tankClient)
{
    int s = FindTankSlot(tankClient);
    if (s >= 0) g_Tanks[s].rocksHit++;
}

stock void Bizzy_TankWitch_TankPunch(int tankClient)
{
    int s = FindTankSlot(tankClient);
    if (s >= 0) g_Tanks[s].punchesLanded++;
}

stock void Bizzy_TankWitch_TankHandoff(int newController)
{
    if (!Bizzy_IsValidPlayer(newController)) return;
    for (int i = 0; i < MAX_ACTIVE_TANKS; i++)
    {
        if (!g_Tanks[i].inUse) continue;
        int ent = EntRefToEntIndex(g_Tanks[i].entRef);
        if (ent != newController) continue;
        int uid = GetClientUserId(newController);
        if (g_Tanks[i].finalControllerUid != uid)
        {
            g_Tanks[i].controllerCount++;
            int prev = GetClientOfUserId(g_Tanks[i].finalControllerUid);
            if (Bizzy_IsValidPlayer(prev))
                Bizzy_Awards_Fire(prev, "tank_handoff", 1);
            g_Tanks[i].finalControllerUid = uid;
        }
    }
}

stock void Bizzy_TankWitch_TankKilled(int tankClient, int killer, const char[] weapon)
{
    int slot = FindTankSlot(tankClient);
    if (slot < 0) return;

    int survival = GetTime() - g_Tanks[slot].spawnEpoch;
    int killerPid = (Bizzy_IsValidPlayer(killer)) ? g_Clients[killer].playerId : 0;
    int controllerClient = GetClientOfUserId(g_Tanks[slot].finalControllerUid);
    int controllerPid = (controllerClient > 0 && Bizzy_IsValidPlayer(controllerClient))
        ? g_Clients[controllerClient].playerId : 0;

    char weaponEsc[100];
    Bizzy_DB_Escape(weapon, weaponEsc, sizeof weaponEsc);

    char sql[640];
    FormatEx(sql, sizeof sql,
        "UPDATE tank_records SET "
        ... "  killed_at=NOW(), survival_s=%d, distance_units=%d, "
        ... "  incaps_caused=%d, kills_caused=%d, rocks_thrown=%d, rocks_hit=%d, "
        ... "  punches_landed=%d, damage_dealt=%d, damage_received=%d, "
        ... "  controlling_players=%d, final_controller_id=NULLIF(%d, 0), "
        ... "  killer_id=NULLIF(%d, 0), killer_weapon='%s', outcome='killed' "
        ... "WHERE id=%d",
        survival, g_Tanks[slot].distanceUnits,
        g_Tanks[slot].incapsCaused, g_Tanks[slot].killsCaused,
        g_Tanks[slot].rocksThrown, g_Tanks[slot].rocksHit,
        g_Tanks[slot].punchesLanded, g_Tanks[slot].damageDealt,
        g_Tanks[slot].damageReceived, g_Tanks[slot].controllerCount,
        controllerPid, killerPid, weaponEsc, g_Tanks[slot].dbId);
    Bizzy_DB_Exec(sql);

    // Write boss damage log: reads from combat.sp's g_VictimLog (same TU).
    WriteBossDmgLog(g_Tanks[slot].dbId, "tank", tankClient, killer);

    g_Tanks[slot].inUse = false;
}

static void WriteBossDmgLog(int bossRecordId, const char[] kind, int bossEnt, int killer)
{
    if (g_DB == null || bossRecordId == 0) return;
    if (bossEnt < 0 || bossEnt >= 2049) return;

    int total = 0;
    for (int i = 0; i < g_VictimLog[bossEnt].count; i++)
        total += g_VictimLog[bossEnt].damage[i];
    if (total <= 0) return;

    int killerUid = Bizzy_IsValidPlayer(killer) ? GetClientUserId(killer) : 0;

    Transaction txn = Bizzy_DB_BeginTxn();
    char sql[384], kindEsc[16];
    Bizzy_DB_Escape(kind, kindEsc, sizeof kindEsc);

    for (int i = 0; i < g_VictimLog[bossEnt].count; i++)
    {
        int uid = g_VictimLog[bossEnt].attackerUid[i];
        int dmg = g_VictimLog[bossEnt].damage[i];
        int cli = GetClientOfUserId(uid);
        if (cli == 0 || g_Clients[cli].playerId == 0) continue;
        int pct = total > 0 ? (dmg * 10000 / total) : 0;
        int kb = (uid == killerUid) ? 1 : 0;
        FormatEx(sql, sizeof sql,
            "INSERT INTO boss_damage_log "
            ... "(boss_kind, boss_record_id, player_id, damage, damage_pct, dealt_killing_blow, at) "
            ... "VALUES ('%s', %d, %d, %d, %d/100.0, %d, NOW())",
            kindEsc, bossRecordId, g_Clients[cli].playerId, dmg, pct, kb);
        txn.AddQuery(sql);
    }
    Bizzy_DB_RunTxn(txn);
}

static int FindTankSlot(int client)
{
    for (int i = 0; i < MAX_ACTIVE_TANKS; i++)
        if (g_Tanks[i].inUse && EntRefToEntIndex(g_Tanks[i].entRef) == client) return i;
    return -1;
}

static int AllocTankSlot()
{
    for (int i = 0; i < MAX_ACTIVE_TANKS; i++)
        if (!g_Tanks[i].inUse) return i;
    return -1;
}

// -----------------------------------------------------------------------------
// Witch lifecycle
// -----------------------------------------------------------------------------

stock void Bizzy_TankWitch_WitchSpawn(int witchEnt)
{
    int slot = AllocWitchSlot();
    if (slot < 0) return;
    g_Witches[slot].inUse = true;
    g_Witches[slot].entRef = EntIndexToEntRef(witchEnt);
    g_Witches[slot].seenEpoch = GetTime();
    g_Witches[slot].startlerUid = 0;
    g_Witches[slot].incappedUid = 0;
    g_Witches[slot].state = 0;

    if (g_DB == null || g_ServerId == 0) return;
    char sql[384];
    FormatEx(sql, sizeof sql,
        "INSERT INTO witch_records (server_id, match_round_id, map_id, seen_at, outcome) "
        ... "VALUES (%d, NULLIF(%d, 0), %d, NOW(), 'avoided')",
        g_ServerId, Bizzy_Versus_GetRoundId(), g_CurrentMapId);

    DataPack dp = new DataPack();
    dp.WriteCell(slot);
    g_DB.Query(OnWitchInserted, sql, dp);
}

static void OnWitchInserted(Database db, DBResultSet rs, const char[] error, DataPack dp)
{
    dp.Reset();
    int slot = dp.ReadCell();
    delete dp;
    if (rs == null || slot < 0 || slot >= MAX_ACTIVE_WITCHES) return;
    g_Witches[slot].dbId = rs.InsertId;
}

stock void Bizzy_TankWitch_WitchStartled(int witchEnt, int startler)
{
    int s = FindWitchSlot(witchEnt);
    if (s < 0) return;
    g_Witches[s].state = 1;
    g_Witches[s].startlerUid = Bizzy_IsValidPlayer(startler) ? GetClientUserId(startler) : 0;
}

stock void Bizzy_TankWitch_WitchKilled(int witchEnt, int killer, bool crown)
{
    int slot = FindWitchSlot(witchEnt);
    if (slot < 0) return;
    g_Witches[slot].state = 2;

    char outcome[24];
    if      (crown)                                strcopy(outcome, sizeof outcome, "crowned");
    else if (g_Witches[slot].startlerUid != 0)    strcopy(outcome, sizeof outcome, "killed_after_startle");
    else                                          strcopy(outcome, sizeof outcome, "killed");

    int killerPid = (Bizzy_IsValidPlayer(killer) && g_Clients[killer].playerId > 0)
        ? g_Clients[killer].playerId : 0;
    int startlerCli = GetClientOfUserId(g_Witches[slot].startlerUid);
    int startlerPid = (startlerCli > 0 && Bizzy_IsValidPlayer(startlerCli)
                       && g_Clients[startlerCli].playerId > 0)
        ? g_Clients[startlerCli].playerId : 0;

    char sql[384], escOutcome[64];
    Bizzy_DB_Escape(outcome, escOutcome, sizeof escOutcome);
    FormatEx(sql, sizeof sql,
        "UPDATE witch_records SET outcome='%s', killed_by_id=NULLIF(%d, 0), "
        ... "startled_by_id=NULLIF(%d, 0) "
        ... "WHERE id=%d",
        escOutcome, killerPid, startlerPid, g_Witches[slot].dbId);
    Bizzy_DB_Exec(sql);

    if (Bizzy_IsValidPlayer(startlerCli) && g_Witches[slot].incappedUid == 0)
        Bizzy_Awards_Fire(startlerCli, "witch_chase_dodge", 1);

    g_Witches[slot].inUse = false;
}

stock void Bizzy_TankWitch_WitchIncapped(int witchEnt, int victim)
{
    int s = FindWitchSlot(witchEnt);
    if (s < 0) return;
    g_Witches[s].incappedUid = Bizzy_IsValidPlayer(victim) ? GetClientUserId(victim) : 0;
}

static int FindWitchSlot(int ent)
{
    for (int i = 0; i < MAX_ACTIVE_WITCHES; i++)
        if (g_Witches[i].inUse && EntRefToEntIndex(g_Witches[i].entRef) == ent)
            return i;
    return -1;
}

static int AllocWitchSlot()
{
    for (int i = 0; i < MAX_ACTIVE_WITCHES; i++)
        if (!g_Witches[i].inUse) return i;
    return -1;
}
