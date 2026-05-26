-- =============================================================================
-- bizzymod-stats — 009_si_micro_stats
--
-- Roadmap §2: Special-infected micro-stats. Per-SI columns that
-- differentiate baseline from high-skill versus play.
-- =============================================================================

SET NAMES utf8mb4;
SET FOREIGN_KEY_CHECKS = 0;

-- -----------------------------------------------------------------------------
-- All new columns live on player_si_stats; the column relevance varies
-- by si_id and is documented inline.
-- -----------------------------------------------------------------------------
ALTER TABLE `player_si_stats`
    -- Smoker
    ADD COLUMN `smoker_drag_total_units` BIGINT UNSIGNED NOT NULL DEFAULT 0
        COMMENT 'sum of survivor pull distances (units) — Smoker only',
    ADD COLUMN `smoker_max_drag_units`   INT UNSIGNED NOT NULL DEFAULT 0,
    ADD COLUMN `smoker_self_clears`      INT UNSIGNED NOT NULL DEFAULT 0
        COMMENT 'times survivor shot you off without help — Smoker only',
    ADD COLUMN `smoker_choke_time_s`     INT UNSIGNED NOT NULL DEFAULT 0,
    ADD COLUMN `smoker_tongue_attempts`  INT UNSIGNED NOT NULL DEFAULT 0
        COMMENT 'tongue fires, hit or miss',
    -- Hunter
    ADD COLUMN `hunter_pounce_total_units` BIGINT UNSIGNED NOT NULL DEFAULT 0
        COMMENT 'sum of pounce flight distances',
    ADD COLUMN `hunter_pounce_max_units`   INT UNSIGNED NOT NULL DEFAULT 0,
    ADD COLUMN `hunter_pounce_total_time_ms` BIGINT UNSIGNED NOT NULL DEFAULT 0,
    ADD COLUMN `hunter_pounce_skeeted`     INT UNSIGNED NOT NULL DEFAULT 0
        COMMENT 'times shot mid-pounce before landing',
    -- Boomer
    ADD COLUMN `boomer_vomit_range_units` BIGINT UNSIGNED NOT NULL DEFAULT 0
        COMMENT 'cumulative distance from boomer to nearest survivor at vomit time',
    ADD COLUMN `boomer_death_pop_hits`    INT UNSIGNED NOT NULL DEFAULT 0
        COMMENT 'survivors caught in death-explosion bile',
    -- Spitter
    ADD COLUMN `spitter_cone_hits`        INT UNSIGNED NOT NULL DEFAULT 0
        COMMENT 'survivors caught in spit area',
    ADD COLUMN `spitter_stand_time_s`     INT UNSIGNED NOT NULL DEFAULT 0
        COMMENT 'sum of seconds survivors stood in goo',
    -- Jockey
    ADD COLUMN `jockey_ride_distance_units` BIGINT UNSIGNED NOT NULL DEFAULT 0,
    ADD COLUMN `jockey_ledge_throws`     INT UNSIGNED NOT NULL DEFAULT 0
        COMMENT 'rides ending in survivor death within 2s',
    -- Charger
    ADD COLUMN `charger_charge_total_units` BIGINT UNSIGNED NOT NULL DEFAULT 0,
    ADD COLUMN `charger_max_charge_units`   INT UNSIGNED NOT NULL DEFAULT 0,
    ADD COLUMN `charger_ledge_throws`    INT UNSIGNED NOT NULL DEFAULT 0,
    ADD COLUMN `charger_self_throws`     INT UNSIGNED NOT NULL DEFAULT 0
        COMMENT 'charged off a ledge to your own death',
    -- Tank
    ADD COLUMN `tank_max_survival_s`     INT UNSIGNED NOT NULL DEFAULT 0,
    ADD COLUMN `tank_total_survival_s`   INT UNSIGNED NOT NULL DEFAULT 0,
    ADD COLUMN `tank_passed_on_count`    INT UNSIGNED NOT NULL DEFAULT 0
        COMMENT 'times you took over a tank from another player',
    ADD COLUMN `tank_handed_off_count`   INT UNSIGNED NOT NULL DEFAULT 0
        COMMENT 'times you gave up a tank to another player',
    ADD COLUMN `tank_distance_units`     BIGINT UNSIGNED NOT NULL DEFAULT 0,
    -- Witch (as survivor, the "killer" angle)
    ADD COLUMN `witch_crown_attempts`    INT UNSIGNED NOT NULL DEFAULT 0,
    ADD COLUMN `witch_startles_caused`   INT UNSIGNED NOT NULL DEFAULT 0
        COMMENT 'times you triggered (harassed) a witch',
    ADD COLUMN `witch_chase_survived`    INT UNSIGNED NOT NULL DEFAULT 0
        COMMENT 'witch was startled by you but did not incap you';

-- -----------------------------------------------------------------------------
-- Per-spawn detail table — one row per discrete SI spawn instance, for
-- analytics that benefit from row-level granularity (histograms of
-- pounce distance, charge length, etc.). Off by default; controlled
-- via the bizzymod_stats_log_si_spawns CVar.
-- -----------------------------------------------------------------------------
CREATE TABLE `si_spawn_records` (
    `id`            BIGINT UNSIGNED   NOT NULL AUTO_INCREMENT,
    `player_id`     BIGINT UNSIGNED   NOT NULL,
    `server_id`     INT UNSIGNED      NOT NULL,
    `match_round_id` BIGINT UNSIGNED  NULL,
    `si_id`         TINYINT UNSIGNED  NOT NULL,
    `spawned_at`    DATETIME          NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `lifetime_s`    INT UNSIGNED      NOT NULL DEFAULT 0,
    `damage_dealt`  INT UNSIGNED      NOT NULL DEFAULT 0,
    `incaps_caused` TINYINT UNSIGNED  NOT NULL DEFAULT 0,
    `kills_caused`  TINYINT UNSIGNED  NOT NULL DEFAULT 0,
    `death_cause`   VARCHAR(48)       NULL COMMENT 'melee, gun, fire, fall, skeet, ...',
    `signature_metric` INT            NOT NULL DEFAULT 0
        COMMENT 'SI-specific best metric (pounce distance, charge len, ride time, etc.)',
    PRIMARY KEY (`id`),
    KEY `ix_si_spawn_player` (`player_id`, `spawned_at`),
    KEY `ix_si_spawn_round`  (`match_round_id`),
    CONSTRAINT `fk_si_spawn_player` FOREIGN KEY (`player_id`)
        REFERENCES `players` (`id`) ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT `fk_si_spawn_server` FOREIGN KEY (`server_id`)
        REFERENCES `servers` (`id`) ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT `fk_si_spawn_round` FOREIGN KEY (`match_round_id`)
        REFERENCES `match_rounds` (`id`) ON DELETE SET NULL ON UPDATE CASCADE,
    CONSTRAINT `fk_si_spawn_si` FOREIGN KEY (`si_id`)
        REFERENCES `special_infected` (`id`) ON DELETE RESTRICT ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- -----------------------------------------------------------------------------
-- Awards
-- -----------------------------------------------------------------------------
INSERT IGNORE INTO `awards`
    (`code`, `name`, `description`, `category`, `team`, `game_id`, `is_negative`, `base_points`, `display_order`)
VALUES
    ('smoker_long_drag',  'Long Tongue',       'Pulled a survivor >2000 units in one drag',  'infected', 3, 0, 0, 0, 60),
    ('skeeted',           'Skeeted',           'Survivor shot you mid-pounce',               'infected', 3, 0, 0, 1, 92),
    ('boomer_death_pop',  'Death Bile',        'Caught a survivor in your death explosion',  'infected', 3, 0, 0, 0, 61),
    ('jockey_ledge',      'Ledge Special',     'Rode a survivor off a ledge to their death', 'infected', 3, 2, 0, 0, 62),
    ('charger_long_ride', 'Long Haul',         'Charge straight-line >1500 units',           'infected', 3, 2, 0, 0, 63),
    ('charger_self_throw','Self-Yeet',         'Charged yourself off a ledge to death',      'infected', 3, 2, 0, 1, 93),
    ('tank_handoff',      'Tank Handoff',      'Tank passed to another infected player',     'infected', 3, 0, 0, 0, 64),
    ('witch_chase_dodge', 'Witch Dodger',      'Startled a witch and escaped without incap', 'survivor', 2, 0, 0, 0, 65);

-- -----------------------------------------------------------------------------
-- View: skill summary per SI (avg / max signature metrics).
-- -----------------------------------------------------------------------------
DROP VIEW IF EXISTS `v_si_skill`;
CREATE VIEW `v_si_skill` AS
SELECT
    psi.player_id,
    si.code            AS si_code,
    psi.spawns,
    psi.kills_caused,
    psi.incaps_caused,
    -- Signature aggregates per SI
    CASE si.code
        WHEN 'smoker'  THEN psi.smoker_max_drag_units
        WHEN 'hunter'  THEN psi.hunter_pounce_max_units
        WHEN 'charger' THEN psi.charger_max_charge_units
        WHEN 'tank'    THEN psi.tank_max_survival_s
        ELSE 0
    END AS signature_best,
    CASE WHEN psi.spawns > 0
         THEN ROUND(psi.damage_dealt / psi.spawns)
         ELSE 0 END AS avg_damage_per_spawn,
    CASE WHEN psi.spawns > 0
         THEN ROUND(psi.kills_caused * 100.0 / psi.spawns, 1)
         ELSE 0 END AS kill_rate_pct
FROM player_si_stats psi
JOIN special_infected si ON si.id = psi.si_id;

SET FOREIGN_KEY_CHECKS = 1;
