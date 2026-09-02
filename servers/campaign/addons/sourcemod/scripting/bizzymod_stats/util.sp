/**
 * util.sp — small helpers used by other modules. Keep this file pure: no
 * global state writes, no ConVar reads, no DB access.
 */

#if defined _bizzy_util_included
    #endinput
#endif
#define _bizzy_util_included

stock void Bizzy_ResetClientState(int client)
{
    g_Clients[client].inUse              = false;
    g_Clients[client].playerId           = 0;
    g_Clients[client].sessionId          = 0;
    g_Clients[client].steamid[0]         = '\0';
    g_Clients[client].name[0]            = '\0';
    g_Clients[client].team               = TEAM_UNDEFINED;
    g_Clients[client].siType             = SI_None;
    g_Clients[client].pointsThisSession  = 0;
    g_Clients[client].shotsFired         = 0;
    g_Clients[client].shotsHit           = 0;
    g_Clients[client].headshots          = 0;
    g_Clients[client].damageDealt        = 0;
    g_Clients[client].damageTaken        = 0;
    g_Clients[client].damageFriendly     = 0;
    g_Clients[client].kills              = 0;
    g_Clients[client].incaps             = 0;
    g_Clients[client].deaths             = 0;
    g_Clients[client].sessionStartTime   = 0;
    g_Clients[client].spawnStartTime     = 0;
    g_Clients[client].lastDamageTime     = 0;
    g_Clients[client].lastDamageVictim   = 0;
    g_Clients[client].muted              = false;

    g_Clients[client].pipeBombsThrown   = 0;
    g_Clients[client].pipeBombsKills    = 0;
    g_Clients[client].molotovsThrown    = 0;
    g_Clients[client].molotovsKills     = 0;
    g_Clients[client].molotovBurnDamage = 0;
    g_Clients[client].bileBombsThrown   = 0;
    g_Clients[client].bileBombsHits     = 0;
    g_Clients[client].damageToTank      = 0;
    g_Clients[client].damageToWitch     = 0;
    g_Clients[client].damageToSpecial   = 0;
    g_Clients[client].timeAliveS        = 0;
    g_Clients[client].timeDeadS         = 0;
    g_Clients[client].timeIncappedS     = 0;
    g_Clients[client].pinnedBySmoker    = 0;
    g_Clients[client].pinnedByHunter    = 0;
    g_Clients[client].pinnedByJockey    = 0;
    g_Clients[client].pinnedByCharger   = 0;
    g_Clients[client].vomitedOn         = 0;
    g_Clients[client].selfEscapes       = 0;
    g_Clients[client].distanceUnits     = 0;
    g_Clients[client].killStreak        = 0;
    g_Clients[client].killStreakMax     = 0;
    g_Clients[client].aliveSinceEpoch   = 0;
    g_Clients[client].incapSinceEpoch   = 0;
    g_Clients[client].biggestPounceDamage = 0;
    g_Clients[client].biggestTankPunch  = 0;
    g_Clients[client].longestJockeyRideS = 0;

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

    g_Clients[client].hpAtSaferoomSum = 0;     g_Clients[client].hpAtSaferoomCount = 0;
    g_Clients[client].hpAtPillsSum = 0;        g_Clients[client].hpAtPillsCount = 0;
    g_Clients[client].hpAtAdrenSum = 0;        g_Clients[client].hpAtAdrenCount = 0;
    g_Clients[client].hpAtMedkitSum = 0;       g_Clients[client].hpAtMedkitCount = 0;
    g_Clients[client].bwEntries = 0;
    g_Clients[client].bwTimeS = 0;
    g_Clients[client].bwEnteredEpoch = 0;
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
    g_Clients[client].mostRevivesThisSession = 0;
    g_Clients[client].mostHealsThisSession = 0;
    g_Clients[client].lowestHpSurvival = 100;

    g_Clients[client].timeAloneS = 0;
    g_Clients[client].timeLeadingS = 0;
    g_Clients[client].timeTrailingS = 0;
    g_Clients[client].breaksFromGroup = 0;
    g_Clients[client].fallDamageTaken = 0;
    g_Clients[client].maxTeamSpreadUnits = 0;
    g_Clients[client].avgTeamSpreadSum = 0;
    g_Clients[client].avgTeamSpreadCount = 0;
    g_Clients[client].samplerLastX = 0;
    g_Clients[client].samplerLastY = 0;
    g_Clients[client].samplerLastZ = 0;
    g_Clients[client].samplerWasAlone = false;
    g_Clients[client].samplerSpawnEpoch = 0;

    g_Clients[client].reviveChainsStarted = 0;
    g_Clients[client].reviveChainsPartOf = 0;
    g_Clients[client].saveOfSaves = 0;
    g_Clients[client].lastSavedTeammate = 0;
    g_Clients[client].lastSavedEpoch = 0;

    g_Clients[client].firstBloods = 0;
    g_Clients[client].firstDowns = 0;
    g_Clients[client].saferoomDoorCloses = 0;
    g_Clients[client].lastInSafe = 0;
    g_Clients[client].crescendosCleared = 0;
    g_Clients[client].crescendosWiped = 0;
    g_Clients[client].finaleWavesCleared = 0;
    g_Clients[client].tankKillParticipations = 0;
    g_Clients[client].tankSoloKills = 0;
    g_Clients[client].untouchableMapRunning = 1;

    g_Clients[client].siAbilityStartX = 0;
    g_Clients[client].siAbilityStartY = 0;
    g_Clients[client].siAbilityStartZ = 0;
    g_Clients[client].siAbilityStartMs = 0;
    g_Clients[client].siAbilityKind = 0;
    g_Clients[client].smokerVictimUid = 0;
    g_Clients[client].smokerGrabX = 0;
    g_Clients[client].smokerGrabY = 0;
    g_Clients[client].saferoomOrdinal = 0;
    g_Clients[client].activeWeaponTier = 0;
}

stock bool Bizzy_IsValidPlayer(int client)
{
    return client > 0 && client <= MaxClients
        && IsClientInGame(client) && !IsFakeClient(client);
}

stock int Bizzy_TeamOf(int client)
{
    if (!Bizzy_IsValidPlayer(client)) return TEAM_UNDEFINED;
    return GetClientTeam(client);
}

stock int Bizzy_ZombieClass(int client)
{
    if (!Bizzy_IsValidPlayer(client) || GetClientTeam(client) != TEAM_INFECTED)
        return SI_None;
    return GetEntProp(client, Prop_Send, "m_zombieClass");
}

/**
 * Map a raw zombie-class int (which differs L4D1 vs L4D2 for witch/tank)
 * to our canonical SpecialInfected ID. The DB seeds use the canonical IDs.
 */
stock SpecialInfected Bizzy_NormalizeZombieClass(int zc)
{
    if (g_Game == Game_L4D1)
    {
        if (zc == ZC_WITCH_L4D1) return SI_Witch;
        if (zc == ZC_TANK_L4D1)  return SI_Tank;
    }
    if (zc >= 1 && zc <= 8)
        return view_as<SpecialInfected>(zc);
    return SI_None;
}

stock void Bizzy_DetectGameMode()
{
    char buf[32];
    ConVar mp = FindConVar("mp_gamemode");
    if (mp != null)
    {
        mp.GetString(buf, sizeof buf);
        if (StrEqual(buf, "coop") || StrEqual(buf, ""))
            g_CurrentMode = GameMode_Coop;
        else if (StrEqual(buf, "versus") || StrEqual(buf, "teamversus"))
            g_CurrentMode = GameMode_Versus;
        else if (StrEqual(buf, "realism"))
            g_CurrentMode = GameMode_Realism;
        else if (StrEqual(buf, "survival"))
            g_CurrentMode = GameMode_Survival;
        else if (StrEqual(buf, "scavenge") || StrEqual(buf, "teamscavenge"))
            g_CurrentMode = GameMode_Scavenge;
        else if (StrEqual(buf, "realismversus"))
            g_CurrentMode = GameMode_RealismVersus;
        else if (StrEqual(buf, "mutation01")
              || StrContains(buf, "mutation", false) == 0)
            g_CurrentMode = GameMode_Mutation;
        else
            g_CurrentMode = GameMode_Coop; // safe default
    }

    // L4D internally uses a string difficulty CVar — parse it.
    ConVar zd = FindConVar("z_difficulty");
    if (zd != null)
    {
        char dstr[16];
        zd.GetString(dstr, sizeof dstr);
        if (StrEqual(dstr, "Easy", false))         g_CurrentDifficulty = Difficulty_Easy;
        else if (StrEqual(dstr, "Normal", false))  g_CurrentDifficulty = Difficulty_Normal;
        else if (StrEqual(dstr, "Hard", false))    g_CurrentDifficulty = Difficulty_Hard;
        else if (StrEqual(dstr, "Impossible", false))
                                                   g_CurrentDifficulty = Difficulty_Expert;
        else                                       g_CurrentDifficulty = Difficulty_Normal;
    }
}

stock int Bizzy_NowEpoch()
{
    return GetTime();
}

stock float Bizzy_DifficultyMultiplier()
{
    switch (g_CurrentDifficulty)
    {
        case Difficulty_Easy:   return 0.5;
        case Difficulty_Hard:   return 2.0;
        case Difficulty_Expert: return 4.0;
        default:                return 1.0;
    }
}

stock void Bizzy_DateTime(char[] out, int len)
{
    FormatTime(out, len, "%Y-%m-%d %H:%M:%S", GetTime());
}

stock void Bizzy_GetSteamId(int client, char[] out, int len)
{
    if (!GetClientAuthId(client, AuthId_Steam2, out, len, true))
    {
        // Fall back to IP for LAN
        GetClientIP(client, out, len);
    }
}
