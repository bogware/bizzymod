-- =============================================================================
-- bizzymod-stats — 001_init_schema
-- Catalogs, identity, sessions, servers. Foundation for all stat tables.
-- =============================================================================

SET NAMES utf8mb4;
SET FOREIGN_KEY_CHECKS = 0;

-- -----------------------------------------------------------------------------
-- schema_migrations: tracks which numbered migrations have been applied.
-- The runner populates this; do not write to it manually.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `schema_migrations` (
    `version`     VARCHAR(64) NOT NULL,
    `applied_at`  DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `checksum`    CHAR(64)    NOT NULL,
    PRIMARY KEY (`version`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- -----------------------------------------------------------------------------
-- Catalog: game (L4D1 vs L4D2). Plugin sets this from engine detection.
-- -----------------------------------------------------------------------------
CREATE TABLE `games` (
    `id`   TINYINT UNSIGNED NOT NULL,
    `code` VARCHAR(16)      NOT NULL,
    `name` VARCHAR(64)      NOT NULL,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_games_code` (`code`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- -----------------------------------------------------------------------------
-- Catalog: gamemode. Numeric IDs match the plugin's GAMEMODE_* defines so
-- they remain wire-compatible with anything reading legacy data.
-- -----------------------------------------------------------------------------
CREATE TABLE `gamemodes` (
    `id`   TINYINT UNSIGNED NOT NULL,
    `code` VARCHAR(32)      NOT NULL,
    `name` VARCHAR(64)      NOT NULL,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_gamemodes_code` (`code`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- -----------------------------------------------------------------------------
-- Catalog: difficulty.
-- -----------------------------------------------------------------------------
CREATE TABLE `difficulties` (
    `id`         TINYINT UNSIGNED NOT NULL,
    `code`       VARCHAR(16)      NOT NULL,
    `name`       VARCHAR(32)      NOT NULL,
    `multiplier` DECIMAL(4, 2)    NOT NULL DEFAULT 1.00,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_difficulties_code` (`code`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- -----------------------------------------------------------------------------
-- Catalog: special infected. ID space is shared across L4D1+L4D2.
-- -----------------------------------------------------------------------------
CREATE TABLE `special_infected` (
    `id`         TINYINT UNSIGNED NOT NULL,
    `code`       VARCHAR(16)      NOT NULL,
    `name`       VARCHAR(32)      NOT NULL,
    `game_id`    TINYINT UNSIGNED NOT NULL DEFAULT 0,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_si_code` (`code`),
    CONSTRAINT `fk_si_game` FOREIGN KEY (`game_id`)
        REFERENCES `games` (`id`) ON DELETE RESTRICT ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- -----------------------------------------------------------------------------
-- Catalog: weapons. Populated from configs/weapons.cfg at install time, and
-- auto-extended at runtime for any unknown weapon seen in damage events.
-- -----------------------------------------------------------------------------
CREATE TABLE `weapons` (
    `id`           SMALLINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `code`         VARCHAR(64)       NOT NULL,
    `display_name` VARCHAR(96)       NULL,
    `slot`         TINYINT UNSIGNED  NULL COMMENT '0=primary,1=secondary,2=throwable,3=melee,4=other',
    `game_id`      TINYINT UNSIGNED  NOT NULL DEFAULT 0,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_weapons_code` (`code`),
    CONSTRAINT `fk_weapons_game` FOREIGN KEY (`game_id`)
        REFERENCES `games` (`id`) ON DELETE RESTRICT ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- -----------------------------------------------------------------------------
-- Servers: one row per game server reporting stats. Lets a single DB
-- service many servers; queries roll up across rows for global views.
-- -----------------------------------------------------------------------------
CREATE TABLE `servers` (
    `id`         INT UNSIGNED      NOT NULL AUTO_INCREMENT,
    `key`        CHAR(32)          NOT NULL COMMENT 'random token the plugin presents to identify itself',
    `name`       VARCHAR(128)      NOT NULL,
    `address`    VARCHAR(64)       NULL COMMENT 'last seen public address:port',
    `game_id`    TINYINT UNSIGNED  NOT NULL,
    `first_seen` DATETIME          NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `last_seen`  DATETIME          NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_servers_key` (`key`),
    KEY `ix_servers_last_seen` (`last_seen`),
    CONSTRAINT `fk_servers_game` FOREIGN KEY (`game_id`)
        REFERENCES `games` (`id`) ON DELETE RESTRICT ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- -----------------------------------------------------------------------------
-- Players: identity. The legacy `players` table mixed identity with stats;
-- here it holds only identity + last-seen metadata. Stats live elsewhere
-- and join via `player_id`.
-- -----------------------------------------------------------------------------
CREATE TABLE `players` (
    `id`             BIGINT UNSIGNED   NOT NULL AUTO_INCREMENT,
    `steamid`        VARCHAR(32)       NOT NULL COMMENT 'STEAM_X:Y:Z form, or IP for LAN',
    `steamid64`      BIGINT UNSIGNED   NULL COMMENT '64-bit community ID, populated when known',
    `name`           VARBINARY(255)    NOT NULL COMMENT 'most recent in-game name; raw bytes to survive non-UTF8 nicks',
    `country_code`   CHAR(2)           NULL,
    `last_ip`        VARBINARY(16)     NULL COMMENT 'packed IPv4 or IPv6, NULL if not collected',
    `first_seen`     DATETIME          NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `last_seen`      DATETIME          NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `last_gamemode`  TINYINT UNSIGNED  NULL,
    `last_server_id` INT UNSIGNED      NULL,
    `is_lan`         TINYINT(1)        NOT NULL DEFAULT 0,
    `is_banned`      TINYINT(1)        NOT NULL DEFAULT 0,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_players_steamid` (`steamid`),
    KEY `ix_players_steamid64` (`steamid64`),
    KEY `ix_players_last_seen` (`last_seen`),
    KEY `ix_players_country` (`country_code`),
    CONSTRAINT `fk_players_last_server` FOREIGN KEY (`last_server_id`)
        REFERENCES `servers` (`id`) ON DELETE SET NULL ON UPDATE CASCADE,
    CONSTRAINT `fk_players_last_gamemode` FOREIGN KEY (`last_gamemode`)
        REFERENCES `gamemodes` (`id`) ON DELETE SET NULL ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- -----------------------------------------------------------------------------
-- Sessions: one row per (player, server, connect..disconnect). Provides the
-- foundation for PPM, session leaderboards, last-N analysis, and per-session
-- drill-down without polluting the rollup tables.
-- -----------------------------------------------------------------------------
CREATE TABLE `sessions` (
    `id`            BIGINT UNSIGNED   NOT NULL AUTO_INCREMENT,
    `player_id`     BIGINT UNSIGNED   NOT NULL,
    `server_id`     INT UNSIGNED      NOT NULL,
    `gamemode_id`   TINYINT UNSIGNED  NOT NULL,
    `difficulty_id` TINYINT UNSIGNED  NOT NULL,
    `map_id`        INT UNSIGNED      NULL,
    `started_at`    DATETIME          NOT NULL,
    `ended_at`      DATETIME          NULL,
    `duration_s`    INT UNSIGNED      NOT NULL DEFAULT 0,
    `points`        INT               NOT NULL DEFAULT 0 COMMENT 'signed; negatives valid',
    `kills`         INT UNSIGNED      NOT NULL DEFAULT 0,
    `deaths`        INT UNSIGNED      NOT NULL DEFAULT 0,
    `team`          TINYINT UNSIGNED  NULL COMMENT '2=survivor,3=infected',
    PRIMARY KEY (`id`),
    KEY `ix_sessions_player` (`player_id`, `started_at`),
    KEY `ix_sessions_server_started` (`server_id`, `started_at`),
    KEY `ix_sessions_open` (`ended_at`),
    CONSTRAINT `fk_sessions_player` FOREIGN KEY (`player_id`)
        REFERENCES `players` (`id`) ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT `fk_sessions_server` FOREIGN KEY (`server_id`)
        REFERENCES `servers` (`id`) ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT `fk_sessions_gamemode` FOREIGN KEY (`gamemode_id`)
        REFERENCES `gamemodes` (`id`) ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT `fk_sessions_difficulty` FOREIGN KEY (`difficulty_id`)
        REFERENCES `difficulties` (`id`) ON DELETE RESTRICT ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- -----------------------------------------------------------------------------
-- Maps: catalog. One row per map name; per-difficulty rollups live in
-- map_stats and per-play records in map_plays.
-- -----------------------------------------------------------------------------
CREATE TABLE `maps` (
    `id`           INT UNSIGNED      NOT NULL AUTO_INCREMENT,
    `code`         VARCHAR(128)      NOT NULL,
    `display_name` VARCHAR(192)      NULL,
    `campaign`     VARCHAR(96)       NULL,
    `chapter`      TINYINT UNSIGNED  NULL,
    `is_finale`    TINYINT(1)        NOT NULL DEFAULT 0,
    `is_custom`    TINYINT(1)        NOT NULL DEFAULT 0,
    `game_id`      TINYINT UNSIGNED  NOT NULL,
    `first_seen`   DATETIME          NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_maps_code_game` (`code`, `game_id`),
    KEY `ix_maps_campaign` (`campaign`),
    CONSTRAINT `fk_maps_game` FOREIGN KEY (`game_id`)
        REFERENCES `games` (`id`) ON DELETE RESTRICT ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- -----------------------------------------------------------------------------
-- Per-player settings (mute, opt-outs, preferences).
-- -----------------------------------------------------------------------------
CREATE TABLE `player_settings` (
    `player_id` BIGINT UNSIGNED NOT NULL,
    `key`       VARCHAR(48)     NOT NULL,
    `value`     VARCHAR(255)    NOT NULL,
    PRIMARY KEY (`player_id`, `key`),
    CONSTRAINT `fk_psettings_player` FOREIGN KEY (`player_id`)
        REFERENCES `players` (`id`) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- -----------------------------------------------------------------------------
-- Global key/value store. Replaces the legacy `server_settings` table.
-- -----------------------------------------------------------------------------
CREATE TABLE `kv_settings` (
    `scope`     ENUM('global', 'server') NOT NULL DEFAULT 'global',
    `scope_id`  INT UNSIGNED             NOT NULL DEFAULT 0,
    `key`       VARCHAR(64)              NOT NULL,
    `value`     BLOB                     NULL,
    `updated_at` DATETIME                NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (`scope`, `scope_id`, `key`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

SET FOREIGN_KEY_CHECKS = 1;
