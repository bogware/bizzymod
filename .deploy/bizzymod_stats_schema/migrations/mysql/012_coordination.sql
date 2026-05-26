-- =============================================================================
-- bizzymod-stats — 012_coordination
--
-- Roadmap §5: Coordination & teamwork. Revive chains, save-of-save,
-- focus alignment, tank/witch focus participation %.
-- =============================================================================

SET NAMES utf8mb4;
SET FOREIGN_KEY_CHECKS = 0;

-- -----------------------------------------------------------------------------
-- Revive-chain tracking. Each revive event records which player revived
-- which, and the chain detector retroactively links events into chains.
-- Stored granularly because chains span multiple players.
-- -----------------------------------------------------------------------------
CREATE TABLE `revive_events` (
    `id`           BIGINT UNSIGNED   NOT NULL AUTO_INCREMENT,
    `server_id`    INT UNSIGNED      NOT NULL,
    `match_round_id` BIGINT UNSIGNED NULL,
    `reviver_id`   BIGINT UNSIGNED   NOT NULL,
    `revived_id`   BIGINT UNSIGNED   NOT NULL,
    `at`           DATETIME          NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `via_defib`    TINYINT(1)        NOT NULL DEFAULT 0,
    `chain_root`   BIGINT UNSIGNED   NULL COMMENT 'id of the first revive in the chain',
    `chain_depth`  TINYINT UNSIGNED  NOT NULL DEFAULT 1,
    PRIMARY KEY (`id`),
    KEY `ix_re_reviver` (`reviver_id`, `at`),
    KEY `ix_re_revived` (`revived_id`, `at`),
    KEY `ix_re_chain` (`chain_root`),
    CONSTRAINT `fk_re_reviver` FOREIGN KEY (`reviver_id`)
        REFERENCES `players` (`id`) ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT `fk_re_revived` FOREIGN KEY (`revived_id`)
        REFERENCES `players` (`id`) ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT `fk_re_server` FOREIGN KEY (`server_id`)
        REFERENCES `servers` (`id`) ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT `fk_re_round` FOREIGN KEY (`match_round_id`)
        REFERENCES `match_rounds` (`id`) ON DELETE SET NULL ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- -----------------------------------------------------------------------------
-- Player rollups: how many chains, how deep on average, etc.
-- -----------------------------------------------------------------------------
ALTER TABLE `player_stats`
    ADD COLUMN `revive_chains_started` INT UNSIGNED NOT NULL DEFAULT 0
        COMMENT 'revive events where you started a chain',
    ADD COLUMN `revive_chains_part_of` INT UNSIGNED NOT NULL DEFAULT 0
        COMMENT 'unique chains you were part of',
    ADD COLUMN `save_of_saves`         INT UNSIGNED NOT NULL DEFAULT 0
        COMMENT 'you saved someone who then saved someone within 60s';

-- -----------------------------------------------------------------------------
-- Tank/witch focus participation. We log per-tank damage attribution so
-- "who contributed how much" is queryable.
-- -----------------------------------------------------------------------------
CREATE TABLE `boss_damage_log` (
    `id`            BIGINT UNSIGNED   NOT NULL AUTO_INCREMENT,
    `boss_kind`     ENUM('tank','witch') NOT NULL,
    `boss_record_id` BIGINT UNSIGNED  NOT NULL COMMENT 'tank_records.id or witch_records.id',
    `player_id`     BIGINT UNSIGNED   NOT NULL,
    `damage`        INT UNSIGNED      NOT NULL,
    `damage_pct`    DECIMAL(5,2)      NOT NULL DEFAULT 0.00,
    `dealt_killing_blow` TINYINT(1)   NOT NULL DEFAULT 0,
    `at`            DATETIME          NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `ix_bdl_boss` (`boss_kind`, `boss_record_id`),
    KEY `ix_bdl_player` (`player_id`, `at`),
    CONSTRAINT `fk_bdl_player` FOREIGN KEY (`player_id`)
        REFERENCES `players` (`id`) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- -----------------------------------------------------------------------------
-- Career bests additions for coordination flavor
-- -----------------------------------------------------------------------------
ALTER TABLE `career_bests`
    ADD COLUMN `longest_revive_chain` TINYINT UNSIGNED NOT NULL DEFAULT 0,
    ADD COLUMN `best_tank_damage_pct` DECIMAL(5,2) NOT NULL DEFAULT 0.00;

-- -----------------------------------------------------------------------------
-- Awards.
-- -----------------------------------------------------------------------------
INSERT IGNORE INTO `awards`
    (`code`, `name`, `description`, `category`, `team`, `game_id`, `is_negative`, `base_points`, `display_order`)
VALUES
    ('chain_revive',    'Chain Reviver',    'Participated in a 3+ revive chain',         'survivor', 2, 0, 0, 0, 76),
    ('save_of_save',    'Save of a Save',   'Saved someone who then saved someone (60s)', 'survivor', 2, 0, 0, 0, 77),
    ('tank_carry',      'Tank Carry',       'Did 50%+ of damage to a killed tank',       'survivor', 2, 0, 0, 0, 78),
    ('mvp_of_round',    'MVP of Round',     'Top points in a single versus round',       'survivor', 2, 0, 0, 0, 79);

-- -----------------------------------------------------------------------------
-- Views.
-- -----------------------------------------------------------------------------
DROP VIEW IF EXISTS `v_revive_chains`;
CREATE VIEW `v_revive_chains` AS
SELECT
    chain_root,
    MIN(at)    AS started_at,
    MAX(at)    AS ended_at,
    COUNT(*)   AS chain_size,
    MAX(chain_depth) AS max_depth,
    GROUP_CONCAT(reviver_id ORDER BY at) AS reviver_chain
FROM revive_events
WHERE chain_root IS NOT NULL
GROUP BY chain_root;

DROP VIEW IF EXISTS `v_tank_contributors`;
CREATE VIEW `v_tank_contributors` AS
SELECT
    boss_record_id  AS tank_record_id,
    player_id,
    damage,
    damage_pct,
    dealt_killing_blow
FROM boss_damage_log
WHERE boss_kind = 'tank';

SET FOREIGN_KEY_CHECKS = 1;
