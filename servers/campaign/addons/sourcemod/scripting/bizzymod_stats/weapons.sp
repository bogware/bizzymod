/**
 * weapons.sp — per-weapon stat capture.
 *
 * Weapons are addressed by their entity classname / weapon name. Unknown
 * names are inserted on first sight so the catalog auto-extends to cover
 * custom weapons from mods.
 */

static StringMap g_WeaponIds; // code -> weapon_id (int)

void Bizzy_Weapons_Init()
{
    g_WeaponIds = new StringMap();
    // Catalog is loaded after DB ready (see scoring/events callers).
    if (g_DB != null) LoadWeapons();
}

static void LoadWeapons()
{
    g_DB.Query(OnWeaponsLoaded, "SELECT id, code FROM weapons");
}

static void OnWeaponsLoaded(Database db, DBResultSet rs, const char[] error, any data)
{
    if (rs == null) return;
    while (rs.FetchRow())
    {
        int id = rs.FetchInt(0);
        char code[64];
        rs.FetchString(1, code, sizeof code);
        g_WeaponIds.SetValue(code, id);
    }
}

stock void Bizzy_Weapons_RecordHit(int client, const char[] weapon, int damage)
{
    if (g_DB == null || g_Clients[client].playerId == 0 || weapon[0] == '\0') return;
    if (g_WeaponIds == null) Bizzy_Weapons_Init();

    int wid;
    if (!g_WeaponIds.GetValue(weapon, wid))
    {
        EnsureWeapon(weapon, client, damage, /*kill=*/false, /*hs=*/false);
        return;
    }
    // NOTE: do NOT increment client-level shotsFired here — Event_WeaponFire
    // already counts shots fired per-tick. This handler is per-hit only.

    char sql[512];
    FormatEx(sql, sizeof sql,
        "INSERT INTO player_weapon_stats "
        ... "(player_id, weapon_id, shots_hit, damage_dealt) "
        ... "VALUES (%d, %d, 1, %d) "
        ... "ON DUPLICATE KEY UPDATE "
        ... "  shots_hit   = shots_hit + 1, "
        ... "  damage_dealt = damage_dealt + VALUES(damage_dealt)",
        g_Clients[client].playerId, wid, damage);
    Bizzy_DB_Exec(sql);
}

stock void Bizzy_Weapons_RecordShot(int client, const char[] weapon)
{
    if (g_DB == null || g_Clients[client].playerId == 0 || weapon[0] == '\0') return;
    if (g_WeaponIds == null) Bizzy_Weapons_Init();

    int wid;
    if (!g_WeaponIds.GetValue(weapon, wid))
        return; // weapon will be inserted on first hit, when we have damage context

    char sql[384];
    FormatEx(sql, sizeof sql,
        "INSERT INTO player_weapon_stats (player_id, weapon_id, shots_fired) "
        ... "VALUES (%d, %d, 1) "
        ... "ON DUPLICATE KEY UPDATE shots_fired = shots_fired + 1",
        g_Clients[client].playerId, wid);
    Bizzy_DB_Exec(sql);
}

stock void Bizzy_Weapons_RecordKill(int client, const char[] weapon, bool headshot)
{
    if (g_DB == null || g_Clients[client].playerId == 0 || weapon[0] == '\0') return;
    if (g_WeaponIds == null) Bizzy_Weapons_Init();

    int wid;
    if (!g_WeaponIds.GetValue(weapon, wid))
    {
        EnsureWeapon(weapon, client, 0, /*kill=*/true, headshot);
        return;
    }

    char sql[512];
    FormatEx(sql, sizeof sql,
        "INSERT INTO player_weapon_stats (player_id, weapon_id, kills, headshots) "
        ... "VALUES (%d, %d, 1, %d) "
        ... "ON DUPLICATE KEY UPDATE "
        ... "  kills = kills + 1, "
        ... "  headshots = headshots + VALUES(headshots)",
        g_Clients[client].playerId, wid, headshot ? 1 : 0);
    Bizzy_DB_Exec(sql);
}

static void EnsureWeapon(const char[] weapon, int client, int damage, bool kill, bool headshot)
{
    char esc[160];
    Bizzy_DB_Escape(weapon, esc, sizeof esc);
    char sql[256];
    FormatEx(sql, sizeof sql,
        "INSERT IGNORE INTO weapons (code, game_id) VALUES ('%s', %d)",
        esc, view_as<int>(g_Game));

    DataPack dp = new DataPack();
    dp.WriteCell(GetClientUserId(client));
    dp.WriteString(weapon);
    dp.WriteCell(damage);
    dp.WriteCell(kill ? 1 : 0);
    dp.WriteCell(headshot ? 1 : 0);
    g_DB.Query(OnWeaponInserted, sql, dp);
}

static void OnWeaponInserted(Database db, DBResultSet rs, const char[] error, DataPack dp)
{
    dp.Reset();
    int uid    = dp.ReadCell();
    char weapon[64]; dp.ReadString(weapon, sizeof weapon);
    int damage = dp.ReadCell();
    bool kill  = dp.ReadCell() != 0;
    bool hs    = dp.ReadCell() != 0;
    delete dp;

    // Lookup the (possibly just-inserted) id and cache it.
    char esc[160];
    Bizzy_DB_Escape(weapon, esc, sizeof esc);
    char sql[256];
    FormatEx(sql, sizeof sql, "SELECT id FROM weapons WHERE code='%s'", esc);

    DataPack d2 = new DataPack();
    d2.WriteCell(uid);
    d2.WriteString(weapon);
    d2.WriteCell(damage);
    d2.WriteCell(kill ? 1 : 0);
    d2.WriteCell(hs ? 1 : 0);
    g_DB.Query(OnWeaponLookedUp, sql, d2);
}

static void OnWeaponLookedUp(Database db, DBResultSet rs, const char[] error, DataPack dp)
{
    dp.Reset();
    int uid    = dp.ReadCell();
    char weapon[64]; dp.ReadString(weapon, sizeof weapon);
    int damage = dp.ReadCell();
    bool kill  = dp.ReadCell() != 0;
    bool hs    = dp.ReadCell() != 0;
    delete dp;

    if (rs == null || !rs.FetchRow()) return;
    int wid = rs.FetchInt(0);
    g_WeaponIds.SetValue(weapon, wid);

    int client = GetClientOfUserId(uid);
    if (client == 0) return;

    // Replay the original event now that we have the ID cached.
    if (kill) Bizzy_Weapons_RecordKill(client, weapon, hs);
    else      Bizzy_Weapons_RecordHit(client, weapon, damage);
}
