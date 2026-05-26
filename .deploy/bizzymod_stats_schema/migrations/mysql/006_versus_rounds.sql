-- =============================================================================
-- bizzymod-stats — 006_versus_rounds
--
-- Per-round, per-map, per-match tracking for Versus (and Scavenge / Realism
-- Versus, which share the structure: two halves per map, side-swap between
-- halves, persistent team identity across the swap, cumulative campaign
-- score across maps).
--
-- Vocabulary (and the words used throughout this schema):
--
--   match         — one contiguous campaign play with stable teams. Starts
--                   on first map, ends on `versus_match_finished` or
--                   abandonment. The thing players think of as "the game we
--                   just played".
--   match_map     — one map within a match. Contains the two rounds.
--   match_round   — one half. (match_id, map ordinal, round_index in {1,2}).
--                   The actual unit of play L4D2 emits round_end for.
--   team_letter   — 'A' or 'B'. Stable across the engine's side-swap; only
--                   changes when a player voluntarily switches teams. This
--                   maps onto the engine's m_iCampaignScore[0]/[1] indices.
--                   At match start, whoever plays Survivors in round 1 is A.
--
-- The schema captures both the engine's authoritative scenario score
-- (distance-based; used to declare the real winner) AND the plugin's
-- accumulated point score per round per player (used for our PPM and
-- awards). They're not the same metric and both are useful.
-- =============================================================================

SET NAMES utf8mb4;
SET FOREIGN_KEY_CHECKS = 0;

-- -----------------------------------------------------------------------------
-- matches: one campaign play with stable teams.
-- -----------------------------------------------------------------------------
CREATE TABLE `matches` (
    `id`            BIGINT UNSIGNED   NOT NULL AUTO_INCREMENT,
    `server_id`     INT UNSIGNED      NOT NULL,
    `gamemode_id`   TINYINT UNSIGNED  NOT NULL,
    `difficulty_id` TINYINT UNSIGNED  NOT NULL DEFAULT 0,
    `campaign`      VARCHAR(96)       NULL COMMENT 'first map''s campaign code, when known',
    `started_at`    DATETIME          NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `ended_at`      DATETIME          NULL,
    `maps_played`   TINYINT UNSIGNED  NOT NULL DEFAULT 0,
    `rounds_played` TINYINT UNSIGNED  NOT NULL DEFAULT 0,
    `team_a_score`  INT UNSIGNED      NOT NULL DEFAULT 0 COMMENT 'cumulative engine campaign score for team A',
    `team_b_score`  INT UNSIGNED      NOT NULL DEFAULT 0,
    `winner`        ENUM('A','B','draw','abandoned') NULL,
    `end_reason`    VARCHAR(48)       NULL COMMENT 'finale, mission_lost, abandoned, mode_change, ...',
    PRIMARY KEY (`id`),
    KEY `ix_matches_server_started` (`server_id`, `started_at`),
    KEY `ix_matches_open`           (`ended_at`),
    KEY `ix_matches_gamemode`       (`gamemode_id`, `started_at`),
    CONSTRAINT `fk_matches_server`     FOREIGN KEY (`server_id`)
        REFERENCES `servers`     (`id`) ON DELETE CASCADE  ON UPDATE CASCADE,
    CONSTRAINT `fk_matches_gamemode`   FOREIGN KEY (`gamemode_id`)
        REFERENCES `gamemodes`   (`id`) ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT `fk_matches_difficulty` FOREIGN KEY (`difficulty_id`)
        REFERENCES `difficulties`(`id`) ON DELETE RESTRICT ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- -----------------------------------------------------------------------------
-- match_teams: defines team A and team B for a given match. Two rows per
-- match. Display name is optional (e.g. "WinningTeam", "EU Stack").
-- -----------------------------------------------------------------------------
CREATE TABLE `match_teams` (
    `match_id`      BIGINT UNSIGNED   NOT NULL,
    `team_letter`   CHAR(1)           NOT NULL COMMENT 'A or B',
    `display_name`  VARCHAR(96)       NULL,
    `final_score`   INT UNSIGNED      NOT NULL DEFAULT 0,
    `rounds_won`    TINYINT UNSIGNED  NOT NULL DEFAULT 0,
    `rounds_lost`   TINYINT UNSIGNED  NOT NULL DEFAULT 0,
    `maps_won`      TINYINT UNSIGNED  NOT NULL DEFAULT 0,
    `maps_lost`     TINYINT UNSIGNED  NOT NULL DEFAULT 0,
    PRIMARY KEY (`match_id`, `team_letter`),
    CONSTRAINT `fk_mteams_match` FOREIGN KEY (`match_id`)
        REFERENCES `matches` (`id`) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- -----------------------------------------------------------------------------
-- match_team_players: persistent membership. A player can appear once per
-- (match, team_letter). If they voluntarily swap teams mid-match, a second
-- row is inserted for the other letter; their original row is closed off
-- with `left_round`.
-- -----------------------------------------------------------------------------
CREATE TABLE `match_team_players` (
    `match_id`     BIGINT UNSIGNED   NOT NULL,
    `team_letter`  CHAR(1)           NOT NULL,
    `player_id`    BIGINT UNSIGNED   NOT NULL,
    `joined_round` SMALLINT UNSIGNED NOT NULL DEFAULT 0 COMMENT '0 = present from match start',
    `left_round`   SMALLINT UNSIGNED NULL COMMENT 'NULL = still present at match end',
    `time_on_team_s` INT UNSIGNED    NOT NULL DEFAULT 0,
    `time_as_survivor_s` INT UNSIGNED NOT NULL DEFAULT 0,
    `time_as_infected_s` INT UNSIGNED NOT NULL DEFAULT 0,
    PRIMARY KEY (`match_id`, `team_letter`, `player_id`, `joined_round`),
    KEY `ix_mtp_player_match` (`player_id`, `match_id`),
    CONSTRAINT `fk_mtp_match` FOREIGN KEY (`match_id`)
        REFERENCES `matches` (`id`) ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT `fk_mtp_player` FOREIGN KEY (`player_id`)
        REFERENCES `players` (`id`) ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT `fk_mtp_team` FOREIGN KEY (`match_id`, `team_letter`)
        REFERENCES `match_teams` (`match_id`, `team_letter`) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- -----------------------------------------------------------------------------
-- match_maps: one row per map within a match. Aggregates the two halves and
-- declares a per-map winner once both rounds complete.
-- -----------------------------------------------------------------------------
CREATE TABLE `match_maps` (
    `id`               BIGINT UNSIGNED   NOT NULL AUTO_INCREMENT,
    `match_id`         BIGINT UNSIGNED   NOT NULL,
    `map_id`           INT UNSIGNED      NOT NULL,
    `ordinal`          TINYINT UNSIGNED  NOT NULL COMMENT '1..N within the match',
    `started_at`       DATETIME          NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `ended_at`         DATETIME          NULL,
    `team_a_score`    INT UNSIGNED      NOT NULL DEFAULT 0 COMMENT 'A''s survivor score on this map',
    `team_b_score`    INT UNSIGNED      NOT NULL DEFAULT 0,
    `winner`          ENUM('A','B','draw','incomplete') NOT NULL DEFAULT 'incomplete',
    `is_finale`       TINYINT(1)        NOT NULL DEFAULT 0,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_match_maps_ordinal` (`match_id`, `ordinal`),
    KEY `ix_match_maps_match` (`match_id`),
    CONSTRAINT `fk_mmaps_match` FOREIGN KEY (`match_id`)
        REFERENCES `matches` (`id`) ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT `fk_mmaps_map` FOREIGN KEY (`map_id`)
        REFERENCES `maps` (`id`) ON DELETE RESTRICT ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- -----------------------------------------------------------------------------
-- match_rounds: one row per half. The `survivor_team` column locks down
-- which team_letter played Survivors in this round; the other team played
-- Infected. Both engine and plugin scores are stored.
-- -----------------------------------------------------------------------------
CREATE TABLE `match_rounds` (
    `id`               BIGINT UNSIGNED   NOT NULL AUTO_INCREMENT,
    `match_id`         BIGINT UNSIGNED   NOT NULL,
    `match_map_id`     BIGINT UNSIGNED   NOT NULL,
    `round_index`      TINYINT UNSIGNED  NOT NULL COMMENT '1 or 2',
    `survivor_team`    CHAR(1)           NOT NULL COMMENT 'A or B',
    `started_at`       DATETIME          NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `ended_at`         DATETIME          NULL,
    `duration_s`       INT UNSIGNED      NOT NULL DEFAULT 0,
    `engine_score`     INT UNSIGNED      NOT NULL DEFAULT 0
        COMMENT 'Survivor team scenario score reported by the engine (distance-based, authoritative)',
    `plugin_score_surv` INT              NOT NULL DEFAULT 0
        COMMENT 'Sum of bizzymod-stats points earned by the Survivor team this round',
    `plugin_score_inf`  INT              NOT NULL DEFAULT 0
        COMMENT 'Sum of bizzymod-stats points earned by the Infected team this round',
    `survivors_left`   TINYINT UNSIGNED  NOT NULL DEFAULT 0,
    `tank_appeared`    TINYINT(1)        NOT NULL DEFAULT 0,
    `witch_appeared`   TINYINT(1)        NOT NULL DEFAULT 0,
    `end_reason`       VARCHAR(48)       NULL COMMENT 'survivor_wipe, saferoom, mission_lost, finale_win, ...',
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_round_idx` (`match_map_id`, `round_index`),
    KEY `ix_rounds_match` (`match_id`),
    CONSTRAINT `fk_rounds_match` FOREIGN KEY (`match_id`)
        REFERENCES `matches` (`id`) ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT `fk_rounds_mmap`  FOREIGN KEY (`match_map_id`)
        REFERENCES `match_maps` (`id`) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- -----------------------------------------------------------------------------
-- player_round_stats: per-player breakdown of a single half. The granular
-- "who did what when" table. Drives MVP/clutch leaderboards and replay
-- breakdowns. One row per (round, player) — players present for only part
-- of the round still get a row.
-- -----------------------------------------------------------------------------
CREATE TABLE `player_round_stats` (
    `match_round_id` BIGINT UNSIGNED   NOT NULL,
    `player_id`      BIGINT UNSIGNED   NOT NULL,
    `team_letter`    CHAR(1)           NOT NULL,
    `side`           TINYINT UNSIGNED  NOT NULL COMMENT '2=survivor, 3=infected',
    `points`         INT               NOT NULL DEFAULT 0,
    `kills`          INT UNSIGNED      NOT NULL DEFAULT 0,
    `deaths`         INT UNSIGNED      NOT NULL DEFAULT 0,
    `incaps`         INT UNSIGNED      NOT NULL DEFAULT 0,
    `damage_dealt`   INT UNSIGNED      NOT NULL DEFAULT 0,
    `damage_taken`   INT UNSIGNED      NOT NULL DEFAULT 0,
    `damage_friendly` INT UNSIGNED     NOT NULL DEFAULT 0,
    `time_in_round_s` INT UNSIGNED     NOT NULL DEFAULT 0,
    `awards_count`   SMALLINT UNSIGNED NOT NULL DEFAULT 0,
    PRIMARY KEY (`match_round_id`, `player_id`),
    KEY `ix_prs_player` (`player_id`),
    CONSTRAINT `fk_prs_round` FOREIGN KEY (`match_round_id`)
        REFERENCES `match_rounds` (`id`) ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT `fk_prs_player` FOREIGN KEY (`player_id`)
        REFERENCES `players` (`id`) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- -----------------------------------------------------------------------------
-- player_versus_stats: per-player running totals for versus play. Kept
-- separate from player_stats so the "you're up 4 maps to 2" view doesn't
-- require summing across the granular tables.
-- -----------------------------------------------------------------------------
CREATE TABLE `player_versus_stats` (
    `player_id`        BIGINT UNSIGNED   NOT NULL,
    `gamemode_id`      TINYINT UNSIGNED  NOT NULL COMMENT 'versus, realismversus, scavenge',
    `matches_played`   INT UNSIGNED      NOT NULL DEFAULT 0,
    `matches_won`      INT UNSIGNED      NOT NULL DEFAULT 0,
    `matches_lost`     INT UNSIGNED      NOT NULL DEFAULT 0,
    `matches_drawn`    INT UNSIGNED      NOT NULL DEFAULT 0,
    `matches_abandoned` INT UNSIGNED     NOT NULL DEFAULT 0,
    `maps_won`         INT UNSIGNED      NOT NULL DEFAULT 0,
    `maps_lost`        INT UNSIGNED      NOT NULL DEFAULT 0,
    `rounds_played`    INT UNSIGNED      NOT NULL DEFAULT 0,
    `rounds_won`       INT UNSIGNED      NOT NULL DEFAULT 0,
    `rounds_lost`      INT UNSIGNED      NOT NULL DEFAULT 0,
    `rounds_as_surv`   INT UNSIGNED      NOT NULL DEFAULT 0,
    `rounds_as_inf`    INT UNSIGNED      NOT NULL DEFAULT 0,
    `total_round_score_surv` BIGINT      NOT NULL DEFAULT 0,
    `total_round_score_inf`  BIGINT      NOT NULL DEFAULT 0,
    `current_win_streak`  INT UNSIGNED   NOT NULL DEFAULT 0,
    `longest_win_streak`  INT UNSIGNED   NOT NULL DEFAULT 0,
    `current_loss_streak` INT UNSIGNED   NOT NULL DEFAULT 0,
    `longest_loss_streak` INT UNSIGNED   NOT NULL DEFAULT 0,
    `last_match_at`    DATETIME          NULL,
    PRIMARY KEY (`player_id`, `gamemode_id`),
    KEY `ix_pvs_winrate` (`gamemode_id`, `matches_won` DESC),
    CONSTRAINT `fk_pvs_player` FOREIGN KEY (`player_id`)
        REFERENCES `players` (`id`) ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT `fk_pvs_gamemode` FOREIGN KEY (`gamemode_id`)
        REFERENCES `gamemodes` (`id`) ON DELETE RESTRICT ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- -----------------------------------------------------------------------------
-- v_match_summary: one row per match with both teams' final scores and
-- the recent-matches list display joined from match_teams.
-- -----------------------------------------------------------------------------
DROP VIEW IF EXISTS `v_match_summary`;
CREATE VIEW `v_match_summary` AS
SELECT
    m.id              AS match_id,
    m.server_id,
    s.name            AS server_name,
    g.code            AS gamemode,
    m.campaign,
    m.started_at,
    m.ended_at,
    m.maps_played,
    m.rounds_played,
    m.team_a_score,
    m.team_b_score,
    m.winner,
    m.end_reason
FROM matches m
JOIN servers s   ON s.id = m.server_id
JOIN gamemodes g ON g.id = m.gamemode_id;

-- -----------------------------------------------------------------------------
-- v_match_team_roster: who was on each team of each match (latest snapshot)
-- -----------------------------------------------------------------------------
DROP VIEW IF EXISTS `v_match_team_roster`;
CREATE VIEW `v_match_team_roster` AS
SELECT
    mtp.match_id,
    mtp.team_letter,
    p.id                  AS player_id,
    p.steamid,
    CAST(p.name AS CHAR)  AS player_name,
    mtp.joined_round,
    mtp.left_round,
    mtp.time_on_team_s
FROM match_team_players mtp
JOIN players p ON p.id = mtp.player_id;

-- -----------------------------------------------------------------------------
-- v_player_versus: per-player versus stats with computed win-rate.
-- -----------------------------------------------------------------------------
DROP VIEW IF EXISTS `v_player_versus`;
CREATE VIEW `v_player_versus` AS
SELECT
    pvs.player_id,
    CAST(p.name AS CHAR) AS name,
    g.code               AS gamemode,
    pvs.matches_played,
    pvs.matches_won,
    pvs.matches_lost,
    pvs.matches_drawn,
    pvs.maps_won,
    pvs.maps_lost,
    pvs.rounds_played,
    pvs.rounds_won,
    pvs.rounds_lost,
    pvs.longest_win_streak,
    CASE WHEN pvs.matches_played > 0
         THEN ROUND(100.0 * pvs.matches_won / pvs.matches_played, 2)
         ELSE 0 END AS match_winrate_pct,
    CASE WHEN pvs.rounds_played > 0
         THEN ROUND(100.0 * pvs.rounds_won / pvs.rounds_played, 2)
         ELSE 0 END AS round_winrate_pct
FROM player_versus_stats pvs
JOIN players   p ON p.id = pvs.player_id
JOIN gamemodes g ON g.id = pvs.gamemode_id;

SET FOREIGN_KEY_CHECKS = 1;
