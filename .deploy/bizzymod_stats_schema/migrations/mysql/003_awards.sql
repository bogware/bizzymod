-- =============================================================================
-- bizzymod-stats — 003_awards
-- Awards as data, not columns. The legacy `players` table had 30+ `award_*`
-- INT columns; here awards live in a catalog and `player_awards` records
-- counts per (player, award). New awards = INSERT into the catalog.
-- =============================================================================

SET NAMES utf8mb4;
SET FOREIGN_KEY_CHECKS = 0;

CREATE TABLE `awards` (
    `id`           SMALLINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `code`         VARCHAR(64)       NOT NULL,
    `name`         VARCHAR(96)       NOT NULL,
    `description`  VARCHAR(255)      NULL,
    `category`     VARCHAR(32)       NOT NULL DEFAULT 'general'
        COMMENT 'survivor, infected, finale, ff, special',
    `team`         TINYINT UNSIGNED  NULL COMMENT '2=survivor, 3=infected, NULL=both',
    `game_id`      TINYINT UNSIGNED  NOT NULL DEFAULT 0 COMMENT '0=both games',
    `is_negative`  TINYINT(1)        NOT NULL DEFAULT 0 COMMENT 'true if it counts against the player',
    `base_points`  INT               NOT NULL DEFAULT 0,
    `display_order` SMALLINT UNSIGNED NOT NULL DEFAULT 100,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_awards_code` (`code`),
    KEY `ix_awards_category` (`category`),
    CONSTRAINT `fk_awards_game` FOREIGN KEY (`game_id`)
        REFERENCES `games` (`id`) ON DELETE RESTRICT ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- -----------------------------------------------------------------------------
-- player_awards: per-player count of each award earned.
-- gamemode_id is included so a single award can be tracked per gamemode
-- (e.g. "Witch Crowner" in coop vs versus look different in the leaderboards).
-- -----------------------------------------------------------------------------
CREATE TABLE `player_awards` (
    `player_id`   BIGINT UNSIGNED   NOT NULL,
    `award_id`    SMALLINT UNSIGNED NOT NULL,
    `gamemode_id` TINYINT UNSIGNED  NOT NULL DEFAULT 0 COMMENT '0 = aggregated',
    `count`       INT UNSIGNED      NOT NULL DEFAULT 0,
    `first_at`    DATETIME          NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `last_at`     DATETIME          NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (`player_id`, `award_id`, `gamemode_id`),
    KEY `ix_pawards_award_count` (`award_id`, `count` DESC),
    CONSTRAINT `fk_pawards_player` FOREIGN KEY (`player_id`)
        REFERENCES `players` (`id`) ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT `fk_pawards_award` FOREIGN KEY (`award_id`)
        REFERENCES `awards` (`id`) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- -----------------------------------------------------------------------------
-- award_events: optional firehose of award occurrences. Lets the web UI
-- render an activity feed ("just earned X"). Toggle via plugin CVAR.
-- -----------------------------------------------------------------------------
CREATE TABLE `award_events` (
    `id`         BIGINT UNSIGNED   NOT NULL AUTO_INCREMENT,
    `player_id`  BIGINT UNSIGNED   NOT NULL,
    `award_id`   SMALLINT UNSIGNED NOT NULL,
    `server_id`  INT UNSIGNED      NOT NULL,
    `session_id` BIGINT UNSIGNED   NULL,
    `points`     INT               NOT NULL DEFAULT 0,
    `at`         DATETIME          NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `ix_aevents_player_at` (`player_id`, `at`),
    KEY `ix_aevents_at` (`at`),
    CONSTRAINT `fk_aevents_player` FOREIGN KEY (`player_id`)
        REFERENCES `players` (`id`) ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT `fk_aevents_award` FOREIGN KEY (`award_id`)
        REFERENCES `awards` (`id`) ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT `fk_aevents_server` FOREIGN KEY (`server_id`)
        REFERENCES `servers` (`id`) ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT `fk_aevents_session` FOREIGN KEY (`session_id`)
        REFERENCES `sessions` (`id`) ON DELETE SET NULL ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

SET FOREIGN_KEY_CHECKS = 1;
