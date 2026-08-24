/**
 * identity.sp — resolve/create rows in `servers`, `players`, `maps`,
 * `weapons`. Caches IDs in memory so the hot path never re-queries.
 *
 * Server identity is bootstrapped via a stable key stored in
 * cfg/sourcemod/bizzymod_stats.server_key. If absent we generate one on first
 * run and write it back.
 */

#define BIZZY_KEYFILE "cfg/sourcemod/bizzymod_stats.server_key"

void Bizzy_Identity_EnsureServer()
{
    LoadOrCreateServerKey();

    char namebuf[128], escName[260], escKey[80];
    ConVar hn = FindConVar("hostname");
    if (hn != null) hn.GetString(namebuf, sizeof namebuf);
    if (namebuf[0] == '\0') strcopy(namebuf, sizeof namebuf, "Unknown Server");
    strcopy(g_ServerName, sizeof g_ServerName, namebuf);

    Bizzy_DB_Escape(g_ServerKey, escKey, sizeof escKey);
    Bizzy_DB_Escape(namebuf, escName, sizeof escName);

    char sql[512];
    FormatEx(sql, sizeof sql,
        "INSERT INTO servers (`key`, name, game_id, last_seen) "
        ... "VALUES ('%s', '%s', %d, NOW()) "
        ... "ON DUPLICATE KEY UPDATE name=VALUES(name), last_seen=NOW()",
        escKey, escName, view_as<int>(g_Game));
    g_DB.Query(OnServerUpserted, sql);
}

static void OnServerUpserted(Database db, DBResultSet rs, const char[] error, any data)
{
    if (error[0] != '\0') { LogError("[bizzymod-stats] server upsert: %s", error); return; }
    char esc[80];
    Bizzy_DB_Escape(g_ServerKey, esc, sizeof esc);
    char sql[256];
    FormatEx(sql, sizeof sql, "SELECT id FROM servers WHERE `key`='%s'", esc);
    g_DB.Query(OnServerLookup, sql);
}

static void OnServerLookup(Database db, DBResultSet rs, const char[] error, any data)
{
    if (rs == null || !rs.FetchRow())
    {
        LogError("[bizzymod-stats] server row missing after upsert");
        return;
    }
    g_ServerId = rs.FetchInt(0);
    LogMessage("[bizzymod-stats] online as server_id=%d (key=%s)", g_ServerId, g_ServerKey);

    // Resolve map_id now in case the DB connected mid-map (server boot
    // with a map already loaded, or plugin hot-reload). OnMapStart only
    // fires on actual transitions, so without this hook g_CurrentMapId
    // would stay 0 until the next map change — and any tank / witch /
    // crescendo / wave insert in the meantime would FK-violate against
    // maps.id. See bogware/bizzymod-stats#5.
    Bizzy_Identity_ResolveMap();

    // Now safe to backfill any sessions for players already connected
    // (covers hot-reload).
    for (int i = 1; i <= MaxClients; i++)
        if (Bizzy_IsValidPlayer(i))
            Bizzy_BeginClientSession(i);
}

// -----------------------------------------------------------------------------
// Server key (file-backed, random-on-first-run)
// -----------------------------------------------------------------------------

static void LoadOrCreateServerKey()
{
    char path[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, path, sizeof path, BIZZY_KEYFILE);

    File f = OpenFile(path, "r");
    if (f != null)
    {
        f.ReadString(g_ServerKey, sizeof g_ServerKey);
        delete f;
        TrimString(g_ServerKey);
        if (strlen(g_ServerKey) >= 16) return;
    }

    // Generate a 32-hex-char random key from /dev/urandom-ish entropy: SM
    // doesn't expose a strong RNG, so we mix GetEngineTime + GetURandomInt
    // (1.11+) where available, else a time-based PRNG.
    static const char hex[] = "0123456789abcdef";
    for (int i = 0; i < 32; i++)
    {
        int r = GetURandomInt() & 0xF;
        g_ServerKey[i] = hex[r];
    }
    g_ServerKey[32] = '\0';

    f = OpenFile(path, "w");
    if (f != null)
    {
        f.WriteString(g_ServerKey, false);
        delete f;
    }
    else
    {
        LogError("[bizzymod-stats] could not persist server key to %s", path);
    }
}

// -----------------------------------------------------------------------------
// Player resolution — cached in g_Clients[].playerId
// -----------------------------------------------------------------------------

stock void Bizzy_Identity_ResolvePlayer(int client)
{
    if (!Bizzy_IsValidPlayer(client) || g_DB == null || g_ServerId == 0)
        return;

    char steamid[32], name[64];
    Bizzy_GetSteamId(client, steamid, sizeof steamid);
    GetClientName(client, name, sizeof name);
    strcopy(g_Clients[client].steamid, sizeof ClientState::steamid, steamid);
    strcopy(g_Clients[client].name,    sizeof ClientState::name,    name);

    char escId[80], escName[160];
    Bizzy_DB_Escape(steamid, escId, sizeof escId);
    Bizzy_DB_Escape(name,    escName, sizeof escName);

    char ip[64], escIp[160];
    GetClientIP(client, ip, sizeof ip);
    Bizzy_DB_Escape(ip, escIp, sizeof escIp);

    char sql[768];
    FormatEx(sql, sizeof sql,
        "INSERT INTO players (steamid, name, last_ip, first_seen, last_seen, last_server_id) "
        ... "VALUES ('%s', '%s', INET6_ATON('%s'), NOW(), NOW(), %d) "
        ... "ON DUPLICATE KEY UPDATE "
        ... "  name=VALUES(name), last_ip=VALUES(last_ip), "
        ... "  last_seen=NOW(), last_server_id=VALUES(last_server_id)",
        escId, escName, escIp, g_ServerId);

    DataPack dp = new DataPack();
    dp.WriteCell(GetClientUserId(client));
    g_DB.Query(OnPlayerUpsert, sql, dp);
}

static void OnPlayerUpsert(Database db, DBResultSet rs, const char[] error, DataPack dp)
{
    dp.Reset();
    int uid = dp.ReadCell();
    delete dp;

    if (error[0] != '\0') { LogError("[bizzymod-stats] player upsert: %s", error); return; }
    int client = GetClientOfUserId(uid);
    if (client == 0 || !Bizzy_IsValidPlayer(client)) return;

    char escId[80];
    Bizzy_DB_Escape(g_Clients[client].steamid, escId, sizeof escId);
    char sql[256];
    FormatEx(sql, sizeof sql, "SELECT id FROM players WHERE steamid='%s'", escId);

    DataPack d2 = new DataPack();
    d2.WriteCell(uid);
    g_DB.Query(OnPlayerLookup, sql, d2);
}

static void OnPlayerLookup(Database db, DBResultSet rs, const char[] error, DataPack dp)
{
    dp.Reset();
    int uid = dp.ReadCell();
    delete dp;

    if (rs == null || !rs.FetchRow()) return;
    int client = GetClientOfUserId(uid);
    if (client == 0) return;
    g_Clients[client].playerId = rs.FetchInt(0);

    // Now that we have a player_id, hand off to the session module.
    Bizzy_Session_Open(client);
}

// -----------------------------------------------------------------------------
// Maps — resolve current map name to maps.id, creating on first sight.
// -----------------------------------------------------------------------------

stock void Bizzy_Identity_ResolveMap()
{
    if (g_DB == null) return;
    // Refresh from the engine every call. OnMapStart sets g_CurrentMap on
    // every map change, but if this is called from the DB-ready callback
    // (handling hot reload / late connect) OnMapStart may not have fired
    // yet on this plugin instance — in which case g_CurrentMap is empty
    // and we'd no-op. Reading from GetCurrentMap directly is safe and
    // idempotent. See bogware/bizzymod-stats#5.
    GetCurrentMap(g_CurrentMap, sizeof g_CurrentMap);
    if (g_CurrentMap[0] == '\0') return;
    char esc[260];
    Bizzy_DB_Escape(g_CurrentMap, esc, sizeof esc);
    char sql[512];
    FormatEx(sql, sizeof sql,
        "INSERT INTO maps (code, game_id, first_seen) VALUES ('%s', %d, NOW()) "
        ... "ON DUPLICATE KEY UPDATE first_seen=first_seen",
        esc, view_as<int>(g_Game));
    g_DB.Query(OnMapUpsert, sql);
}

static void OnMapUpsert(Database db, DBResultSet rs, const char[] error, any data)
{
    if (error[0] != '\0') { LogError("[bizzymod-stats] map upsert: %s", error); return; }
    char esc[260];
    Bizzy_DB_Escape(g_CurrentMap, esc, sizeof esc);
    char sql[512];
    FormatEx(sql, sizeof sql,
        "SELECT id FROM maps WHERE code='%s' AND game_id=%d",
        esc, view_as<int>(g_Game));
    g_DB.Query(OnMapLookup, sql);
}

static void OnMapLookup(Database db, DBResultSet rs, const char[] error, any data)
{
    if (rs != null && rs.FetchRow())
        g_CurrentMapId = rs.FetchInt(0);
}
