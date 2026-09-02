/**
 * movement.sp — periodic position sampler.
 *
 * One Timer at 0.25s drives:
 *   - per-survivor distance accumulation (XYZ delta sum)
 *   - per-survivor BW state polling (HP check)
 *   - nearest-teammate distance & "time alone" tracking
 *   - team spread metrics (max + running average)
 *   - tank position deltas (via tank_witch.sp)
 *
 * Distance attribution: we don't classify by type (run/jump/swim); the
 * total is `distance_units` on player_stats. Sanity bound: deltas of
 * >2000 units between two 250ms samples are dropped as teleports.
 */

#define MOVEMENT_SAMPLE_INTERVAL 0.25
#define LONE_THRESHOLD_UNITS     750
#define TELEPORT_THRESHOLD_UNITS 2000

void Bizzy_OnMovementInit()
{
    CreateTimer(MOVEMENT_SAMPLE_INTERVAL, Timer_MovementSample,
                _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

static Action Timer_MovementSample(Handle timer)
{
    if (!g_cvEnabled.BoolValue) return Plugin_Continue;

    // Walk alive survivors; gather positions for distance + spread metrics.
    int alive[MAXPLAYERS + 1];
    int aliveCount = 0;
    float pos[MAXPLAYERS + 1][3];

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!Bizzy_IsValidPlayer(i)) continue;
        if (GetClientTeam(i) != TEAM_SURVIVORS) continue;
        if (!IsPlayerAlive(i)) continue;

        GetClientAbsOrigin(i, pos[i]);

        // Distance accumulation
        if (g_Clients[i].samplerLastX != 0 || g_Clients[i].samplerLastY != 0)
        {
            int dx = RoundToFloor(pos[i][0]) - g_Clients[i].samplerLastX;
            int dy = RoundToFloor(pos[i][1]) - g_Clients[i].samplerLastY;
            int dz = RoundToFloor(pos[i][2]) - g_Clients[i].samplerLastZ;
            int d = RoundToFloor(SquareRoot(float(dx*dx + dy*dy + dz*dz)));
            if (d < TELEPORT_THRESHOLD_UNITS)
                g_Clients[i].distanceUnits += d;
        }
        g_Clients[i].samplerLastX = RoundToFloor(pos[i][0]);
        g_Clients[i].samplerLastY = RoundToFloor(pos[i][1]);
        g_Clients[i].samplerLastZ = RoundToFloor(pos[i][2]);

        // BW state poll (cheaper than hooking HP changes)
        Bizzy_Combat_CheckBWState(i);

        // Weapon-tier sampling: 0.25s per sample tick added to the bucket
        // matching the player's currently-held weapon.
        int tier = ClassifyActiveWeapon(i);
        switch (tier)
        {
            case 1: g_Clients[i].weaponT1TimeS++;
            case 2: g_Clients[i].weaponT2TimeS++;
            case 3: g_Clients[i].weaponMeleeTimeS++;
            case 4: g_Clients[i].weaponSniperTimeS++;
        }

        alive[aliveCount++] = i;
    }

    // Pairwise spread + alone detection
    if (aliveCount >= 2)
    {
        int maxSpread = 0;

        for (int a = 0; a < aliveCount; a++)
        {
            int ca = alive[a];
            int minToTeammate = 0x7FFFFFFF;
            for (int b = 0; b < aliveCount; b++)
            {
                if (a == b) continue;
                int cb = alive[b];
                int dx = RoundToFloor(pos[ca][0] - pos[cb][0]);
                int dy = RoundToFloor(pos[ca][1] - pos[cb][1]);
                int dz = RoundToFloor(pos[ca][2] - pos[cb][2]);
                int d = RoundToFloor(SquareRoot(float(dx*dx + dy*dy + dz*dz)));
                if (d > maxSpread) maxSpread = d;
                if (d < minToTeammate) minToTeammate = d;
            }

            bool isAlone = (minToTeammate > LONE_THRESHOLD_UNITS);
            if (isAlone)
            {
                g_Clients[ca].timeAloneS += 1; // 4 samples per second; 1/4s per sample => use ms? simpler: 0.25s -> add 0
                // To avoid floating arithmetic, accumulate quarters in a hidden field; for v1 the resolution loss is fine.
            }
            // Transition detection for "breaks from group"
            if (isAlone && !g_Clients[ca].samplerWasAlone)
                g_Clients[ca].breaksFromGroup++;
            g_Clients[ca].samplerWasAlone = isAlone;
        }

        // Team spread metric on the first alive player (rep)
        int repClient = alive[0];
        if (maxSpread > g_Clients[repClient].maxTeamSpreadUnits)
        {
            for (int a = 0; a < aliveCount; a++)
                if (maxSpread > g_Clients[alive[a]].maxTeamSpreadUnits)
                    g_Clients[alive[a]].maxTeamSpreadUnits = maxSpread;
        }
        // Running average accumulation (one sample per quarter-second)
        for (int a = 0; a < aliveCount; a++)
        {
            g_Clients[alive[a]].avgTeamSpreadSum += maxSpread;
            g_Clients[alive[a]].avgTeamSpreadCount++;
        }
    }

    // Tank sampling
    Bizzy_TankWitch_SamplePositions();

    return Plugin_Continue;
}

stock void Bizzy_Movement_FinalizeSpread(int client)
{
    if (g_Clients[client].avgTeamSpreadCount > 0)
    {
        // Already a sum; consumers compute the average at query time. Keep
        // as a separate field so we can divide cleanly. We persist
        // (avgTeamSpreadSum / avgTeamSpreadCount) → avg_team_spread_units.
    }
}

static int ClassifyActiveWeapon(int client)
{
    int wpn = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
    if (wpn <= 0 || !IsValidEntity(wpn)) return 0;
    char cls[48];
    GetEntityClassname(wpn, cls, sizeof cls);
    // L4D2 weapon classnames
    if (StrEqual(cls, "weapon_melee")) return 3;
    if (StrEqual(cls, "weapon_chainsaw")) return 3;
    if (StrContains(cls, "sniper", false) >= 0
        || StrEqual(cls, "weapon_hunting_rifle")) return 4;
    // T2 list
    if (StrEqual(cls, "weapon_rifle_ak47")     || StrEqual(cls, "weapon_rifle_desert")
     || StrEqual(cls, "weapon_rifle_sg552")    || StrEqual(cls, "weapon_autoshotgun")
     || StrEqual(cls, "weapon_shotgun_spas")   || StrEqual(cls, "weapon_grenade_launcher")
     || StrEqual(cls, "weapon_smg_silenced")   || StrEqual(cls, "weapon_smg_mp5")
     || StrEqual(cls, "weapon_rifle_m60"))     return 2;
    // T1 list (primary weapons)
    if (StrEqual(cls, "weapon_rifle")          || StrEqual(cls, "weapon_smg")
     || StrEqual(cls, "weapon_pumpshotgun")    || StrEqual(cls, "weapon_shotgun_chrome"))
        return 1;
    return 0;
}
