-- =============================================================================
-- bizzymod-stats — 014_versus_deep_dive
--
-- Roadmap §7: Versus/scavenge deep additions. SI spawn timing, ghost time,
-- death-cause breakdown, side preference, scavenge per-gascan, director
-- placements, character distribution.
-- =============================================================================

SET NAMES utf8mb4;
SET FOREIGN_KEY_CHECKS = 0;

-- -----------------------------------------------------------------------------
-- Per-round per-player versus aggregates: SI spawn timing, ghost time,
-- death cause counts.
-- -----------------------------------------------------------------------------
ALTER TABLE `player_round_stats`
    ADD COLUMN `si_spawns_total_wait_s` INT UNSIGNED NOT NULL DEFAULT 0
        COMMENT 'cumulative seconds waiting to spawn',
    ADD COLUMN `si_spawns_count`        INT UNSIGNED NOT NULL DEFAULT 0,
    ADD COLUMN `ghost_time_s`           INT UNSIGNED NOT NULL DEFAULT 0
        COMMENT 'time in ghost state before materializing (requires L4D2H ext)',
    ADD COLUMN `ghost_distance_units`   BIGINT UNSIGNED NOT NULL DEFAULT 0
        COMMENT 'distance traveled while ghosting (requires L4D2H ext)',
    ADD COLUMN `died_by_melee`          TINYINT UNSIGNED NOT NULL DEFAULT 0,
    ADD COLUMN `died_by_gun`            TINYINT UNSIGNED NOT NULL DEFAULT 0,
    ADD COLUMN `died_by_fire`           TINYINT UNSIGNED NOT NULL DEFAULT 0,
    ADD COLUMN `died_by_fall`           TINYINT UNSIGNED NOT NULL DEFAULT 0,
    ADD COLUMN `died_by_world`          TINYINT UNSIGNED NOT NULL DEFAULT 0;

-- -----------------------------------------------------------------------------
-- Survivor character distribution. Catalog + per-player tally.
-- -----------------------------------------------------------------------------
CREATE TABLE `survivors` (
    `id`      TINYINT UNSIGNED NOT NULL,
    `code`    VARCHAR(16)      NOT NULL,
    `name`    VARCHAR(32)      NOT NULL,
    `game_id` TINYINT UNSIGNED NOT NULL,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_surv_code` (`code`),
    CONSTRAINT `fk_surv_game` FOREIGN KEY (`game_id`)
        REFERENCES `games` (`id`) ON DELETE RESTRICT ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

INSERT IGNORE INTO `survivors` (`id`, `code`, `name`, `game_id`) VALUES
    (1, 'bill',     'Bill',     1),
    (2, 'francis',  'Francis',  1),
    (3, 'louis',    'Louis',    1),
    (4, 'zoey',     'Zoey',     1),
    (5, 'nick',     'Nick',     2),
    (6, 'coach',    'Coach',    2),
    (7, 'ellis',    'Ellis',    2),
    (8, 'rochelle', 'Rochelle', 2);

CREATE TABLE `player_character_stats` (
    `player_id`    BIGINT UNSIGNED  NOT NULL,
    `survivor_id`  TINYINT UNSIGNED NOT NULL,
    `sessions`     INT UNSIGNED     NOT NULL DEFAULT 0,
    `playtime_s`   INT UNSIGNED     NOT NULL DEFAULT 0,
    `points`       INT              NOT NULL DEFAULT 0,
    `wins`         INT UNSIGNED     NOT NULL DEFAULT 0,
    `losses`       INT UNSIGNED     NOT NULL DEFAULT 0,
    `last_played_at` DATETIME       NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (`player_id`, `survivor_id`),
    CONSTRAINT `fk_pcs_player` FOREIGN KEY (`player_id`)
        REFERENCES `players` (`id`) ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT `fk_pcs_surv` FOREIGN KEY (`survivor_id`)
        REFERENCES `survivors` (`id`) ON DELETE RESTRICT ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- -----------------------------------------------------------------------------
-- Scavenge per-gascan: one row per individual gas can pour event.
-- -----------------------------------------------------------------------------
CREATE TABLE `scavenge_gascans` (
    `id`             BIGINT UNSIGNED  NOT NULL AUTO_INCREMENT,
    `match_round_id` BIGINT UNSIGNED  NOT NULL,
    `pourer_id`      BIGINT UNSIGNED  NOT NULL,
    `gascan_seq`     TINYINT UNSIGNED NOT NULL COMMENT 'ordinal within the round',
    `started_at`     DATETIME         NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `completed_at`   DATETIME         NULL,
    `interrupted`    TINYINT(1)       NOT NULL DEFAULT 0,
    `pour_duration_s` INT UNSIGNED    NOT NULL DEFAULT 0,
    PRIMARY KEY (`id`),
    KEY `ix_sg_round` (`match_round_id`, `gascan_seq`),
    KEY `ix_sg_pourer` (`pourer_id`),
    CONSTRAINT `fk_sg_round`  FOREIGN KEY (`match_round_id`)
        REFERENCES `match_rounds` (`id`) ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT `fk_sg_pourer` FOREIGN KEY (`pourer_id`)
        REFERENCES `players` (`id`) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- -----------------------------------------------------------------------------
-- Director boss placements: where on a map did the engine spawn the
-- tank / witch. Position is XYZ in game units. Drives map heatmaps.
-- -----------------------------------------------------------------------------
CREATE TABLE `director_placements` (
    `id`             BIGINT UNSIGNED  NOT NULL AUTO_INCREMENT,
    `server_id`      INT UNSIGNED     NOT NULL,
    `map_id`         INT UNSIGNED     NOT NULL,
    `match_round_id` BIGINT UNSIGNED  NULL,
    `boss_kind`      ENUM('tank','witch') NOT NULL,
    `pos_x`          INT              NOT NULL DEFAULT 0,
    `pos_y`          INT              NOT NULL DEFAULT 0,
    `pos_z`          INT              NOT NULL DEFAULT 0,
    `placed_at`      DATETIME         NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `ix_dp_map_kind` (`map_id`, `boss_kind`, `placed_at`),
    CONSTRAINT `fk_dp_server` FOREIGN KEY (`server_id`)
        REFERENCES `servers` (`id`) ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT `fk_dp_map`    FOREIGN KEY (`map_id`)
        REFERENCES `maps`    (`id`) ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT `fk_dp_round`  FOREIGN KEY (`match_round_id`)
        REFERENCES `match_rounds` (`id`) ON DELETE SET NULL ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- -----------------------------------------------------------------------------
-- Mercy round / time bonus tracking on match_rounds.
-- -----------------------------------------------------------------------------
ALTER TABLE `match_rounds`
    ADD COLUMN `mercy_time_bonus`  INT NOT NULL DEFAULT 0
        COMMENT 'engine time bonus awarded at end of round',
    ADD COLUMN `health_bonus`      INT NOT NULL DEFAULT 0;

-- -----------------------------------------------------------------------------
-- Awards.
-- -----------------------------------------------------------------------------
INSERT IGNORE INTO `awards`
    (`code`, `name`, `description`, `category`, `team`, `game_id`, `is_negative`, `base_points`, `display_order`)
VALUES
    ('character_main',  'Character Main',  'Played 50+ sessions as one character',  'survivor', 2, 0, 0, 0, 86),
    ('gascan_anchor',   'Gascan Anchor',   'Poured 3+ gascans in one round',         'survivor', 2, 2, 0, 0, 87),
    ('gascan_defender', 'Gascan Defender', 'Killed an SI mid-pour as the pourer',    'survivor', 2, 2, 0, 0, 88),
    ('side_specialist', 'Side Specialist', '70%+ win rate on one team letter',       'versus',   2, 0, 0, 0, 89);

-- -----------------------------------------------------------------------------
-- Views.
-- -----------------------------------------------------------------------------
DROP VIEW IF EXISTS `v_player_character_pref`;
CREATE VIEW `v_player_character_pref` AS
SELECT
    pcs.player_id,
    s.code     AS character_code,
    s.name     AS character_name,
    pcs.sessions,
    pcs.playtime_s,
    pcs.wins,
    pcs.losses,
    CASE WHEN (pcs.wins + pcs.losses) > 0
         THEN ROUND(100.0 * pcs.wins / (pcs.wins + pcs.losses), 2)
         ELSE 0 END AS winrate_pct
FROM player_character_stats pcs
JOIN survivors s ON s.id = pcs.survivor_id;

DROP VIEW IF EXISTS `v_match_score_curve`;
CREATE VIEW `v_match_score_curve` AS
SELECT
    mm.match_id,
    mm.ordinal AS map_index,
    mm.team_a_score,
    mm.team_b_score,
    SUM(mm.team_a_score) OVER (PARTITION BY mm.match_id ORDER BY mm.ordinal) AS running_a,
    SUM(mm.team_b_score) OVER (PARTITION BY mm.match_id ORDER BY mm.ordinal) AS running_b
FROM match_maps mm;

DROP VIEW IF EXISTS `v_match_comebacks`;
CREATE VIEW `v_match_comebacks` AS
-- A "comeback" = winner was behind by >=500 at some point in the match.
SELECT
    sc.match_id,
    m.winner,
    MAX(sc.running_a - sc.running_b) AS max_a_lead,
    MAX(sc.running_b - sc.running_a) AS max_b_lead,
    CASE
        WHEN m.winner = 'A' AND MAX(sc.running_b - sc.running_a) >= 500 THEN TRUE
        WHEN m.winner = 'B' AND MAX(sc.running_a - sc.running_b) >= 500 THEN TRUE
        ELSE FALSE
    END AS is_comeback
FROM v_match_score_curve sc
JOIN matches m ON m.id = sc.match_id
GROUP BY sc.match_id, m.winner;

DROP VIEW IF EXISTS `v_side_preference`;
CREATE VIEW `v_side_preference` AS
SELECT
    mtp.player_id,
    mtp.team_letter,
    COUNT(DISTINCT mtp.match_id) AS matches_played,
    SUM(CASE WHEN m.winner = mtp.team_letter THEN 1 ELSE 0 END) AS wins,
    SUM(CASE WHEN m.winner IN ('A','B') AND m.winner != mtp.team_letter THEN 1 ELSE 0 END) AS losses,
    ROUND(100.0 * SUM(CASE WHEN m.winner = mtp.team_letter THEN 1 ELSE 0 END)
                / NULLIF(COUNT(DISTINCT mtp.match_id), 0), 2) AS winrate_pct
FROM match_team_players mtp
JOIN matches m ON m.id = mtp.match_id
WHERE m.winner IN ('A','B','draw')
GROUP BY mtp.player_id, mtp.team_letter;

SET FOREIGN_KEY_CHECKS = 1;
