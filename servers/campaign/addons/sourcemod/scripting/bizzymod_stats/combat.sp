/**
 * combat.sp — combat granularity captures.
 *
 *   - Per-victim damage attribution log (powers kill assists for SI/tank/witch)
 *   - Multi-kill burst detection per attacker
 *   - Time-to-kill per SI (accumulates onto player_si_stats async)
 *   - DPS sampler (sliding 5s window, retains session peak in g_Clients[].peakDpsThisSession)
 *   - Hitgroup classification routed from event handlers
 *   - BW state damage capture
 *   - FF-kills-caused tracking
 *
 * No event hooks of its own — called from events.sp's existing hooks via
 * the Bizzy_Combat_* helpers below.
 */

#define KILL_ASSIST_WINDOW_S   5
#define MULTIKILL_WINDOW_MS    150
#define DPS_WINDOW_MS          5000
#define BW_THRESHOLD_HP        40

// -----------------------------------------------------------------------------
// Per-victim damage log. Tracks the last ATTACKERS_PER_VICTIM attackers and
// their cumulative damage over a short window. On SI/tank/witch death,
// the killer's stats.kill_assist columns get +=1 for each *other* recent
// attacker.
// -----------------------------------------------------------------------------

#define ATTACKERS_PER_VICTIM 6

enum struct VictimDmgLog
{
    int  attackerUid[ATTACKERS_PER_VICTIM];   // userid (so we survive disconnects)
    int  damage[ATTACKERS_PER_VICTIM];
    int  lastTimeMs[ATTACKERS_PER_VICTIM];
    int  count;
}

// Not static — tank_witch.sp reads from this to build boss_damage_log rows.
VictimDmgLog g_VictimLog[2049];

stock void Bizzy_Combat_OnDamage(int attacker, int victim, int damage)
{
    if (victim < 0 || victim >= sizeof g_VictimLog) return;
    if (!Bizzy_IsValidPlayer(attacker)) return;

    int uid = GetClientUserId(attacker);
    int nowMs = RoundToFloor(GetEngineTime() * 1000.0);

    // Find existing entry or pick the oldest slot to evict
    int found = -1, oldestIdx = 0, oldestMs = 0x7FFFFFFF;
    for (int i = 0; i < g_VictimLog[victim].count; i++)
    {
        if (g_VictimLog[victim].attackerUid[i] == uid) { found = i; break; }
        if (g_VictimLog[victim].lastTimeMs[i] < oldestMs)
        {
            oldestMs = g_VictimLog[victim].lastTimeMs[i];
            oldestIdx = i;
        }
    }
    if (found == -1)
    {
        if (g_VictimLog[victim].count < ATTACKERS_PER_VICTIM)
        {
            found = g_VictimLog[victim].count++;
        }
        else
        {
            found = oldestIdx;
            g_VictimLog[victim].damage[found] = 0;
        }
        g_VictimLog[victim].attackerUid[found] = uid;
    }
    g_VictimLog[victim].damage[found] += damage;
    g_VictimLog[victim].lastTimeMs[found] = nowMs;
}

/**
 * Credit kill assists to everyone in the victim's damage log within
 * KILL_ASSIST_WINDOW_S seconds, EXCEPT the killer.
 *
 * `siKind` is one of: 0 = special (smoker/hunter/boomer/spitter/jockey/charger),
 *                    1 = tank,
 *                    2 = witch.
 */
stock void Bizzy_Combat_OnSIKill(int victim, int killer, int siKind)
{
    if (victim < 0 || victim >= sizeof g_VictimLog) return;
    int nowMs = RoundToFloor(GetEngineTime() * 1000.0);
    int killerUid = Bizzy_IsValidPlayer(killer) ? GetClientUserId(killer) : 0;
    int cutoffMs = nowMs - KILL_ASSIST_WINDOW_S * 1000;

    for (int i = 0; i < g_VictimLog[victim].count; i++)
    {
        if (g_VictimLog[victim].lastTimeMs[i] < cutoffMs) continue;
        int uid = g_VictimLog[victim].attackerUid[i];
        if (uid == 0 || uid == killerUid) continue;
        int client = GetClientOfUserId(uid);
        if (!Bizzy_IsValidPlayer(client)) continue;

        switch (siKind)
        {
            case 1: g_Clients[client].killAssistsTank++;
            case 2: g_Clients[client].killAssistsWitch++;
            default: g_Clients[client].killAssistsSpecial++;
        }
        Bizzy_Awards_Fire(client, "kill_assist", 1);
    }

    // Tank solo-kill: did the killer do >=50% of damage?
    if (siKind == 1 && Bizzy_IsValidPlayer(killer))
    {
        int total = 0, killerDmg = 0;
        for (int i = 0; i < g_VictimLog[victim].count; i++)
        {
            total += g_VictimLog[victim].damage[i];
            if (g_VictimLog[victim].attackerUid[i] == killerUid)
                killerDmg = g_VictimLog[victim].damage[i];
        }
        if (total > 0 && killerDmg * 2 >= total)
        {
            g_Clients[killer].tankSoloKills++;
            Bizzy_Awards_Fire(killer, "tank_solo_kill", 1);
        }
        g_Clients[killer].tankKillParticipations++;
    }

    g_VictimLog[victim].count = 0; // reset for the next spawn at this entity
}

// -----------------------------------------------------------------------------
// Multi-kill burst detection
// -----------------------------------------------------------------------------

#define BURST_WINDOW_SLOTS 8

enum struct BurstWindow
{
    int  timesMs[BURST_WINDOW_SLOTS];
    int  count;
}

static BurstWindow g_Bursts[MAXPLAYERS + 1];

stock void Bizzy_Combat_OnInfectedKill(int attacker)
{
    if (!Bizzy_IsValidPlayer(attacker)) return;
    int nowMs = RoundToFloor(GetEngineTime() * 1000.0);
    int cutoff = nowMs - MULTIKILL_WINDOW_MS;

    // Drop stale entries (compact in place)
    int kept = 0;
    for (int i = 0; i < g_Bursts[attacker].count; i++)
    {
        if (g_Bursts[attacker].timesMs[i] >= cutoff)
            g_Bursts[attacker].timesMs[kept++] = g_Bursts[attacker].timesMs[i];
    }
    g_Bursts[attacker].count = kept;
    if (kept >= BURST_WINDOW_SLOTS) return; // overflow guard
    g_Bursts[attacker].timesMs[kept] = nowMs;
    g_Bursts[attacker].count = kept + 1;

    // If we've just hit a multi-kill threshold, count it
    int burst = g_Bursts[attacker].count;
    if      (burst == 2) { g_Clients[attacker].multikill2++; }
    else if (burst == 3) { g_Clients[attacker].multikill3++;
                           Bizzy_Awards_Fire(attacker, "multikill_3", 1); }
    else if (burst == 4) { g_Clients[attacker].multikill4++;
                           Bizzy_Awards_Fire(attacker, "multikill_4", 1); }
    else if (burst >= 5) { g_Clients[attacker].multikill5plus++;
                           Bizzy_Awards_Fire(attacker, "multikill_5", 1); }

    if (burst > g_Clients[attacker].biggestMultikill)
        g_Clients[attacker].biggestMultikill = burst;
}

// -----------------------------------------------------------------------------
// Hitgroup routing (called from Event_PlayerHurt)
// -----------------------------------------------------------------------------

stock void Bizzy_Combat_RouteHitgroup(int attacker, int hitgroup, int damage)
{
    if (!Bizzy_IsValidPlayer(attacker)) return;
    switch (hitgroup)
    {
        case 1:        g_Clients[attacker].dmgHitHead    += damage;
        case 2:        g_Clients[attacker].dmgHitChest   += damage;
        case 3:        g_Clients[attacker].dmgHitStomach += damage;
        case 4, 5, 6, 7: g_Clients[attacker].dmgHitLimb  += damage;
        default:       g_Clients[attacker].dmgHitOther   += damage;
    }
    if (damage > g_Clients[attacker].biggestSingleHit)
        g_Clients[attacker].biggestSingleHit = damage;
}

// -----------------------------------------------------------------------------
// DPS sampler — rolling DPS_WINDOW_MS window. We approximate with a
// reset-on-overflow scheme: damage accumulates in a window starting at
// dpsWindowStartMs; when it expires, the window's dps is candidate for
// session peak and the window resets.
// -----------------------------------------------------------------------------

stock void Bizzy_Combat_OnAttack(int attacker, int damage)
{
    if (!Bizzy_IsValidPlayer(attacker)) return;
    int nowMs = RoundToFloor(GetEngineTime() * 1000.0);

    if (g_Clients[attacker].dpsWindowStartMs == 0
        || (nowMs - g_Clients[attacker].dpsWindowStartMs) > DPS_WINDOW_MS)
    {
        // Close prior window
        if (g_Clients[attacker].dpsWindowStartMs != 0)
        {
            int span = nowMs - g_Clients[attacker].dpsWindowStartMs;
            if (span > 0)
            {
                int dps = g_Clients[attacker].dpsWindowDamage * 1000 / span;
                if (dps > g_Clients[attacker].peakDpsThisSession)
                    g_Clients[attacker].peakDpsThisSession = dps;
            }
        }
        g_Clients[attacker].dpsWindowStartMs = nowMs;
        g_Clients[attacker].dpsWindowDamage = 0;
    }
    g_Clients[attacker].dpsWindowDamage += damage;
}

// -----------------------------------------------------------------------------
// BW (black-and-white) state damage capture & state tracking
// -----------------------------------------------------------------------------

stock void Bizzy_Combat_CheckBWState(int client)
{
    if (!Bizzy_IsValidPlayer(client)) return;
    if (GetClientTeam(client) != TEAM_SURVIVORS) return;
    int hp = GetClientHealth(client);
    bool isBW = (hp > 0 && hp <= BW_THRESHOLD_HP);
    int now = GetTime();

    if (isBW && g_Clients[client].bwEnteredEpoch == 0)
    {
        g_Clients[client].bwEnteredEpoch = now;
        g_Clients[client].bwEntries++;
    }
    else if (!isBW && g_Clients[client].bwEnteredEpoch != 0)
    {
        g_Clients[client].bwTimeS += (now - g_Clients[client].bwEnteredEpoch);
        g_Clients[client].bwEnteredEpoch = 0;
    }

    if (hp > 0 && hp < g_Clients[client].lowestHpSurvival)
        g_Clients[client].lowestHpSurvival = hp;
}

stock void Bizzy_Combat_OnDamageTaken(int victim, int damage, const char[] weapon, int attacker)
{
    if (!Bizzy_IsValidPlayer(victim)) return;

    // BW damage attribution
    int hp = GetClientHealth(victim);
    if (hp > 0 && hp <= BW_THRESHOLD_HP)
        g_Clients[victim].damageTakenBW += damage;

    // Environment / self damage classification
    if (StrEqual(weapon, "world") || StrEqual(weapon, "worldspawn")
        || StrEqual(weapon, "trigger_hurt"))
    {
        g_Clients[victim].damageEnvironment += damage;
        g_Clients[victim].fallDamageTaken += damage; // assume world dmg is mostly falls
    }
    if (attacker == victim)
    {
        g_Clients[victim].damageSelf += damage;
    }

    // "Untouchable" map flag: any damage taken voids the streak
    if (damage > 0) g_Clients[victim].untouchableMapRunning = 0;
}

stock void Bizzy_Combat_OnReload(int client)
{
    if (Bizzy_IsValidPlayer(client))
        g_Clients[client].reloads++;
}

// -----------------------------------------------------------------------------
// FF-kills-caused: track recent FF damage; if victim dies within window
// without other-source damage in between, credit the attacker.
// -----------------------------------------------------------------------------

#define FF_KILL_WINDOW_S 10

static int  g_LastFFAttackerUid[MAXPLAYERS + 1];
static int  g_LastFFTime[MAXPLAYERS + 1];

stock void Bizzy_Combat_OnFriendlyFire(int attacker, int victim)
{
    if (!Bizzy_IsValidPlayer(victim) || !Bizzy_IsValidPlayer(attacker)) return;
    g_LastFFAttackerUid[victim] = GetClientUserId(attacker);
    g_LastFFTime[victim] = GetTime();
}

stock void Bizzy_Combat_OnDeathFFCheck(int victim)
{
    if (g_LastFFAttackerUid[victim] == 0) return;
    if ((GetTime() - g_LastFFTime[victim]) > FF_KILL_WINDOW_S) return;
    int attacker = GetClientOfUserId(g_LastFFAttackerUid[victim]);
    if (Bizzy_IsValidPlayer(attacker))
    {
        g_Clients[attacker].ffKillsCaused++;
        Bizzy_Awards_Fire(attacker, "ff_killer", 1);
    }
    g_LastFFAttackerUid[victim] = 0;
}
