/**
 * bizzymod-stats — shared definitions for the multi-file plugin.
 *
 * This file is included by every module under the bizzymod_stats subdir. It declares the
 * public symbols (constants, enums, the global state struct) that modules
 * use to coordinate.
 */

#if defined _bizzymod_stats_included
    #endinput
#endif
#define _bizzymod_stats_included

#define BIZZY_PLUGIN_NAME    "bizzymod-stats"
#define BIZZY_PLUGIN_VERSION "0.6.0"
#define BIZZY_PLUGIN_URL     "https://github.com/bogware/bizzymod-stats"

#define BIZZY_DB_CONFIG_NAME "bizzymod_stats"

// -----------------------------------------------------------------------------
// Game / mode catalogs. IDs match the seeded values in schema migration 004.
// -----------------------------------------------------------------------------

enum Game
{
    Game_Unknown = 0,
    Game_L4D1    = 1,
    Game_L4D2    = 2,
};

enum GameMode
{
    GameMode_Unknown       = -1,
    GameMode_Coop          = 0,
    GameMode_Versus        = 1,
    GameMode_Realism       = 2,
    GameMode_Survival      = 3,
    GameMode_Scavenge      = 4,
    GameMode_RealismVersus = 5,
    GameMode_Mutation      = 6,
    GameMode_Holdout       = 7,
    GameMode_TankRun       = 8,
};

enum Difficulty
{
    Difficulty_Unknown = 0,
    Difficulty_Easy    = 1,
    Difficulty_Normal  = 2,
    Difficulty_Hard    = 3,
    Difficulty_Expert  = 4,
};

enum SpecialInfected
{
    SI_None    = 0,
    SI_Smoker  = 1,
    SI_Boomer  = 2,
    SI_Hunter  = 3,
    SI_Spitter = 4,  // L4D2
    SI_Jockey  = 5,  // L4D2
    SI_Charger = 6,  // L4D2
    SI_Witch   = 7,
    SI_Tank    = 8,
};

#define ZC_SMOKER  1
#define ZC_BOOMER  2
#define ZC_HUNTER  3
#define ZC_SPITTER 4
#define ZC_JOCKEY  5
#define ZC_CHARGER 6
#define ZC_WITCH_L4D1 4
#define ZC_TANK_L4D1  5
#define ZC_WITCH_L4D2 7
#define ZC_TANK_L4D2  8

#define TEAM_UNDEFINED  0
#define TEAM_SPECTATORS 1
#define TEAM_SURVIVORS  2
#define TEAM_INFECTED   3

// -----------------------------------------------------------------------------
// Per-client state. Indexed by client (1..MaxClients). Lives in main.sp.
// -----------------------------------------------------------------------------

enum struct ClientState
{
    bool   inUse;
    int    playerId;            // DB players.id (0 = not yet resolved)
    int    sessionId;           // DB sessions.id of the active session
    char   steamid[32];
    char   name[64];
    int    team;
    int    siType;              // SpecialInfected (active spawn)
    int    pointsThisSession;
    int    shotsFired;
    int    shotsHit;
    int    headshots;
    int    damageDealt;
    int    damageTaken;
    int    damageFriendly;
    int    kills;
    int    incaps;
    int    deaths;
    int    sessionStartTime;
    int    spawnStartTime;      // when this SI spawn started, for SI playtime
    int    lastDamageTime;      // for friendly-fire cooldown
    int    lastDamageVictim;
    bool   muted;               // user opt-out via sm_rankmute

    // --- 007: extended stats ---
    int    pipeBombsThrown;
    int    pipeBombsKills;
    int    molotovsThrown;
    int    molotovsKills;
    int    molotovBurnDamage;
    int    bileBombsThrown;
    int    bileBombsHits;
    int    damageToTank;
    int    damageToWitch;
    int    damageToSpecial;
    int    timeAliveS;
    int    timeDeadS;
    int    timeIncappedS;
    int    pinnedBySmoker;
    int    pinnedByHunter;
    int    pinnedByJockey;
    int    pinnedByCharger;
    int    vomitedOn;
    int    selfEscapes;
    int    distanceUnits;
    int    killStreak;          // current run of kills without death
    int    killStreakMax;       // session-best streak
    int    aliveSinceEpoch;     // when alive started; 0 = currently dead
    int    incapSinceEpoch;     // when incap started; 0 = not currently incapped
    int    biggestPounceDamage;
    int    biggestTankPunch;
    int    longestJockeyRideS;

    // --- 008: combat granularity ---
    int    dmgHitHead;
    int    dmgHitChest;
    int    dmgHitStomach;
    int    dmgHitLimb;
    int    dmgHitOther;
    int    damageTakenBW;
    int    damageEnvironment;
    int    damageSelf;
    int    fallDeaths;
    int    ffKillsCaused;
    int    reloads;
    int    multikill2;
    int    multikill3;
    int    multikill4;
    int    multikill5plus;
    int    killAssistsSpecial;
    int    killAssistsTank;
    int    killAssistsWitch;
    int    peakDpsThisSession;
    int    dpsWindowStartMs;
    int    dpsWindowDamage;
    int    longestKillUnits;
    int    biggestSingleHit;
    int    biggestMultikill;

    // --- 010: health & inventory ---
    int    hpAtSaferoomSum;
    int    hpAtSaferoomCount;
    int    hpAtPillsSum;
    int    hpAtPillsCount;
    int    hpAtAdrenSum;
    int    hpAtAdrenCount;
    int    hpAtMedkitSum;
    int    hpAtMedkitCount;
    int    bwEntries;
    int    bwTimeS;
    int    bwEnteredEpoch;       // 0 = not currently BW
    int    pillsHoarded;
    int    adrenalineHoarded;
    int    medkitsHoarded;
    int    throwablesHoarded;
    int    defibsHoarded;
    int    defibTargetPointsSum;
    int    weaponT1TimeS;
    int    weaponT2TimeS;
    int    weaponMeleeTimeS;
    int    weaponSniperTimeS;
    int    mostRevivesThisSession;
    int    mostHealsThisSession;
    int    lowestHpSurvival;     // lowest HP reached without dying

    // --- 011: movement & positioning ---
    int    timeAloneS;
    int    timeLeadingS;
    int    timeTrailingS;
    int    breaksFromGroup;
    int    fallDamageTaken;
    int    maxTeamSpreadUnits;
    int    avgTeamSpreadSum;
    int    avgTeamSpreadCount;
    int    samplerLastX;         // last sampled position; ints to keep struct flat
    int    samplerLastY;
    int    samplerLastZ;
    bool   samplerWasAlone;
    int    samplerSpawnEpoch;    // when sampler started for this client

    // --- 012: coordination ---
    int    reviveChainsStarted;
    int    reviveChainsPartOf;
    int    saveOfSaves;
    int    lastSavedTeammate;    // for save-of-save chain
    int    lastSavedEpoch;

    // --- 013: round-shaping ---
    int    firstBloods;
    int    firstDowns;
    int    saferoomDoorCloses;
    int    lastInSafe;
    int    crescendosCleared;
    int    crescendosWiped;
    int    finaleWavesCleared;
    int    tankKillParticipations;
    int    tankSoloKills;
    int    untouchableMapRunning; // bool 0/1: still no damage this map

    // --- extension-point captures ---
    // SI flight/drag tracking: snapshot positions at ability_use, compute
    // delta at terminal event (pounce land, tongue release).
    int    siAbilityStartX;
    int    siAbilityStartY;
    int    siAbilityStartZ;
    int    siAbilityStartMs;
    int    siAbilityKind;        // 1=hunter_lunge, 2=smoker_tongue, 3=charger_charge
    // Active drag target (smoker side)
    int    smokerVictimUid;
    int    smokerGrabX;
    int    smokerGrabY;
    // Saferoom arrival ordinal — set by entered_checkpoint, reset on map start
    int    saferoomOrdinal;
    // Weapon-tier sampling — last seen tier (movement sampler infers seconds held)
    int    activeWeaponTier;     // 0=none, 1=t1, 2=t2, 3=melee, 4=sniper
}

// -----------------------------------------------------------------------------
// Module entry points. Defined in each sub-.sp; called by bizzymod_stats.sp.
// All compiled into one translation unit via #include — no `forward` needed.
// -----------------------------------------------------------------------------

// Documentary list (definitions live in the corresponding modules):
//   Bizzy_OnConfigInit, Bizzy_OnDatabaseInit, Bizzy_OnEventsInit,
//   Bizzy_OnCommandsInit, Bizzy_OnAwardsInit, Bizzy_OnRankvoteInit,
//   Bizzy_OnTimedMapsInit, Bizzy_OnMotdInit, Bizzy_OnSessionInit,
//   Bizzy_OnVersusInit
