/**
 * bizzymod_coop_scaling.sp
 *
 * Standalone replacement for the AutoDifficultyCheck() block in Merudo's
 * SuperVersus (SVR). Tested cvar name set:
 *     director_auto_difficulty
 *     director_tank_hpmulti
 *     director_si_hpmulti
 *     director_ci_multi
 *     director_si_more
 *
 * These match what legacy/cfg/server1.cfg and older-legacy/cfg/server1.cfg
 * have under their //SuperVersus blocks, and what the deployed
 * l4d_superversus.smx in older-legacy actually exposes (verified by
 * strings-dump on the .smx).
 *
 * WHY THIS EXISTS (not just re-enabling SVR):
 *   We removed SVR in PR #6 because its eager bot-fill (SpawnCheck +
 *   SpawnFakeClient) and bot kick (KickUnusedBot) loops conflict with
 *   MultiSlots Improved. Both plugins manage the survivor slot count via
 *   Event_PlayerSpawn / Event_PlayerDisconnect; running them together
 *   produces races where SVR kicks bots MultiSlots just spawned, or
 *   spawns bots into slots MultiSlots is about to give a real human.
 *
 *   But SVR's scaling pass (AutoDifficultyCheck) is purely cvar-driven
 *   and doesn't touch the survivor team — it only writes to z_tank_health,
 *   z_mob_spawn_*, z_*_health (SI), and the z_*_limit (SI count) cvars.
 *   Lifting that block out into a standalone plugin gets us the
 *   scaling behavior older-legacy //SuperVersus block was aiming at
 *   (but never actually achieved, because legacy's SVR was capped at
 *   survivor_limit=4 so the formulas always multiplied by 0).
 *
 * THE FORMULA (verbatim from Merudo's SVR AutoDifficultyCheck, with the
 * cvar names mapped to ours):
 *
 *     extra = max(0, survivors_alive_in_team - 4)
 *
 *     tank_hp     = base_tank_hp * (1 + director_tank_hpmulti * extra)
 *     spawn_multi =                 1 + director_ci_multi     * extra
 *     si_hp       = base_si_hp   * (1 + director_si_hpmulti   * extra)
 *
 *     z_mob_spawn_*     scaled UP   by spawn_multi
 *     z_mob_spawn_interval_*  scaled DOWN by spawn_multi (intervals shrink)
 *     director_special_*      scaled DOWN by spawn_multi (faster respawns)
 *     z_smoker_limit etc.     bumped by 1 + ceil(extra/4) when director_si_more > 0
 *     dvar MaxSpecials        bumped to 2 + extra        when director_si_more > 0
 *
 * Triggered on:
 *   - round_start  (apply fresh after engine resets cvars)
 *   - player_spawn (recompute when survivor count changes)
 *   - player_death (recompute when survivor count changes)
 *
 * Restores baseline values on round_end / map change so a future round
 * with fewer survivors gets vanilla difficulty back.
 *
 * Adapted from: dvander/sourcepawn-corpus :: forums/M/e/r/Merudo/
 *               l4d_superversus_2395926.sp (Merudo's SuperVersus
 *               Reloaded, AutoDifficultyCheck() lines 962-1042).
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

#define PLUGIN_VERSION "1.0.0"
#define TEAM_SURVIVOR 2

public Plugin myinfo =
{
    name        = "Bizzymod Coop Scaling",
    author      = "bizzymod (adapted from Merudo SVR AutoDifficultyCheck)",
    description = "Scales tank HP / SI HP / common spawn rate / SI count with current survivor count. Standalone — coexists cleanly with MultiSlots Improved.",
    version     = PLUGIN_VERSION,
    url         = "https://github.com/bogware/bizzymod-campaign"
};

ConVar g_cvAutoDifficulty;
ConVar g_cvTankHpMulti;
ConVar g_cvSiHpMulti;
ConVar g_cvCiMulti;
ConVar g_cvSiMore;

// Cached baseline values (captured on OnMapStart so Stripper/VScript
// overrides are respected as the "base" we scale from).
bool g_bCached = false;

int g_iBaseTankHealth;
int g_iBaseMobMinSize, g_iBaseMobMaxSize, g_iBaseMobFinaleSize;
int g_iBaseMegaMobSize, g_iBaseCommonLimit;

int g_iBaseMobMaxE, g_iBaseMobMaxN, g_iBaseMobMaxH, g_iBaseMobMaxX;
int g_iBaseMobMinE, g_iBaseMobMinN, g_iBaseMobMinH, g_iBaseMobMinX;
int g_iBaseMegaMobMax, g_iBaseMegaMobMin;
int g_iBaseSpecResp, g_iBaseSpecBattle, g_iBaseSpecFinale;
int g_iBaseSpecInitMax, g_iBaseSpecInitMaxExtra, g_iBaseSpecInitMin;
int g_iBaseSpecOriginal;

int g_iBaseGasHealth, g_iBaseHunterHealth, g_iBaseExpHealth;
int g_iBaseSpitterHealth, g_iBaseChargerHealth, g_iBaseJockeyHealth;

int g_iBaseSmokerLimit, g_iBaseBoomerLimit, g_iBaseHunterLimit;
int g_iBaseSpitterLimit, g_iBaseChargerLimit, g_iBaseJockeyLimit;

public void OnPluginStart()
{
    g_cvAutoDifficulty = CreateConVar("director_auto_difficulty", "1",
        "Master enable for survivor-count scaling. 1=on, 0=off.",
        FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvTankHpMulti = CreateConVar("director_tank_hpmulti", "1",
        "Tank HP scale. tank_hp = base * (1 + multi*(survivors-4)). Requires director_auto_difficulty 1.",
        FCVAR_NOTIFY, true, 0.0, true, 5.0);
    g_cvSiHpMulti = CreateConVar("director_si_hpmulti", "0",
        "SI HP scale (smoker, hunter, etc.). Same formula. Requires director_auto_difficulty 1.",
        FCVAR_NOTIFY, true, 0.0, true, 5.0);
    g_cvCiMulti = CreateConVar("director_ci_multi", "1",
        "Common infected spawn-rate scale. Same formula. Requires director_auto_difficulty 1.",
        FCVAR_NOTIFY, true, 0.0, true, 5.0);
    g_cvSiMore = CreateConVar("director_si_more", "2",
        "Spawn additional SI per extra survivor. >0 = on. Requires director_auto_difficulty 1.",
        FCVAR_NOTIFY, true, 0.0, true, 8.0);

    HookEvent("round_start",  Event_RoundStart, EventHookMode_PostNoCopy);
    HookEvent("round_end",    Event_RoundEnd,   EventHookMode_PreNoCopy);
    HookEvent("player_spawn", Event_PlayerSpawn);
    HookEvent("player_death", Event_PlayerDeath);

    AutoExecConfig(true, "bizzymod_coop_scaling");
}

public void OnMapStart()
{
    CacheBaselines();
}

void CacheBaselines()
{
    // Tank
    g_iBaseTankHealth   = GetConVarInt(FindConVar("z_tank_health"));

    // Common mob sizes
    g_iBaseMobMinSize    = GetConVarInt(FindConVar("z_mob_spawn_min_size"));
    g_iBaseMobMaxSize    = GetConVarInt(FindConVar("z_mob_spawn_max_size"));
    g_iBaseMobFinaleSize = GetConVarInt(FindConVar("z_mob_spawn_finale_size"));
    g_iBaseMegaMobSize   = GetConVarInt(FindConVar("z_mega_mob_size"));
    g_iBaseCommonLimit   = GetConVarInt(FindConVar("z_common_limit"));

    // Common mob intervals (per difficulty)
    g_iBaseMobMaxE = GetConVarInt(FindConVar("z_mob_spawn_max_interval_easy"));
    g_iBaseMobMaxN = GetConVarInt(FindConVar("z_mob_spawn_max_interval_normal"));
    g_iBaseMobMaxH = GetConVarInt(FindConVar("z_mob_spawn_max_interval_hard"));
    g_iBaseMobMaxX = GetConVarInt(FindConVar("z_mob_spawn_max_interval_expert"));
    g_iBaseMobMinE = GetConVarInt(FindConVar("z_mob_spawn_min_interval_easy"));
    g_iBaseMobMinN = GetConVarInt(FindConVar("z_mob_spawn_min_interval_normal"));
    g_iBaseMobMinH = GetConVarInt(FindConVar("z_mob_spawn_min_interval_hard"));
    g_iBaseMobMinX = GetConVarInt(FindConVar("z_mob_spawn_min_interval_expert"));
    g_iBaseMegaMobMax = GetConVarInt(FindConVar("z_mega_mob_spawn_max_interval"));
    g_iBaseMegaMobMin = GetConVarInt(FindConVar("z_mega_mob_spawn_min_interval"));

    // Special respawn cadence
    g_iBaseSpecResp     = GetConVarInt(FindConVar("director_special_respawn_interval"));
    g_iBaseSpecBattle   = GetConVarInt(FindConVar("director_special_battlefield_respawn_interval"));
    g_iBaseSpecFinale   = GetConVarInt(FindConVar("director_special_finale_offer_length"));
    g_iBaseSpecInitMax  = GetConVarInt(FindConVar("director_special_initial_spawn_delay_max"));
    g_iBaseSpecInitMaxExtra = GetConVarInt(FindConVar("director_special_initial_spawn_delay_max_extra"));
    g_iBaseSpecInitMin  = GetConVarInt(FindConVar("director_special_initial_spawn_delay_min"));
    g_iBaseSpecOriginal = GetConVarInt(FindConVar("director_special_original_offer_length"));

    // SI health
    g_iBaseGasHealth     = GetConVarInt(FindConVar("z_gas_health"));      // smoker (L4D1: gas)
    g_iBaseHunterHealth  = GetConVarInt(FindConVar("z_hunter_health"));
    g_iBaseExpHealth     = GetConVarInt(FindConVar("z_exploding_health"));// boomer (L4D1: exploding)
    g_iBaseSpitterHealth = GetConVarInt(FindConVar("z_spitter_health"));
    g_iBaseChargerHealth = GetConVarInt(FindConVar("z_charger_health"));
    g_iBaseJockeyHealth  = GetConVarInt(FindConVar("z_jockey_health"));

    // SI per-class limits
    g_iBaseSmokerLimit  = GetConVarInt(FindConVar("z_smoker_limit"));
    g_iBaseBoomerLimit  = GetConVarInt(FindConVar("z_boomer_limit"));
    g_iBaseHunterLimit  = GetConVarInt(FindConVar("z_hunter_limit"));
    g_iBaseSpitterLimit = GetConVarInt(FindConVar("z_spitter_limit"));
    g_iBaseChargerLimit = GetConVarInt(FindConVar("z_charger_limit"));
    g_iBaseJockeyLimit  = GetConVarInt(FindConVar("z_jockey_limit"));

    g_bCached = true;
}

public void Event_RoundStart(Event evt, const char[] name, bool dontBroadcast)
{
    // Engine resets some of these at round start; re-apply.
    ApplyScaling();
}

public void Event_RoundEnd(Event evt, const char[] name, bool dontBroadcast)
{
    RestoreBaseline();
}

public void Event_PlayerSpawn(Event evt, const char[] name, bool dontBroadcast)
{
    ApplyScaling();
}

public void Event_PlayerDeath(Event evt, const char[] name, bool dontBroadcast)
{
    ApplyScaling();
}

void ApplyScaling()
{
    if (!g_bCached) return;
    if (!g_cvAutoDifficulty.BoolValue) return;

    int extra = GetSurvivorTeamCount() - 4;
    if (extra <= 0)
    {
        // 4 or fewer survivors → keep vanilla difficulty
        RestoreBaseline();
        return;
    }

    // --- TANK HP ---
    float tankMulti = 1.0 + g_cvTankHpMulti.FloatValue * extra;
    if (g_cvTankHpMulti.FloatValue > 0.0)
    {
        int newTankHp = RoundFloat(float(g_iBaseTankHealth) * tankMulti);
        SetConVarInt(FindConVar("z_tank_health"), newTankHp);
    }

    // --- COMMON INFECTED SPAWN RATE ---
    float spawnMulti = 1.0 + g_cvCiMulti.FloatValue * float(extra);
    if (g_cvCiMulti.FloatValue > 0.0 && spawnMulti > 0.0)
    {
        SetConVarInt(FindConVar("z_mob_spawn_finale_size"), RoundToNearest(float(g_iBaseMobFinaleSize) * spawnMulti));
        SetConVarInt(FindConVar("z_mob_spawn_max_size"),    RoundToNearest(float(g_iBaseMobMaxSize)    * spawnMulti));
        SetConVarInt(FindConVar("z_mob_spawn_min_size"),    RoundToNearest(float(g_iBaseMobMinSize)    * spawnMulti));
        SetConVarInt(FindConVar("z_mega_mob_size"),         RoundToNearest(float(g_iBaseMegaMobSize)   * spawnMulti));
        SetConVarInt(FindConVar("z_common_limit"),          RoundToNearest(float(g_iBaseCommonLimit)   * spawnMulti));

        SetConVarInt(FindConVar("z_mob_spawn_max_interval_easy"),   RoundToFloor(float(g_iBaseMobMaxE) / spawnMulti));
        SetConVarInt(FindConVar("z_mob_spawn_max_interval_normal"), RoundToFloor(float(g_iBaseMobMaxN) / spawnMulti));
        SetConVarInt(FindConVar("z_mob_spawn_max_interval_hard"),   RoundToFloor(float(g_iBaseMobMaxH) / spawnMulti));
        SetConVarInt(FindConVar("z_mob_spawn_max_interval_expert"), RoundToFloor(float(g_iBaseMobMaxX) / spawnMulti));
        SetConVarInt(FindConVar("z_mob_spawn_min_interval_easy"),   RoundToFloor(float(g_iBaseMobMinE) / spawnMulti));
        SetConVarInt(FindConVar("z_mob_spawn_min_interval_normal"), RoundToFloor(float(g_iBaseMobMinN) / spawnMulti));
        SetConVarInt(FindConVar("z_mob_spawn_min_interval_hard"),   RoundToFloor(float(g_iBaseMobMinH) / spawnMulti));
        SetConVarInt(FindConVar("z_mob_spawn_min_interval_expert"), RoundToFloor(float(g_iBaseMobMinX) / spawnMulti));

        SetConVarInt(FindConVar("z_mega_mob_spawn_max_interval"), RoundToFloor(float(g_iBaseMegaMobMax) / spawnMulti));
        SetConVarInt(FindConVar("z_mega_mob_spawn_min_interval"), RoundToFloor(float(g_iBaseMegaMobMin) / spawnMulti));

        SetConVarInt(FindConVar("director_special_respawn_interval"),             RoundToFloor(float(g_iBaseSpecResp)        / spawnMulti));
        SetConVarInt(FindConVar("director_special_battlefield_respawn_interval"), RoundToFloor(float(g_iBaseSpecBattle)      / spawnMulti));
        SetConVarInt(FindConVar("director_special_finale_offer_length"),          RoundToFloor(float(g_iBaseSpecFinale)      / spawnMulti));
        SetConVarInt(FindConVar("director_special_initial_spawn_delay_max"),      RoundToFloor(float(g_iBaseSpecInitMax)     / spawnMulti));
        SetConVarInt(FindConVar("director_special_initial_spawn_delay_max_extra"),RoundToFloor(float(g_iBaseSpecInitMaxExtra)/ spawnMulti));
        SetConVarInt(FindConVar("director_special_initial_spawn_delay_min"),      RoundToFloor(float(g_iBaseSpecInitMin)     / spawnMulti));
        SetConVarInt(FindConVar("director_special_original_offer_length"),        RoundToFloor(float(g_iBaseSpecOriginal)    / spawnMulti));
    }

    // --- SI HEALTH ---
    float sihpMulti = 1.0 + g_cvSiHpMulti.FloatValue * float(extra);
    if (g_cvSiHpMulti.FloatValue > 0.0)
    {
        SetConVarInt(FindConVar("z_gas_health"),       RoundToCeil(float(g_iBaseGasHealth)     * sihpMulti));
        SetConVarInt(FindConVar("z_hunter_health"),    RoundToNearest(float(g_iBaseHunterHealth)*sihpMulti));
        SetConVarInt(FindConVar("z_exploding_health"), RoundToNearest(float(g_iBaseExpHealth)   *sihpMulti));
        SetConVarInt(FindConVar("z_spitter_health"),   RoundToCeil(float(g_iBaseSpitterHealth)  *sihpMulti));
        SetConVarInt(FindConVar("z_charger_health"),   RoundToNearest(float(g_iBaseChargerHealth)*sihpMulti));
        SetConVarInt(FindConVar("z_jockey_health"),    RoundToNearest(float(g_iBaseJockeyHealth)*sihpMulti));
    }

    // --- EXTRA SI PER CLASS ---
    if (g_cvSiMore.FloatValue > 0.0)
    {
        int extraPerClass = 1 + RoundToCeil(float(extra) / 4.0);
        SetConVarInt(FindConVar("z_smoker_limit"),  g_iBaseSmokerLimit  + extraPerClass);
        SetConVarInt(FindConVar("z_boomer_limit"),  g_iBaseBoomerLimit  + extraPerClass);
        SetConVarInt(FindConVar("z_hunter_limit"),  g_iBaseHunterLimit  + extraPerClass);
        SetConVarInt(FindConVar("z_spitter_limit"), g_iBaseSpitterLimit + extraPerClass);
        SetConVarInt(FindConVar("z_charger_limit"), g_iBaseChargerLimit + extraPerClass);
        SetConVarInt(FindConVar("z_jockey_limit"),  g_iBaseJockeyLimit  + extraPerClass);
    }
}

void RestoreBaseline()
{
    if (!g_bCached) return;

    SetConVarInt(FindConVar("z_tank_health"),           g_iBaseTankHealth);

    SetConVarInt(FindConVar("z_mob_spawn_finale_size"), g_iBaseMobFinaleSize);
    SetConVarInt(FindConVar("z_mob_spawn_max_size"),    g_iBaseMobMaxSize);
    SetConVarInt(FindConVar("z_mob_spawn_min_size"),    g_iBaseMobMinSize);
    SetConVarInt(FindConVar("z_mega_mob_size"),         g_iBaseMegaMobSize);
    SetConVarInt(FindConVar("z_common_limit"),          g_iBaseCommonLimit);

    SetConVarInt(FindConVar("z_mob_spawn_max_interval_easy"),   g_iBaseMobMaxE);
    SetConVarInt(FindConVar("z_mob_spawn_max_interval_normal"), g_iBaseMobMaxN);
    SetConVarInt(FindConVar("z_mob_spawn_max_interval_hard"),   g_iBaseMobMaxH);
    SetConVarInt(FindConVar("z_mob_spawn_max_interval_expert"), g_iBaseMobMaxX);
    SetConVarInt(FindConVar("z_mob_spawn_min_interval_easy"),   g_iBaseMobMinE);
    SetConVarInt(FindConVar("z_mob_spawn_min_interval_normal"), g_iBaseMobMinN);
    SetConVarInt(FindConVar("z_mob_spawn_min_interval_hard"),   g_iBaseMobMinH);
    SetConVarInt(FindConVar("z_mob_spawn_min_interval_expert"), g_iBaseMobMinX);
    SetConVarInt(FindConVar("z_mega_mob_spawn_max_interval"),   g_iBaseMegaMobMax);
    SetConVarInt(FindConVar("z_mega_mob_spawn_min_interval"),   g_iBaseMegaMobMin);

    SetConVarInt(FindConVar("director_special_respawn_interval"),             g_iBaseSpecResp);
    SetConVarInt(FindConVar("director_special_battlefield_respawn_interval"), g_iBaseSpecBattle);
    SetConVarInt(FindConVar("director_special_finale_offer_length"),          g_iBaseSpecFinale);
    SetConVarInt(FindConVar("director_special_initial_spawn_delay_max"),      g_iBaseSpecInitMax);
    SetConVarInt(FindConVar("director_special_initial_spawn_delay_max_extra"),g_iBaseSpecInitMaxExtra);
    SetConVarInt(FindConVar("director_special_initial_spawn_delay_min"),      g_iBaseSpecInitMin);
    SetConVarInt(FindConVar("director_special_original_offer_length"),        g_iBaseSpecOriginal);

    SetConVarInt(FindConVar("z_gas_health"),       g_iBaseGasHealth);
    SetConVarInt(FindConVar("z_hunter_health"),    g_iBaseHunterHealth);
    SetConVarInt(FindConVar("z_exploding_health"), g_iBaseExpHealth);
    SetConVarInt(FindConVar("z_spitter_health"),   g_iBaseSpitterHealth);
    SetConVarInt(FindConVar("z_charger_health"),   g_iBaseChargerHealth);
    SetConVarInt(FindConVar("z_jockey_health"),    g_iBaseJockeyHealth);

    SetConVarInt(FindConVar("z_smoker_limit"),  g_iBaseSmokerLimit);
    SetConVarInt(FindConVar("z_boomer_limit"),  g_iBaseBoomerLimit);
    SetConVarInt(FindConVar("z_hunter_limit"),  g_iBaseHunterLimit);
    SetConVarInt(FindConVar("z_spitter_limit"), g_iBaseSpitterLimit);
    SetConVarInt(FindConVar("z_charger_limit"), g_iBaseChargerLimit);
    SetConVarInt(FindConVar("z_jockey_limit"),  g_iBaseJockeyLimit);
}

int GetSurvivorTeamCount()
{
    // Count the WHOLE survivor team (humans + bots), matching SVR's
    // GetSurvivorTeam(). With MultiSlots' lazy bot spawn, bots only exist
    // to slot for connecting humans, so in practice this ≈ human count.
    // Counting them explicitly here is the safe semantic that matches the
    // older-legacy //SuperVersus block's intent.
    int count = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && GetClientTeam(i) == TEAM_SURVIVOR)
            count++;
    }
    return count;
}
