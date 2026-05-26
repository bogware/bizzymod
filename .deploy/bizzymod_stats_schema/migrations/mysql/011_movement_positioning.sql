-- =============================================================================
-- bizzymod-stats — 011_movement_positioning
--
-- Roadmap §4: Movement, positioning, traversal. Backed by an OnGameFrame
-- sampler that walks alive survivors at 4 Hz and accumulates deltas.
-- =============================================================================

SET NAMES utf8mb4;
SET FOREIGN_KEY_CHECKS = 0;

-- -----------------------------------------------------------------------------
-- Per-session/gamemode movement rollups.
-- -----------------------------------------------------------------------------
ALTER TABLE `player_stats`
    -- We already have distance_units from migration 007; flesh it out
    ADD COLUMN `time_alone_s`           INT UNSIGNED NOT NULL DEFAULT 0
        COMMENT 'seconds spent farther than the LONE_THRESHOLD from nearest teammate',
    ADD COLUMN `time_leading_s`         INT UNSIGNED NOT NULL DEFAULT 0
        COMMENT 'seconds as the furthest-forward survivor',
    ADD COLUMN `time_trailing_s`        INT UNSIGNED NOT NULL DEFAULT 0
        COMMENT 'seconds as the furthest-back survivor',
    ADD COLUMN `breaks_from_group`      INT UNSIGNED NOT NULL DEFAULT 0
        COMMENT 'transitions into "alone" state',
    ADD COLUMN `fall_damage_taken`      BIGINT UNSIGNED NOT NULL DEFAULT 0,
    ADD COLUMN `max_team_spread_units`  INT UNSIGNED NOT NULL DEFAULT 0
        COMMENT 'session peak of max-pairwise distance among teammates',
    ADD COLUMN `avg_team_spread_units`  INT UNSIGNED NOT NULL DEFAULT 0
        COMMENT 'rolling average (samples-weighted) across the session';

-- -----------------------------------------------------------------------------
-- Saferoom arrival ordering. One row per (map_play, player); records the
-- order they entered the saferoom (1 = first, 4 = last). Drives the
-- "always first / always last" leaderboards.
-- -----------------------------------------------------------------------------
CREATE TABLE `saferoom_arrivals` (
    `id`         BIGINT UNSIGNED   NOT NULL AUTO_INCREMENT,
    `server_id`  INT UNSIGNED      NOT NULL,
    `player_id`  BIGINT UNSIGNED   NOT NULL,
    `map_id`     INT UNSIGNED      NOT NULL,
    `match_id`   BIGINT UNSIGNED   NULL,
    `arrived_at` DATETIME          NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `order_idx`  TINYINT UNSIGNED  NOT NULL COMMENT '1..N within the saferoom event',
    `hp_at_arrival` TINYINT UNSIGNED NOT NULL DEFAULT 0,
    PRIMARY KEY (`id`),
    KEY `ix_sra_player` (`player_id`, `arrived_at`),
    KEY `ix_sra_map`    (`map_id`),
    CONSTRAINT `fk_sra_server` FOREIGN KEY (`server_id`)
        REFERENCES `servers` (`id`) ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT `fk_sra_player` FOREIGN KEY (`player_id`)
        REFERENCES `players` (`id`) ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT `fk_sra_map` FOREIGN KEY (`map_id`)
        REFERENCES `maps` (`id`) ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT `fk_sra_match` FOREIGN KEY (`match_id`)
        REFERENCES `matches` (`id`) ON DELETE SET NULL ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- -----------------------------------------------------------------------------
-- Awards.
-- -----------------------------------------------------------------------------
INSERT IGNORE INTO `awards`
    (`code`, `name`, `description`, `category`, `team`, `game_id`, `is_negative`, `base_points`, `display_order`)
VALUES
    ('lone_wolf',    'Lone Wolf',     'Spent the most time alone in a session',    'survivor', 2, 0, 0, 0, 71),
    ('pointman',     'Pointman',      'Spent the most time leading the group',     'survivor', 2, 0, 0, 0, 72),
    ('trailblazer',  'Trailblazer',   'Most distance traveled in a session',       'survivor', 2, 0, 0, 0, 73),
    ('first_in',     'First In',      'First to a saferoom on 10+ maps',           'survivor', 2, 0, 0, 0, 74),
    ('last_in',      'Last In',       'Last to a saferoom on 10+ maps (door-holder)', 'survivor', 2, 0, 0, 0, 75),
    ('lemming',      'Lemming',       'Died from a fall',                          'survivor', 2, 0, 0, 1, 95);

-- -----------------------------------------------------------------------------
-- View: arrival-order stats per player.
-- -----------------------------------------------------------------------------
DROP VIEW IF EXISTS `v_saferoom_order`;
CREATE VIEW `v_saferoom_order` AS
SELECT
    player_id,
    COUNT(*) AS total_arrivals,
    SUM(CASE WHEN order_idx = 1 THEN 1 ELSE 0 END) AS first_arrivals,
    SUM(CASE WHEN order_idx = 1 THEN 1 ELSE 0 END) * 100.0 / COUNT(*) AS first_pct,
    AVG(order_idx) AS avg_order,
    ROUND(AVG(hp_at_arrival)) AS avg_hp_at_arrival
FROM saferoom_arrivals
GROUP BY player_id;

SET FOREIGN_KEY_CHECKS = 1;
