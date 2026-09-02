/**
 * config.sp — ConVar registration. Modules read cached globals from
 * bizzymod_stats.sp; new tunables should be registered here and exposed via
 * a global g_cv* in the main file.
 *
 * Convention: prefix is `bizzymod_stats_` for new vars. Legacy `bizzymod_stats_*`
 * names are kept as bound duplicates only where existing server configs
 * are likely to reference them (registered in the alias block below).
 */

void Bizzy_OnConfigInit()
{
    CreateConVar("bizzymod_stats_version", BIZZY_PLUGIN_VERSION, "bizzymod-stats plugin version",
        FCVAR_NOTIFY | FCVAR_DONTRECORD);

    g_cvEnabled = CreateConVar("bizzymod_stats_enabled", "1",
        "Master switch. 0 disables all stat collection.",
        _, true, 0.0, true, 1.0);

    g_cvAnnounceJoin = CreateConVar("bizzymod_stats_announce_join", "1",
        "Announce joining players' rank and points to the server.",
        _, true, 0.0, true, 1.0);

    g_cvAnnounceRank = CreateConVar("bizzymod_stats_announce_rank", "1",
        "Announce when a player's rank changes.",
        _, true, 0.0, true, 1.0);

    g_cvFFireMode = CreateConVar("bizzymod_stats_ffire_mode", "1",
        "Friendly fire scoring: 0=off, 1=cooldown, 2=damage-based.",
        _, true, 0.0, true, 2.0);

    g_cvFFireMultiplier = CreateConVar("bizzymod_stats_ffire_multiplier", "1.5",
        "Damage-mode multiplier: penalty = damage * multiplier.",
        _, true, 0.0, false, 0.0);

    g_cvFFireCooldown = CreateConVar("bizzymod_stats_ffire_cooldown", "10.0",
        "Seconds between counted FF incidents (cooldown mode).",
        _, true, 0.0, false, 0.0);

    g_cvDifficultyMultiplier = CreateConVar("bizzymod_stats_difficulty_multiplier", "1",
        "Apply difficulty multipliers to scoring (0=off, 1=on).",
        _, true, 0.0, true, 1.0);

    g_cvEnableNegativeScore = CreateConVar("bizzymod_stats_negative_score", "1",
        "Allow point losses (negative scoring events).",
        _, true, 0.0, true, 1.0);

    g_cvLogEvents = CreateConVar("bizzymod_stats_log_events", "0",
        "Write the award_events firehose table for activity feeds.",
        _, true, 0.0, true, 1.0);

    g_cvBotMultiplier = CreateConVar("bizzymod_stats_bot_multiplier", "1.0",
        "Multiplier on bot-related score penalties (0 disables).",
        _, true, 0.0, false, 0.0);
}
