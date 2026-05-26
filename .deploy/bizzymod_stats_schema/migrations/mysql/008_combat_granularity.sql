-- =============================================================================
-- bizzymod-stats — 008_combat_granularity
--
-- Roadmap §1: Combat granularity. Hitgroup breakdown, kill assists,
-- multi-kills, TTK per SI, DPS peak, long-distance kills, BW damage,
-- environment damage, FF by weapon, FF kills caused, reloads.
--
-- All additive. Safe on populated DBs.
-- =============================================================================

SET NAMES utf8mb4;
SET FOREIGN_KEY_CHECKS = 0;

-- -----------------------------------------------------------------------------
-- Hitgroup breakdown. Mirrors valve hitgroup IDs: 1=head, 2=chest,
-- 3=stomach, 4-5=arm, 6-7=leg, 0=generic. We collapse arm+leg into limb.
-- -----------------------------------------------------------------------------
ALTER TABLE `player_stats`
    ADD COLUMN `dmg_hitgroup_head`    BIGINT UNSIGNED NOT NULL DEFAULT 0,
    ADD COLUMN `dmg_hitgroup_chest`   BIGINT UNSIGNED NOT NULL DEFAULT 0,
    ADD COLUMN `dmg_hitgroup_stomach` BIGINT UNSIGNED NOT NULL DEFAULT 0,
    ADD COLUMN `dmg_hitgroup_limb`    BIGINT UNSIGNED NOT NULL DEFAULT 0,
    ADD COLUMN `dmg_hitgroup_other`   BIGINT UNSIGNED NOT NULL DEFAULT 0;

ALTER TABLE `player_weapon_stats`
    ADD COLUMN `dmg_head`    BIGINT UNSIGNED NOT NULL DEFAULT 0,
    ADD COLUMN `dmg_chest`   BIGINT UNSIGNED NOT NULL DEFAULT 0,
    ADD COLUMN `dmg_limb`    BIGINT UNSIGNED NOT NULL DEFAULT 0,
    ADD COLUMN `damage_friendly` BIGINT UNSIGNED NOT NULL DEFAULT 0,
    ADD COLUMN `reloads`     INT UNSIGNED NOT NULL DEFAULT 0;

-- -----------------------------------------------------------------------------
-- Kill assists. We credit anyone who damaged the SI/tank/witch within
-- KILL_ASSIST_WINDOW_S seconds before the killing blow, excluding the
-- killer themselves. Stored as a counter per (player, gamemode).
-- -----------------------------------------------------------------------------
ALTER TABLE `player_stats`
    ADD COLUMN `kill_assists_special` INT UNSIGNED NOT NULL DEFAULT 0,
    ADD COLUMN `kill_assists_tank`    INT UNSIGNED NOT NULL DEFAULT 0,
    ADD COLUMN `kill_assists_witch`   INT UNSIGNED NOT NULL DEFAULT 0;

-- -----------------------------------------------------------------------------
-- Multi-kills per shot. A "multi-kill" is N>=2 infected deaths from the
-- same attacker within MULTIKILL_WINDOW_MS milliseconds. We bucket by N.
-- -----------------------------------------------------------------------------
ALTER TABLE `player_stats`
    ADD COLUMN `multikill_2` INT UNSIGNED NOT NULL DEFAULT 0,
    ADD COLUMN `multikill_3` INT UNSIGNED NOT NULL DEFAULT 0,
    ADD COLUMN `multikill_4` INT UNSIGNED NOT NULL DEFAULT 0,
    ADD COLUMN `multikill_5plus` INT UNSIGNED NOT NULL DEFAULT 0;

-- -----------------------------------------------------------------------------
-- Time-to-kill per SI. Sum + count per (player, si). Average is derived.
-- -----------------------------------------------------------------------------
ALTER TABLE `player_si_stats`
    ADD COLUMN `ttk_total_ms`  BIGINT UNSIGNED NOT NULL DEFAULT 0,
    ADD COLUMN `ttk_count`     INT UNSIGNED NOT NULL DEFAULT 0,
    ADD COLUMN `ttk_min_ms`    INT UNSIGNED NOT NULL DEFAULT 0,
    ADD COLUMN `ttk_max_ms`    INT UNSIGNED NOT NULL DEFAULT 0;

-- -----------------------------------------------------------------------------
-- DPS peak. Tracked as the highest sustained DPS over DPS_WINDOW_S
-- seconds. Single number per player.
-- -----------------------------------------------------------------------------
ALTER TABLE `career_bests`
    ADD COLUMN `peak_dps`               INT UNSIGNED NOT NULL DEFAULT 0,
    ADD COLUMN `longest_kill_units`     INT UNSIGNED NOT NULL DEFAULT 0,
    ADD COLUMN `biggest_single_hit`     INT UNSIGNED NOT NULL DEFAULT 0
        COMMENT 'largest single damage event ever dealt';

-- -----------------------------------------------------------------------------
-- Damage classification. BW = damage taken while in the black-and-white
-- (low HP) state. Environment = world/self damage (falls, own fire, etc.)
-- -----------------------------------------------------------------------------
ALTER TABLE `player_stats`
    ADD COLUMN `damage_taken_bw`     BIGINT UNSIGNED NOT NULL DEFAULT 0,
    ADD COLUMN `damage_environment`  BIGINT UNSIGNED NOT NULL DEFAULT 0,
    ADD COLUMN `damage_self`         BIGINT UNSIGNED NOT NULL DEFAULT 0
        COMMENT 'self-damage from fire, falls, etc',
    ADD COLUMN `fall_deaths`         INT UNSIGNED NOT NULL DEFAULT 0;

-- -----------------------------------------------------------------------------
-- FF-kills-caused: friendly fire damage that resulted in a teammate
-- death within FF_KILL_WINDOW_S seconds. Counts the *count* of caused
-- deaths, not the damage.
-- -----------------------------------------------------------------------------
ALTER TABLE `player_stats`
    ADD COLUMN `ff_kills_caused`  INT UNSIGNED NOT NULL DEFAULT 0,
    ADD COLUMN `reloads`          INT UNSIGNED NOT NULL DEFAULT 0;

-- -----------------------------------------------------------------------------
-- Multi-kill records: distribution view for "biggest multi-kill ever".
-- -----------------------------------------------------------------------------
ALTER TABLE `career_bests`
    ADD COLUMN `biggest_multikill` TINYINT UNSIGNED NOT NULL DEFAULT 0;

-- -----------------------------------------------------------------------------
-- New awards
-- -----------------------------------------------------------------------------
INSERT IGNORE INTO `awards`
    (`code`, `name`, `description`, `category`, `team`, `game_id`, `is_negative`, `base_points`, `display_order`)
VALUES
    ('sniper_kill',     'Long Shot',     'Killed an infected at >1500 units distance',         'survivor', 2, 0, 0, 0, 50),
    ('multikill_3',     'Triple Kill',   'Killed 3 commons with one shot',                     'survivor', 2, 0, 0, 0, 51),
    ('multikill_4',     'Quad Kill',     'Killed 4 commons with one shot',                     'survivor', 2, 0, 0, 0, 52),
    ('multikill_5',     'Penta Kill',    'Killed 5+ commons with one shot',                    'survivor', 2, 0, 0, 0, 53),
    ('kill_assist',     'Assist',        'Damaged an SI killed by a teammate within 5s',       'survivor', 2, 0, 0, 0, 54),
    ('tank_solo_kill',  'Solo Tanker',   'Solo-killed a tank (>50% damage contribution)',      'survivor', 2, 0, 0, 0, 55),
    ('ff_killer',       'Friendly Death','Caused a teammate death via friendly fire',          'ff',       2, 0, 1, 0, 91),
    ('sharpshooter',    'Sharpshooter',  'Sustained accuracy >=75% over 10+ sessions',         'survivor', 2, 0, 0, 0, 56);

-- -----------------------------------------------------------------------------
-- View: per-SI average TTK with names.
-- -----------------------------------------------------------------------------
DROP VIEW IF EXISTS `v_player_ttk`;
CREATE VIEW `v_player_ttk` AS
SELECT
    psi.player_id,
    CAST(p.name AS CHAR) AS player_name,
    si.code  AS si_code,
    si.name  AS si_name,
    psi.ttk_count,
    psi.ttk_min_ms,
    psi.ttk_max_ms,
    CASE WHEN psi.ttk_count > 0
         THEN ROUND(psi.ttk_total_ms / psi.ttk_count)
         ELSE 0 END AS ttk_avg_ms
FROM player_si_stats psi
JOIN players p           ON p.id  = psi.player_id
JOIN special_infected si ON si.id = psi.si_id;

-- -----------------------------------------------------------------------------
-- View: accuracy + headshot ratios from refreshed counts.
-- -----------------------------------------------------------------------------
DROP VIEW IF EXISTS `v_player_precision`;
CREATE VIEW `v_player_precision` AS
SELECT
    p.id                    AS player_id,
    CAST(p.name AS CHAR)    AS player_name,
    SUM(ps.shots_fired)     AS shots_fired,
    SUM(ps.shots_hit)       AS shots_hit,
    SUM(ps.headshots)       AS headshots,
    SUM(ps.dmg_hitgroup_head)    AS head_damage,
    SUM(ps.dmg_hitgroup_chest)   AS chest_damage,
    SUM(ps.dmg_hitgroup_limb)    AS limb_damage,
    CASE WHEN SUM(ps.shots_fired) > 0
         THEN ROUND(100.0 * SUM(ps.shots_hit) / SUM(ps.shots_fired), 2)
         ELSE 0 END         AS accuracy_pct,
    CASE WHEN SUM(ps.shots_hit) > 0
         THEN ROUND(100.0 * SUM(ps.headshots) / SUM(ps.shots_hit), 2)
         ELSE 0 END         AS headshot_pct
FROM players p
LEFT JOIN player_stats ps ON ps.player_id = p.id AND ps.server_id = 0
GROUP BY p.id;

SET FOREIGN_KEY_CHECKS = 1;
