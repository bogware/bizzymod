-- =============================================================================
-- bizzymod-stats — 007_extended_stats
--
-- Additive expansion: throwables, target-specific damage, time alive/dead,
-- pinned-as-survivor counts, distance travelled, and a career_bests table
-- of single-event records.
--
-- All changes are ADD COLUMN with a default, so existing rows stay valid
-- and the migration is safe to apply against a populated database.
-- =============================================================================

SET NAMES utf8mb4;
SET FOREIGN_KEY_CHECKS = 0;

-- -----------------------------------------------------------------------------
-- Throwable usage. Captured per (player, gamemode); covers all throwables
-- through one set of columns (pipe / molotov / bile). The throwable type
-- is identified at capture time and routed to the right column.
-- -----------------------------------------------------------------------------
ALTER TABLE `player_stats`
    ADD COLUMN `pipe_bombs_thrown`   INT UNSIGNED NOT NULL DEFAULT 0,
    ADD COLUMN `pipe_bombs_kills`    INT UNSIGNED NOT NULL DEFAULT 0,
    ADD COLUMN `molotovs_thrown`     INT UNSIGNED NOT NULL DEFAULT 0,
    ADD COLUMN `molotovs_kills`      INT UNSIGNED NOT NULL DEFAULT 0,
    ADD COLUMN `molotov_burn_damage` BIGINT UNSIGNED NOT NULL DEFAULT 0,
    ADD COLUMN `bile_bombs_thrown`   INT UNSIGNED NOT NULL DEFAULT 0,
    ADD COLUMN `bile_bombs_hits`     INT UNSIGNED NOT NULL DEFAULT 0
        COMMENT 'count of survivors+infected hit with bile';

-- -----------------------------------------------------------------------------
-- Target-specific damage. The `damage_dealt` column is the total; these
-- columns let us break out the headline targets.
-- -----------------------------------------------------------------------------
ALTER TABLE `player_stats`
    ADD COLUMN `damage_to_tank`   BIGINT UNSIGNED NOT NULL DEFAULT 0,
    ADD COLUMN `damage_to_witch`  BIGINT UNSIGNED NOT NULL DEFAULT 0,
    ADD COLUMN `damage_to_special` BIGINT UNSIGNED NOT NULL DEFAULT 0
        COMMENT 'aggregate damage to all special infected types';

-- -----------------------------------------------------------------------------
-- Time alive / dead tracking. Useful for "always last to die" leaderboards.
-- -----------------------------------------------------------------------------
ALTER TABLE `player_stats`
    ADD COLUMN `time_alive_s`     INT UNSIGNED NOT NULL DEFAULT 0,
    ADD COLUMN `time_dead_s`      INT UNSIGNED NOT NULL DEFAULT 0,
    ADD COLUMN `time_incapped_s`  INT UNSIGNED NOT NULL DEFAULT 0;

-- -----------------------------------------------------------------------------
-- Pinned-as-survivor counts. Mirror of player_si_stats but from the
-- victim's perspective, so we can answer "who gets caught by smokers
-- the most" without joining to the SI side.
-- -----------------------------------------------------------------------------
ALTER TABLE `player_stats`
    ADD COLUMN `pinned_by_smoker`  INT UNSIGNED NOT NULL DEFAULT 0,
    ADD COLUMN `pinned_by_hunter`  INT UNSIGNED NOT NULL DEFAULT 0,
    ADD COLUMN `pinned_by_jockey`  INT UNSIGNED NOT NULL DEFAULT 0,
    ADD COLUMN `pinned_by_charger` INT UNSIGNED NOT NULL DEFAULT 0,
    ADD COLUMN `vomited_on`        INT UNSIGNED NOT NULL DEFAULT 0,
    ADD COLUMN `self_escapes`      INT UNSIGNED NOT NULL DEFAULT 0
        COMMENT 'broke a pin without teammate help (shoot the SI off yourself)';

-- -----------------------------------------------------------------------------
-- Distance travelled (engine reports per-player movement distance). Sum
-- across sessions; the units are game units, divide by 16 for feet, by
-- ~52 for meters (rough conversion).
-- -----------------------------------------------------------------------------
ALTER TABLE `player_stats`
    ADD COLUMN `distance_units` BIGINT UNSIGNED NOT NULL DEFAULT 0;

-- -----------------------------------------------------------------------------
-- career_bests: single-row "best ever" records per player. Each column
-- holds the player's all-time peak for one metric. Updates happen via
-- INSERT ... ON DUPLICATE KEY UPDATE col = GREATEST(col, VALUES(col)).
-- -----------------------------------------------------------------------------
CREATE TABLE `career_bests` (
    `player_id`                  BIGINT UNSIGNED NOT NULL,
    `most_points_in_session`     INT UNSIGNED NOT NULL DEFAULT 0,
    `most_kills_in_session`      INT UNSIGNED NOT NULL DEFAULT 0,
    `most_headshots_in_session`  INT UNSIGNED NOT NULL DEFAULT 0,
    `most_points_in_round`       INT UNSIGNED NOT NULL DEFAULT 0,
    `most_kills_in_round`        INT UNSIGNED NOT NULL DEFAULT 0,
    `most_damage_in_round`       INT UNSIGNED NOT NULL DEFAULT 0,
    `biggest_pounce_damage`      INT UNSIGNED NOT NULL DEFAULT 0,
    `biggest_tank_punch_damage`  INT UNSIGNED NOT NULL DEFAULT 0,
    `longest_jockey_ride_s`      INT UNSIGNED NOT NULL DEFAULT 0,
    `longest_charger_carry`      INT UNSIGNED NOT NULL DEFAULT 0,
    `longest_kill_streak`        INT UNSIGNED NOT NULL DEFAULT 0
        COMMENT 'most kills without dying',
    `longest_survival_time_s`    INT UNSIGNED NOT NULL DEFAULT 0
        COMMENT 'longest single span alive on Survivor team',
    `fastest_finale_s`           INT UNSIGNED NOT NULL DEFAULT 0
        COMMENT 'shortest time to win a finale',
    `last_updated`               DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
        ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (`player_id`),
    CONSTRAINT `fk_career_bests_player` FOREIGN KEY (`player_id`)
        REFERENCES `players` (`id`) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- -----------------------------------------------------------------------------
-- Extend player_round_stats with the new per-round metrics so we can
-- aggregate them at match close.
-- -----------------------------------------------------------------------------
ALTER TABLE `player_round_stats`
    ADD COLUMN `headshots`        INT UNSIGNED NOT NULL DEFAULT 0,
    ADD COLUMN `kill_streak_max`  INT UNSIGNED NOT NULL DEFAULT 0
        COMMENT 'longest kills-without-dying span within this round',
    ADD COLUMN `damage_to_tank`   INT UNSIGNED NOT NULL DEFAULT 0,
    ADD COLUMN `time_alive_s`     INT UNSIGNED NOT NULL DEFAULT 0;

-- -----------------------------------------------------------------------------
-- New awards introduced by this migration. Existing player_awards rows
-- unaffected.
-- -----------------------------------------------------------------------------
INSERT IGNORE INTO `awards` (`code`, `name`, `description`, `category`, `team`, `game_id`, `is_negative`, `base_points`, `display_order`) VALUES
    ('pipe_kill',         'Pipe Bombing Champion',   'Killed common infected with a pipe bomb', 'survivor', 2, 0, 0, 0, 40),
    ('molotov_kill',      'Pyromaniac',              'Killed infected with molotov burn',       'survivor', 2, 0, 0, 0, 41),
    ('bile_throw',        'Bile Boomer',             'Hit with a bile bomb',                    'survivor', 2, 2, 0, 0, 42),
    ('self_escape',       'Self Rescue',             'Broke a SI pin without a teammate',       'survivor', 2, 0, 0, 0, 43),
    ('kill_streak_10',    'Kill Streak ×10',         '10 kills without dying',                   'survivor', 2, 0, 0, 0, 44),
    ('kill_streak_25',    'Kill Streak ×25',         '25 kills without dying',                   'survivor', 2, 0, 0, 0, 45),
    ('kill_streak_50',    'Kill Streak ×50',         '50 kills without dying',                   'survivor', 2, 0, 0, 0, 46),
    ('headshot_master',   'Headshot Master',         'Sustained headshot ratio over time',      'survivor', 2, 0, 0, 0, 47);

-- -----------------------------------------------------------------------------
-- Convenience view: career bests joined to player name.
-- -----------------------------------------------------------------------------
DROP VIEW IF EXISTS `v_career_bests`;
CREATE VIEW `v_career_bests` AS
SELECT
    cb.*,
    CAST(p.name AS CHAR) AS player_name,
    p.steamid
FROM career_bests cb
JOIN players p ON p.id = cb.player_id;

SET FOREIGN_KEY_CHECKS = 1;
