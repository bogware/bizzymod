/**
 * scoring.sp — central point-mutation API. All scoring events go through
 * Bizzy_Score() so the negative-score CVAR, difficulty multiplier, and
 * announcement logic live in one place.
 *
 * Sub-modules (events.sp, awards.sp, weapons.sp) call Bizzy_Score() with
 * a *reason code* (matches awards.code in DB when applicable) so the
 * award_events table can be populated for activity feeds.
 */

stock void Bizzy_Score(int client, int rawPoints, const char[] reason = "")
{
    if (!g_cvEnabled.BoolValue) return;
    if (!Bizzy_IsValidPlayer(client)) return;
    if (g_Clients[client].muted) return;

    int points = rawPoints;

    if (g_cvDifficultyMultiplier.BoolValue)
        points = RoundToNearest(float(points) * Bizzy_DifficultyMultiplier());

    if (points < 0 && !g_cvEnableNegativeScore.BoolValue)
        return;

    g_Clients[client].pointsThisSession += points;
    Bizzy_Versus_AccumScore(client, points);

    if (g_cvLogEvents.BoolValue && reason[0] != '\0')
        Bizzy_Awards_LogEvent(client, reason, points);
}

stock void Bizzy_RecordKill(int killer, int victim, bool headshot,
                            const char[] weapon = "")
{
    if (!Bizzy_IsValidPlayer(killer)) return;

    int kteam = GetClientTeam(killer);
    int vteam = (victim > 0 && victim <= MaxClients && IsClientInGame(victim))
                ? GetClientTeam(victim) : 0;

    g_Clients[killer].kills++;
    if (headshot) g_Clients[killer].headshots++;
    Bizzy_Versus_AccumKill(killer, false);

    if (weapon[0] != '\0')
        Bizzy_Weapons_RecordKill(killer, weapon, headshot);

    // Team-context scoring
    if (kteam == TEAM_SURVIVORS && vteam == TEAM_INFECTED)
    {
        // Survivor killed an infected — kill points awarded in events.sp
        // based on victim's zombie class; nothing to do here.
    }
    else if (kteam == TEAM_INFECTED && vteam == TEAM_SURVIVORS)
    {
        ConVar cv = FindConVar("bizzymod_stats_survivor_death");
        int pts = (cv == null) ? 40 : cv.IntValue;
        Bizzy_Score(killer, pts, "survivor_kill");
    }
    else if (kteam == vteam && killer != victim)
    {
        Bizzy_Awards_Fire(killer, "teamkill", 1);
    }
}

stock void Bizzy_RecordDamage(int attacker, int victim, int damage,
                              const char[] weapon = "")
{
    if (!Bizzy_IsValidPlayer(attacker)) return;
    g_Clients[attacker].damageDealt += damage;
    g_Clients[attacker].shotsHit++;

    bool friendly = false;
    if (Bizzy_IsValidPlayer(victim))
    {
        g_Clients[victim].damageTaken += damage;

        int at = GetClientTeam(attacker);
        int vt = GetClientTeam(victim);
        if (at == vt && attacker != victim)
        {
            friendly = true;
            HandleFriendlyFire(attacker, victim, damage);
        }
    }
    Bizzy_Versus_AccumDamage(attacker, victim, damage, friendly);

    if (weapon[0] != '\0')
        Bizzy_Weapons_RecordHit(attacker, weapon, damage);
}

static void HandleFriendlyFire(int attacker, int victim, int damage)
{
    g_Clients[attacker].damageFriendly += damage;

    int mode = g_cvFFireMode.IntValue;
    if (mode == 0) return;

    if (mode == 2)
    {
        // damage-based: penalty = damage * multiplier (then difficulty scaled)
        int penalty = -RoundToNearest(float(damage) * g_cvFFireMultiplier.FloatValue);
        Bizzy_Score(attacker, penalty, "friendly_fire");
        Bizzy_Awards_Fire(attacker, "friendly_fire", 1);
        return;
    }

    // mode 1: cooldown — one penalty per N seconds per victim
    int now = Bizzy_NowEpoch();
    int cooldown = RoundToNearest(g_cvFFireCooldown.FloatValue);
    if (g_Clients[attacker].lastDamageVictim == victim
        && (now - g_Clients[attacker].lastDamageTime) < cooldown)
        return;
    g_Clients[attacker].lastDamageVictim = victim;
    g_Clients[attacker].lastDamageTime   = now;

    ConVar cv = FindConVar("bizzymod_stats_ff_base_penalty");
    int basePenalty = -((cv == null) ? 25 : cv.IntValue);
    Bizzy_Score(attacker, basePenalty, "friendly_fire");
    Bizzy_Awards_Fire(attacker, "friendly_fire", 1);
}
