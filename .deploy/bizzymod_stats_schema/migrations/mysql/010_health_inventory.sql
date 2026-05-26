-- =============================================================================
-- bizzymod-stats — 010_health_inventory
--
-- Roadmap §3: Health & inventory management. HP-at-event snapshots,
-- saferoom hoarding, defib priority, weapon-tier time, BW state entries.
-- =============================================================================

SET NAMES utf8mb4;
SET FOREIGN_KEY_CHECKS = 0;

-- -----------------------------------------------------------------------------
-- HP-at-event rollups. Sum + count for "average HP when X" derivation.
-- -----------------------------------------------------------------------------
ALTER TABLE `player_stats`
    ADD COLUMN `hp_at_saferoom_sum`   BIGINT UNSIGNED NOT NULL DEFAULT 0,
    ADD COLUMN `hp_at_saferoom_count` INT UNSIGNED NOT NULL DEFAULT 0,
    ADD COLUMN `hp_at_pills_sum`      BIGINT UNSIGNED NOT NULL DEFAULT 0,
    ADD COLUMN `hp_at_pills_count`    INT UNSIGNED NOT NULL DEFAULT 0,
    ADD COLUMN `hp_at_adrenaline_sum`   BIGINT UNSIGNED NOT NULL DEFAULT 0,
    ADD COLUMN `hp_at_adrenaline_count` INT UNSIGNED NOT NULL DEFAULT 0,
    ADD COLUMN `hp_at_medkit_sum`     BIGINT UNSIGNED NOT NULL DEFAULT 0,
    ADD COLUMN `hp_at_medkit_count`   INT UNSIGNED NOT NULL DEFAULT 0,
    -- Times entered black-and-white (<= 40 hp threshold; configurable plugin-side)
    ADD COLUMN `bw_entries`           INT UNSIGNED NOT NULL DEFAULT 0,
    ADD COLUMN `bw_time_s`            INT UNSIGNED NOT NULL DEFAULT 0
        COMMENT 'sum of seconds spent in BW state';

-- -----------------------------------------------------------------------------
-- Hoarded items: items still in inventory when crossing into the saferoom.
-- We log a +1 per (pills/adrenaline/medkit/throwable) carried in.
-- -----------------------------------------------------------------------------
ALTER TABLE `player_stats`
    ADD COLUMN `pills_hoarded`     INT UNSIGNED NOT NULL DEFAULT 0,
    ADD COLUMN `adrenaline_hoarded` INT UNSIGNED NOT NULL DEFAULT 0,
    ADD COLUMN `medkits_hoarded`   INT UNSIGNED NOT NULL DEFAULT 0,
    ADD COLUMN `throwables_hoarded` INT UNSIGNED NOT NULL DEFAULT 0,
    ADD COLUMN `defibs_hoarded`    INT UNSIGNED NOT NULL DEFAULT 0
        COMMENT 'defibs carried into a saferoom unused';

-- -----------------------------------------------------------------------------
-- Defib priority: cumulative points-of-target. Higher = revived important
-- teammates. Averaged via defibs_used count at query time.
-- -----------------------------------------------------------------------------
ALTER TABLE `player_stats`
    ADD COLUMN `defib_target_points_sum` BIGINT NOT NULL DEFAULT 0
        COMMENT 'sum of revived players'' session points at defib time';

-- -----------------------------------------------------------------------------
-- Weapon-tier time tracking. T1 / T2 / melee / sniper split.
-- -----------------------------------------------------------------------------
ALTER TABLE `player_stats`
    ADD COLUMN `weapon_t1_time_s`     INT UNSIGNED NOT NULL DEFAULT 0,
    ADD COLUMN `weapon_t2_time_s`     INT UNSIGNED NOT NULL DEFAULT 0,
    ADD COLUMN `weapon_melee_time_s`  INT UNSIGNED NOT NULL DEFAULT 0,
    ADD COLUMN `weapon_sniper_time_s` INT UNSIGNED NOT NULL DEFAULT 0;

-- -----------------------------------------------------------------------------
-- Update career_bests with health-flavored peaks.
-- -----------------------------------------------------------------------------
ALTER TABLE `career_bests`
    ADD COLUMN `most_revives_in_session` INT UNSIGNED NOT NULL DEFAULT 0,
    ADD COLUMN `most_heals_in_session`   INT UNSIGNED NOT NULL DEFAULT 0,
    ADD COLUMN `lowest_hp_survival`      TINYINT UNSIGNED NOT NULL DEFAULT 100
        COMMENT 'lowest HP reached and survived without taking lethal damage';

-- -----------------------------------------------------------------------------
-- New awards.
-- -----------------------------------------------------------------------------
INSERT IGNORE INTO `awards`
    (`code`, `name`, `description`, `category`, `team`, `game_id`, `is_negative`, `base_points`, `display_order`)
VALUES
    ('iron_stomach',  'Iron Stomach',  'Finished a map at full HP without pills', 'survivor', 2, 0, 0, 0, 66),
    ('generous',      'Generous',      'Gave more pills than you used',           'survivor', 2, 0, 0, 0, 67),
    ('doctor',        'Doctor',        '5+ heals on teammates in one session',    'survivor', 2, 0, 0, 0, 68),
    ('hoarder',       'Hoarder',       'Carried 4+ items into a saferoom',        'survivor', 2, 0, 0, 1, 94),
    ('clutch_heal',   'Clutch Heal',   'Healed below 30 HP and survived 60s+',    'survivor', 2, 0, 0, 0, 69),
    ('defib_pro',     'Defib Pro',     '10 defibs in your career',                'survivor', 2, 2, 0, 0, 70);

-- -----------------------------------------------------------------------------
-- View: derived averages.
-- -----------------------------------------------------------------------------
DROP VIEW IF EXISTS `v_player_health`;
CREATE VIEW `v_player_health` AS
SELECT
    ps.player_id,
    SUM(ps.bw_entries) AS bw_entries,
    SUM(ps.bw_time_s)  AS bw_time_s,
    CASE WHEN SUM(ps.hp_at_saferoom_count) > 0
         THEN ROUND(SUM(ps.hp_at_saferoom_sum) / SUM(ps.hp_at_saferoom_count))
         ELSE NULL END AS avg_hp_at_saferoom,
    CASE WHEN SUM(ps.hp_at_pills_count) > 0
         THEN ROUND(SUM(ps.hp_at_pills_sum) / SUM(ps.hp_at_pills_count))
         ELSE NULL END AS avg_hp_at_pills,
    CASE WHEN SUM(ps.hp_at_medkit_count) > 0
         THEN ROUND(SUM(ps.hp_at_medkit_sum) / SUM(ps.hp_at_medkit_count))
         ELSE NULL END AS avg_hp_at_medkit,
    SUM(ps.pills_hoarded)      AS pills_hoarded,
    SUM(ps.adrenaline_hoarded) AS adrenaline_hoarded,
    SUM(ps.medkits_hoarded)    AS medkits_hoarded,
    SUM(ps.throwables_hoarded) AS throwables_hoarded,
    SUM(ps.defibs_hoarded)     AS defibs_hoarded
FROM player_stats ps
GROUP BY ps.player_id;

SET FOREIGN_KEY_CHECKS = 1;
