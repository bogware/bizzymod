/**
 * database.sp — async MySQL connection + write queue.
 *
 * Design:
 *   - All writes go through Bizzy_DB_Exec() (single statements) or
 *     Bizzy_DB_BeginTxn() (batched). Both are async — no SQL call ever
 *     blocks the game tick.
 *   - All reads go through Bizzy_DB_Query() with a callback.
 *   - Identifier escaping is done with SQL_EscapeString; never use
 *     Format("%s") to inject untrusted strings.
 *
 * Connection lifecycle:
 *   OnDatabaseInit() -> SQL_TConnect("bizzymod_stats") -> OnDBConnected ->
 *     ensure server row -> OnServerResolved -> emit Bizzy_OnDBReady() to
 *     other modules, which begin their own work (session backfill etc.)
 */

void Bizzy_OnDatabaseInit()
{
    Database.Connect(OnDBConnected, BIZZY_DB_CONFIG_NAME);
}

static void OnDBConnected(Database db, const char[] error, any data)
{
    if (db == null)
    {
        LogError("[bizzymod-stats] DB connect failed: %s", error);
        SetFailState("bizzymod-stats: cannot connect to '%s' database (see databases.cfg)",
            BIZZY_DB_CONFIG_NAME);
        return;
    }
    g_DB = db;
    g_DB.SetCharset("utf8mb4");

    // Resolve/create server row; the rest of the modules don't fire until
    // we have g_ServerId.
    Bizzy_Identity_EnsureServer();
}

stock void Bizzy_DB_Exec(const char[] sql)
{
    if (g_DB == null) return;
    g_DB.Query(OnVoidQuery, sql);
}

static void OnVoidQuery(Database db, DBResultSet rs, const char[] error, any data)
{
    if (error[0] != '\0')
        LogError("[bizzymod-stats] query failed: %s", error);
}

/**
 * Run a SELECT (or any query whose results you care about). Callback runs
 * on the main thread; `rs` is invalid on error.
 */
stock void Bizzy_DB_Query(const char[] sql, SQLQueryCallback cb, any data = 0)
{
    if (g_DB == null)
    {
        LogError("[bizzymod-stats] Bizzy_DB_Query before DB ready: %s", sql);
        return;
    }
    g_DB.Query(cb, sql, data);
}

/**
 * Start a transaction for batched writes. Caller AddQueries() then
 * Bizzy_DB_RunTxn(txn).
 */
stock Transaction Bizzy_DB_BeginTxn()
{
    return new Transaction();
}

stock void Bizzy_DB_RunTxn(Transaction txn, SQLTxnSuccess onok = INVALID_FUNCTION,
                           SQLTxnFailure onfail = INVALID_FUNCTION, any data = 0)
{
    if (g_DB == null) { delete txn; return; }
    if (onok == INVALID_FUNCTION) onok = DefaultTxnSuccess;
    if (onfail == INVALID_FUNCTION) onfail = DefaultTxnFail;
    g_DB.Execute(txn, onok, onfail, data);
}

static void DefaultTxnSuccess(Database db, any data, int numQueries, DBResultSet[] results, any[] qd)
{
    // no-op
}

static void DefaultTxnFail(Database db, any data, int numQueries, const char[] error,
                           int failIndex, any[] qd)
{
    LogError("[bizzymod-stats] transaction failed (q#%d): %s", failIndex, error);
}

/**
 * Escape a string for safe embedding in dynamic SQL. Output buffer must be
 * 2*strlen+1.
 */
stock void Bizzy_DB_Escape(const char[] input, char[] out, int len)
{
    if (g_DB == null) { out[0] = '\0'; return; }
    g_DB.Escape(input, out, len);
}
