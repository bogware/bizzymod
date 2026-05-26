-- =============================================================================
-- bizzymod-stats — 002_stat_tables
-- Rollup stats. Each table normalizes on (player_id, gamemode, difficulty)
-- instead of the legacy approach of one wide table with per-mode columns.
-- =============================================================================

SET NAMES utf8mb4;
SET FOREIGN_KEY_CHECKS = 0;

-- -----------------------------------------------------------------------------
-- player_stats: the core rollup. One row per (player, gamemode, difficulty).
-- Replaces ~80 columns of the legacy `players` table.
--
-- Survivor- and infected-side counters live in the same row because most
-- gamemodes only use one side; querying for the other is a NULL or zero.
-- Use views (see 005_views) for "all gamemodes combined" rollups.
-- -----------------------------------------------------------------------------
CREATE TABLE `player_stats` (
    `player_id`     BIGINT UNSIGNED   NOT NULL,
    `gamemode_id`   TINYINT UNSIGNED  NOT NULL,
    `difficulty_id` TINYINT UNSIGNED  NOT NULL DEFAULT 0,
    `server_id`     INT UNSIGNED      NOT NULL DEFAULT 0 COMMENT '0 = aggregated across all servers',

    -- Headline counters
    `points`            INT          NOT NULL DEFAULT 0 COMMENT 'signed',
    `playtime_s`        INT UNSIGNED NOT NULL DEFAULT 0,
    `sessions`          INT UNSIGNED NOT NULL DEFAULT 0,
    `maps_completed`    INT UNSIGNED NOT NULL DEFAULT 0,
    `campaigns_finished` INT UNSIGNED NOT NULL DEFAULT 0,
    `wins`              INT UNSIGNED NOT NULL DEFAULT 0,
    `losses`            INT UNSIGNED NOT NULL DEFAULT 0,

    -- Combat (survivor side)
    `shots_fired`       INT UNSIGNED NOT NULL DEFAULT 0,
    `shots_hit`         INT UNSIGNED NOT NULL DEFAULT 0,
    `headshots`         INT UNSIGNED NOT NULL DEFAULT 0,
    `damage_dealt`      BIGINT UNSIGNED NOT NULL DEFAULT 0,
    `damage_taken`      BIGINT UNSIGNED NOT NULL DEFAULT 0,
    `damage_friendly`   BIGINT UNSIGNED NOT NULL DEFAULT 0,
    `damage_friendly_taken` BIGINT UNSIGNED NOT NULL DEFAULT 0,
    `kills_common`      INT UNSIGNED NOT NULL DEFAULT 0,
    `kills_uncommon`    INT UNSIGNED NOT NULL DEFAULT 0 COMMENT 'L4D2 uncommon variants',
    `kills_witch`       INT UNSIGNED NOT NULL DEFAULT 0,
    `kills_tank`        INT UNSIGNED NOT NULL DEFAULT 0,
    `kills_special`     INT UNSIGNED NOT NULL DEFAULT 0,
    `kills_melee`       INT UNSIGNED NOT NULL DEFAULT 0,
    `kills_survivor`    INT UNSIGNED NOT NULL DEFAULT 0 COMMENT 'as infected, kills against survivor team',

    -- Self/health
    `incaps`            INT UNSIGNED NOT NULL DEFAULT 0,
    `incaps_taken`      INT UNSIGNED NOT NULL DEFAULT 0,
    `deaths`            INT UNSIGNED NOT NULL DEFAULT 0,
    `revives`           INT UNSIGNED NOT NULL DEFAULT 0,
    `revives_received`  INT UNSIGNED NOT NULL DEFAULT 0,
    `pills_taken`       INT UNSIGNED NOT NULL DEFAULT 0,
    `pills_given`       INT UNSIGNED NOT NULL DEFAULT 0,
    `adrenaline_taken`  INT UNSIGNED NOT NULL DEFAULT 0,
    `adrenaline_given`  INT UNSIGNED NOT NULL DEFAULT 0,
    `medkits_used`      INT UNSIGNED NOT NULL DEFAULT 0,
    `medkits_used_on_other` INT UNSIGNED NOT NULL DEFAULT 0,
    `defibs_used`       INT UNSIGNED NOT NULL DEFAULT 0,

    -- Friendly fire / discipline
    `ff_incidents`      INT UNSIGNED NOT NULL DEFAULT 0,
    `teamkills`         INT UNSIGNED NOT NULL DEFAULT 0,
    `teamkills_taken`   INT UNSIGNED NOT NULL DEFAULT 0,

    -- Game-flow (survivor)
    `safe_room_reaches` INT UNSIGNED NOT NULL DEFAULT 0,
    `safe_room_lefts`   INT UNSIGNED NOT NULL DEFAULT 0,

    -- L4D2 specific actions
    `gascans_poured`    INT UNSIGNED NOT NULL DEFAULT 0,
    `gascans_partial`   INT UNSIGNED NOT NULL DEFAULT 0 COMMENT 'pours interrupted before completion',
    `ammo_upgrades_deployed` INT UNSIGNED NOT NULL DEFAULT 0,
    `caralarms_triggered` INT UNSIGNED NOT NULL DEFAULT 0,

    -- Specialized rescue actions
    `saved_from_smoker` INT UNSIGNED NOT NULL DEFAULT 0,
    `saved_from_hunter` INT UNSIGNED NOT NULL DEFAULT 0,
    `saved_from_jockey` INT UNSIGNED NOT NULL DEFAULT 0,
    `saved_from_charger_pummel` INT UNSIGNED NOT NULL DEFAULT 0,
    `saved_from_charger_carry`  INT UNSIGNED NOT NULL DEFAULT 0,
    `saved_from_ledge`  INT UNSIGNED NOT NULL DEFAULT 0,

    -- Computed-at-query: ppm via view; skill/accuracy via view.

    PRIMARY KEY (`player_id`, `gamemode_id`, `difficulty_id`, `server_id`),
    KEY `ix_pstats_points` (`gamemode_id`, `points` DESC),
    KEY `ix_pstats_playtime` (`gamemode_id`, `playtime_s` DESC),
    CONSTRAINT `fk_pstats_player` FOREIGN KEY (`player_id`)
        REFERENCES `players` (`id`) ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT `fk_pstats_gamemode` FOREIGN KEY (`gamemode_id`)
        REFERENCES `gamemodes` (`id`) ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT `fk_pstats_difficulty` FOREIGN KEY (`difficulty_id`)
        REFERENCES `difficulties` (`id`) ON DELETE RESTRICT ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- -----------------------------------------------------------------------------
-- player_si_stats: per-special-infected stats. Replaces the 8+ pairs of
-- `infected_<si>_*` columns in the legacy schema.
-- -----------------------------------------------------------------------------
CREATE TABLE `player_si_stats` (
    `player_id`     BIGINT UNSIGNED   NOT NULL,
    `gamemode_id`   TINYINT UNSIGNED  NOT NULL,
    `si_id`         TINYINT UNSIGNED  NOT NULL,

    `spawns`            INT UNSIGNED NOT NULL DEFAULT 0,
    `playtime_s`        INT UNSIGNED NOT NULL DEFAULT 0,
    `damage_dealt`      BIGINT UNSIGNED NOT NULL DEFAULT 0,
    `damage_external`   BIGINT UNSIGNED NOT NULL DEFAULT 0 COMMENT 'damage attributed via CI under SI influence',
    `incaps_caused`     INT UNSIGNED NOT NULL DEFAULT 0,
    `kills_caused`      INT UNSIGNED NOT NULL DEFAULT 0,
    `survivors_pinned`  INT UNSIGNED NOT NULL DEFAULT 0,
    `deaths`            INT UNSIGNED NOT NULL DEFAULT 0,

    -- SI-specific (use only the columns relevant to each SI; NULL/0 otherwise)
    `boomer_vomits`        INT UNSIGNED NOT NULL DEFAULT 0,
    `boomer_blinds`        INT UNSIGNED NOT NULL DEFAULT 0,
    `boomer_perfect_vomits` INT UNSIGNED NOT NULL DEFAULT 0,
    `hunter_pounces`       INT UNSIGNED NOT NULL DEFAULT 0,
    `hunter_perfect_pounces` INT UNSIGNED NOT NULL DEFAULT 0,
    `hunter_nice_pounces`  INT UNSIGNED NOT NULL DEFAULT 0,
    `hunter_pounce_damage` BIGINT UNSIGNED NOT NULL DEFAULT 0,
    `smoker_pulls`         INT UNSIGNED NOT NULL DEFAULT 0,
    `smoker_choke_damage`  BIGINT UNSIGNED NOT NULL DEFAULT 0,
    `jockey_rides`         INT UNSIGNED NOT NULL DEFAULT 0,
    `jockey_ride_time_s`   INT UNSIGNED NOT NULL DEFAULT 0,
    `jockey_ride_damage`   BIGINT UNSIGNED NOT NULL DEFAULT 0,
    `charger_impacts`      INT UNSIGNED NOT NULL DEFAULT 0,
    `charger_carry_dist`   INT UNSIGNED NOT NULL DEFAULT 0 COMMENT 'units carried',
    `charger_scattering_rams` INT UNSIGNED NOT NULL DEFAULT 0,
    `spitter_pools`        INT UNSIGNED NOT NULL DEFAULT 0,
    `spitter_pool_damage`  BIGINT UNSIGNED NOT NULL DEFAULT 0,
    `tank_rocks_thrown`    INT UNSIGNED NOT NULL DEFAULT 0,
    `tank_rocks_hit`       INT UNSIGNED NOT NULL DEFAULT 0,
    `tank_punches`         INT UNSIGNED NOT NULL DEFAULT 0,
    `tank_bulldozers`      INT UNSIGNED NOT NULL DEFAULT 0,

    PRIMARY KEY (`player_id`, `gamemode_id`, `si_id`),
    CONSTRAINT `fk_psi_player` FOREIGN KEY (`player_id`)
        REFERENCES `players` (`id`) ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT `fk_psi_gamemode` FOREIGN KEY (`gamemode_id`)
        REFERENCES `gamemodes` (`id`) ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT `fk_psi_si` FOREIGN KEY (`si_id`)
        REFERENCES `special_infected` (`id`) ON DELETE RESTRICT ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- -----------------------------------------------------------------------------
-- player_weapon_stats: per-weapon usage. Drives "favorite weapon" displays,
-- precision leaderboards, weapon-balance analysis.
-- -----------------------------------------------------------------------------
CREATE TABLE `player_weapon_stats` (
    `player_id`     BIGINT UNSIGNED   NOT NULL,
    `weapon_id`     SMALLINT UNSIGNED NOT NULL,
    `shots_fired`   INT UNSIGNED      NOT NULL DEFAULT 0,
    `shots_hit`     INT UNSIGNED      NOT NULL DEFAULT 0,
    `headshots`     INT UNSIGNED      NOT NULL DEFAULT 0,
    `kills`         INT UNSIGNED      NOT NULL DEFAULT 0,
    `kills_special` INT UNSIGNED      NOT NULL DEFAULT 0,
    `kills_tank`    INT UNSIGNED      NOT NULL DEFAULT 0,
    `kills_witch`   INT UNSIGNED      NOT NULL DEFAULT 0,
    `damage_dealt`  BIGINT UNSIGNED   NOT NULL DEFAULT 0,
    `time_held_s`   INT UNSIGNED      NOT NULL DEFAULT 0,

    PRIMARY KEY (`player_id`, `weapon_id`),
    KEY `ix_pweap_kills` (`weapon_id`, `kills` DESC),
    CONSTRAINT `fk_pweap_player` FOREIGN KEY (`player_id`)
        REFERENCES `players` (`id`) ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT `fk_pweap_weapon` FOREIGN KEY (`weapon_id`)
        REFERENCES `weapons` (`id`) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- -----------------------------------------------------------------------------
-- map_stats: rollup per map per gamemode per difficulty. Replaces the
-- legacy `maps` table's per-difficulty column triples.
-- -----------------------------------------------------------------------------
CREATE TABLE `map_stats` (
    `map_id`        INT UNSIGNED      NOT NULL,
    `gamemode_id`   TINYINT UNSIGNED  NOT NULL,
    `difficulty_id` TINYINT UNSIGNED  NOT NULL DEFAULT 0,
    `plays`         INT UNSIGNED      NOT NULL DEFAULT 0,
    `restarts`      INT UNSIGNED      NOT NULL DEFAULT 0,
    `wins_survivors` INT UNSIGNED     NOT NULL DEFAULT 0,
    `wins_infected` INT UNSIGNED      NOT NULL DEFAULT 0,
    `playtime_s`    INT UNSIGNED      NOT NULL DEFAULT 0,
    `points_survivor` BIGINT          NOT NULL DEFAULT 0,
    `points_infected` BIGINT          NOT NULL DEFAULT 0,
    `kills_common`  INT UNSIGNED      NOT NULL DEFAULT 0,
    `kills_special` INT UNSIGNED      NOT NULL DEFAULT 0,
    `kills_survivor` INT UNSIGNED     NOT NULL DEFAULT 0,
    `tank_kills`    INT UNSIGNED      NOT NULL DEFAULT 0,
    `witch_kills`   INT UNSIGNED      NOT NULL DEFAULT 0,
    `caralarms`     INT UNSIGNED      NOT NULL DEFAULT 0,
    `gascans_poured` INT UNSIGNED     NOT NULL DEFAULT 0,

    PRIMARY KEY (`map_id`, `gamemode_id`, `difficulty_id`),
    KEY `ix_mstats_gm_plays` (`gamemode_id`, `plays` DESC),
    CONSTRAINT `fk_mstats_map` FOREIGN KEY (`map_id`)
        REFERENCES `maps` (`id`) ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT `fk_mstats_gamemode` FOREIGN KEY (`gamemode_id`)
        REFERENCES `gamemodes` (`id`) ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT `fk_mstats_difficulty` FOREIGN KEY (`difficulty_id`)
        REFERENCES `difficulties` (`id`) ON DELETE RESTRICT ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- -----------------------------------------------------------------------------
-- map_plays: optional per-play log. Provides time-series + heatmaps without
-- losing the rollup in map_stats. Disable via plugin CVAR for low-volume use.
-- -----------------------------------------------------------------------------
CREATE TABLE `map_plays` (
    `id`            BIGINT UNSIGNED   NOT NULL AUTO_INCREMENT,
    `map_id`        INT UNSIGNED      NOT NULL,
    `server_id`     INT UNSIGNED      NOT NULL,
    `gamemode_id`   TINYINT UNSIGNED  NOT NULL,
    `difficulty_id` TINYINT UNSIGNED  NOT NULL,
    `started_at`    DATETIME          NOT NULL,
    `ended_at`      DATETIME          NULL,
    `duration_s`    INT UNSIGNED      NOT NULL DEFAULT 0,
    `survivor_win`  TINYINT(1)        NULL,
    `player_count`  TINYINT UNSIGNED  NOT NULL DEFAULT 0,
    `bot_count`     TINYINT UNSIGNED  NOT NULL DEFAULT 0,
    PRIMARY KEY (`id`),
    KEY `ix_mplays_map_started` (`map_id`, `started_at`),
    KEY `ix_mplays_server_started` (`server_id`, `started_at`),
    CONSTRAINT `fk_mplays_map` FOREIGN KEY (`map_id`)
        REFERENCES `maps` (`id`) ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT `fk_mplays_server` FOREIGN KEY (`server_id`)
        REFERENCES `servers` (`id`) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- -----------------------------------------------------------------------------
-- timed_maps: best/longest time per (map, gamemode, difficulty, player).
-- For Survival the plugin stores longest time; for others shortest.
-- -----------------------------------------------------------------------------
CREATE TABLE `timed_maps` (
    `map_id`        INT UNSIGNED      NOT NULL,
    `gamemode_id`   TINYINT UNSIGNED  NOT NULL,
    `difficulty_id` TINYINT UNSIGNED  NOT NULL,
    `player_id`     BIGINT UNSIGNED   NOT NULL,
    `mutation`      VARCHAR(64)       NOT NULL DEFAULT '',
    `best_time_ms`  BIGINT UNSIGNED   NOT NULL,
    `plays`         INT UNSIGNED      NOT NULL DEFAULT 1,
    `players`       TINYINT UNSIGNED  NOT NULL DEFAULT 1 COMMENT 'team size when recorded',
    `created_at`    DATETIME          NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `updated_at`    DATETIME          NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (`map_id`, `gamemode_id`, `difficulty_id`, `player_id`, `mutation`),
    KEY `ix_timed_best` (`map_id`, `gamemode_id`, `difficulty_id`, `best_time_ms`),
    CONSTRAINT `fk_timed_map` FOREIGN KEY (`map_id`)
        REFERENCES `maps` (`id`) ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT `fk_timed_player` FOREIGN KEY (`player_id`)
        REFERENCES `players` (`id`) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

SET FOREIGN_KEY_CHECKS = 1;
