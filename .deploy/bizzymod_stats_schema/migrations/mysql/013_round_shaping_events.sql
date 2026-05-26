-- =============================================================================
-- bizzymod-stats — 013_round_shaping_events
--
-- Roadmap §6: Round-shaping events. Tank summary cards, witch outcomes,
-- crescendo events, finale waves, saferoom saves, first-blood/first-down.
-- =============================================================================

SET NAMES utf8mb4;
SET FOREIGN_KEY_CHECKS = 0;

-- -----------------------------------------------------------------------------
-- tank_records: one row per tank spawn, closed at tank death.
-- -----------------------------------------------------------------------------
CREATE TABLE `tank_records` (
    `id`              BIGINT UNSIGNED  NOT NULL AUTO_INCREMENT,
    `server_id`       INT UNSIGNED     NOT NULL,
    `match_round_id`  BIGINT UNSIGNED  NULL COMMENT 'NULL = co-op tank, not in versus',
    `map_id`          INT UNSIGNED     NOT NULL,
    `spawned_at`      DATETIME         NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `killed_at`       DATETIME         NULL,
    `survival_s`      INT UNSIGNED     NOT NULL DEFAULT 0,
    `distance_units`  BIGINT UNSIGNED  NOT NULL DEFAULT 0,
    `incaps_caused`   TINYINT UNSIGNED NOT NULL DEFAULT 0,
    `kills_caused`    TINYINT UNSIGNED NOT NULL DEFAULT 0,
    `rocks_thrown`    TINYINT UNSIGNED NOT NULL DEFAULT 0,
    `rocks_hit`       TINYINT UNSIGNED NOT NULL DEFAULT 0,
    `punches_landed`  TINYINT UNSIGNED NOT NULL DEFAULT 0,
    `damage_dealt`    INT UNSIGNED     NOT NULL DEFAULT 0,
    `damage_received` INT UNSIGNED     NOT NULL DEFAULT 0,
    `controlling_players` TINYINT UNSIGNED NOT NULL DEFAULT 1
        COMMENT 'number of distinct players who controlled this tank (hand-offs)',
    `final_controller_id` BIGINT UNSIGNED NULL,
    `killer_id`       BIGINT UNSIGNED  NULL COMMENT 'survivor who got the killing blow',
    `killer_weapon`   VARCHAR(64)      NULL,
    `outcome`         ENUM('killed','passed_on','timeout','round_end') NOT NULL DEFAULT 'killed',
    PRIMARY KEY (`id`),
    KEY `ix_tr_match` (`match_round_id`),
    KEY `ix_tr_map`   (`map_id`, `spawned_at`),
    CONSTRAINT `fk_tr_server` FOREIGN KEY (`server_id`)
        REFERENCES `servers` (`id`) ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT `fk_tr_map`    FOREIGN KEY (`map_id`)
        REFERENCES `maps`    (`id`) ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT `fk_tr_round`  FOREIGN KEY (`match_round_id`)
        REFERENCES `match_rounds` (`id`) ON DELETE SET NULL ON UPDATE CASCADE,
    CONSTRAINT `fk_tr_killer` FOREIGN KEY (`killer_id`)
        REFERENCES `players` (`id`) ON DELETE SET NULL ON UPDATE CASCADE,
    CONSTRAINT `fk_tr_controller` FOREIGN KEY (`final_controller_id`)
        REFERENCES `players` (`id`) ON DELETE SET NULL ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- -----------------------------------------------------------------------------
-- witch_records: one row per witch encounter.
-- -----------------------------------------------------------------------------
CREATE TABLE `witch_records` (
    `id`              BIGINT UNSIGNED  NOT NULL AUTO_INCREMENT,
    `server_id`       INT UNSIGNED     NOT NULL,
    `match_round_id`  BIGINT UNSIGNED  NULL,
    `map_id`          INT UNSIGNED     NOT NULL,
    `seen_at`         DATETIME         NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `outcome`         ENUM('crowned','killed','avoided','escaped','killed_after_startle') NOT NULL DEFAULT 'avoided',
    `startled_by_id`  BIGINT UNSIGNED  NULL,
    `killed_by_id`    BIGINT UNSIGNED  NULL,
    `incapped_id`     BIGINT UNSIGNED  NULL COMMENT 'survivor incapped by the witch',
    `chase_distance_units` INT UNSIGNED NOT NULL DEFAULT 0,
    PRIMARY KEY (`id`),
    KEY `ix_wr_match` (`match_round_id`),
    CONSTRAINT `fk_wr_server` FOREIGN KEY (`server_id`)
        REFERENCES `servers` (`id`) ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT `fk_wr_map`    FOREIGN KEY (`map_id`)
        REFERENCES `maps`    (`id`) ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT `fk_wr_round`  FOREIGN KEY (`match_round_id`)
        REFERENCES `match_rounds` (`id`) ON DELETE SET NULL ON UPDATE CASCADE,
    CONSTRAINT `fk_wr_startler` FOREIGN KEY (`startled_by_id`)
        REFERENCES `players` (`id`) ON DELETE SET NULL ON UPDATE CASCADE,
    CONSTRAINT `fk_wr_killer` FOREIGN KEY (`killed_by_id`)
        REFERENCES `players` (`id`) ON DELETE SET NULL ON UPDATE CASCADE,
    CONSTRAINT `fk_wr_incapped` FOREIGN KEY (`incapped_id`)
        REFERENCES `players` (`id`) ON DELETE SET NULL ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- -----------------------------------------------------------------------------
-- Crescendo / panic event tracking.
-- -----------------------------------------------------------------------------
CREATE TABLE `crescendo_events` (
    `id`           BIGINT UNSIGNED  NOT NULL AUTO_INCREMENT,
    `server_id`    INT UNSIGNED     NOT NULL,
    `match_round_id` BIGINT UNSIGNED NULL,
    `map_id`       INT UNSIGNED     NOT NULL,
    `kind`         VARCHAR(32)      NOT NULL DEFAULT 'crescendo' COMMENT 'crescendo, gauntlet, holdout',
    `started_at`   DATETIME         NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `ended_at`     DATETIME         NULL,
    `duration_s`   INT UNSIGNED     NOT NULL DEFAULT 0,
    `survivors_down` TINYINT UNSIGNED NOT NULL DEFAULT 0
        COMMENT 'how many survivors were incapped during this event',
    `survivors_died` TINYINT UNSIGNED NOT NULL DEFAULT 0,
    `outcome`      ENUM('cleared','wiped','partial') NOT NULL DEFAULT 'cleared',
    PRIMARY KEY (`id`),
    KEY `ix_ce_map` (`map_id`, `started_at`),
    CONSTRAINT `fk_ce_server` FOREIGN KEY (`server_id`)
        REFERENCES `servers` (`id`) ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT `fk_ce_map`    FOREIGN KEY (`map_id`)
        REFERENCES `maps`    (`id`) ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT `fk_ce_round`  FOREIGN KEY (`match_round_id`)
        REFERENCES `match_rounds` (`id`) ON DELETE SET NULL ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- -----------------------------------------------------------------------------
-- Finale waves.
-- -----------------------------------------------------------------------------
CREATE TABLE `finale_waves` (
    `id`           BIGINT UNSIGNED  NOT NULL AUTO_INCREMENT,
    `server_id`    INT UNSIGNED     NOT NULL,
    `match_round_id` BIGINT UNSIGNED NULL,
    `map_id`       INT UNSIGNED     NOT NULL,
    `wave_number`  TINYINT UNSIGNED NOT NULL,
    `started_at`   DATETIME         NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `ended_at`     DATETIME         NULL,
    `duration_s`   INT UNSIGNED     NOT NULL DEFAULT 0,
    `survivors_alive_start` TINYINT UNSIGNED NOT NULL DEFAULT 4,
    `survivors_alive_end`   TINYINT UNSIGNED NOT NULL DEFAULT 0,
    `outcome`      ENUM('survived','died') NOT NULL DEFAULT 'survived',
    PRIMARY KEY (`id`),
    KEY `ix_fw_map` (`map_id`, `started_at`),
    CONSTRAINT `fk_fw_server` FOREIGN KEY (`server_id`)
        REFERENCES `servers` (`id`) ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT `fk_fw_map`    FOREIGN KEY (`map_id`)
        REFERENCES `maps`    (`id`) ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT `fk_fw_round`  FOREIGN KEY (`match_round_id`)
        REFERENCES `match_rounds` (`id`) ON DELETE SET NULL ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- -----------------------------------------------------------------------------
-- Per-round attribution counters on player_stats.
-- -----------------------------------------------------------------------------
ALTER TABLE `player_stats`
    ADD COLUMN `first_bloods`        INT UNSIGNED NOT NULL DEFAULT 0
        COMMENT 'first kill of a versus round',
    ADD COLUMN `first_downs`         INT UNSIGNED NOT NULL DEFAULT 0
        COMMENT 'first incap of a round (you were the one downed)',
    ADD COLUMN `saferoom_door_closes` INT UNSIGNED NOT NULL DEFAULT 0
        COMMENT 'you closed the saferoom door for the team',
    ADD COLUMN `last_in_safe`        INT UNSIGNED NOT NULL DEFAULT 0
        COMMENT 'you were the last surv to enter the saferoom',
    ADD COLUMN `crescendos_cleared`  INT UNSIGNED NOT NULL DEFAULT 0,
    ADD COLUMN `crescendos_wiped`    INT UNSIGNED NOT NULL DEFAULT 0,
    ADD COLUMN `finale_waves_cleared` INT UNSIGNED NOT NULL DEFAULT 0,
    ADD COLUMN `tank_kill_participations` INT UNSIGNED NOT NULL DEFAULT 0,
    ADD COLUMN `tank_solo_kills`     INT UNSIGNED NOT NULL DEFAULT 0;

-- -----------------------------------------------------------------------------
-- Awards.
-- -----------------------------------------------------------------------------
INSERT IGNORE INTO `awards`
    (`code`, `name`, `description`, `category`, `team`, `game_id`, `is_negative`, `base_points`, `display_order`)
VALUES
    ('first_blood',         'First Blood',          'First kill of the round',                   'survivor', 2, 0, 0, 0, 80),
    ('first_down',          'First Down',           'First survivor incapped this round',        'survivor', 2, 0, 0, 1, 96),
    ('saferoom_save',       'Door Holder',          'Closed the safe room door for the team',    'survivor', 2, 0, 0, 0, 81),
    ('crescendo_cleared',   'Crescendo Cleared',    'Survived a panic event without a death',    'survivor', 2, 0, 0, 0, 82),
    ('finale_wave_survived','Wave Rider',           'Survived a finale wave',                    'survivor', 2, 0, 0, 0, 83),
    ('untouchable_finale',  'Untouchable',          'Finished a finale without taking damage',   'survivor', 2, 0, 0, 0, 84),
    ('untouchable_map',     'Pristine',             'Finished a map without taking damage',      'survivor', 2, 0, 0, 0, 85);

-- -----------------------------------------------------------------------------
-- Views.
-- -----------------------------------------------------------------------------
DROP VIEW IF EXISTS `v_tank_summary`;
CREATE VIEW `v_tank_summary` AS
SELECT
    tr.id,
    tr.server_id,
    tr.match_round_id,
    tr.map_id,
    tr.survival_s,
    tr.distance_units,
    tr.incaps_caused,
    tr.kills_caused,
    tr.outcome,
    CAST(p.name AS CHAR) AS final_controller_name,
    CAST(k.name AS CHAR) AS killer_name,
    tr.killer_weapon
FROM tank_records tr
LEFT JOIN players p ON p.id = tr.final_controller_id
LEFT JOIN players k ON k.id = tr.killer_id;

DROP VIEW IF EXISTS `v_crescendo_stats`;
CREATE VIEW `v_crescendo_stats` AS
SELECT
    map_id,
    COUNT(*)          AS encounters,
    SUM(CASE WHEN outcome='cleared' THEN 1 ELSE 0 END) AS cleared_count,
    SUM(CASE WHEN outcome='wiped'   THEN 1 ELSE 0 END) AS wiped_count,
    ROUND(AVG(duration_s)) AS avg_duration_s
FROM crescendo_events
GROUP BY map_id;

SET FOREIGN_KEY_CHECKS = 1;
