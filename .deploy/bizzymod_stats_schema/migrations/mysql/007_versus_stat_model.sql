-- -----------------------------------------------------------------------------
-- 007_versus_stat_model.sql
--
-- Versus stat-model cleanup (see CHANGELOG 0.7.4):
--   * A versus HALF has no individual winner — the chapter is decided by comparing
--     its two halves — so player_versus_stats.rounds_won / rounds_lost were always
--     0 and made round_winrate_pct read 0%. Drop them.
--   * The user-facing "Round" win/loss is the per-CHAPTER aggregate
--     (maps_won / maps_lost): each chapter is what players call "a round of versus",
--     won or lost on its own two halves with no campaign carry-over. The view now
--     surfaces those as round_wins / round_losses and computes both win-rates over
--     DECIDED games (wins / (wins + losses)), not over games-played (which now
--     include abandoned matches that carry no win/loss).
-- Apply AFTER every server is running plugin >= 0.7.4 (which no longer writes the
-- dropped columns).
-- -----------------------------------------------------------------------------

SET FOREIGN_KEY_CHECKS = 0;

ALTER TABLE `player_versus_stats`
    DROP COLUMN `rounds_won`,
    DROP COLUMN `rounds_lost`;

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
    pvs.matches_abandoned,
    -- "Round" W/L = the per-chapter aggregate (maps_won / maps_lost).
    pvs.maps_won         AS round_wins,
    pvs.maps_lost        AS round_losses,
    pvs.maps_won,
    pvs.maps_lost,
    pvs.rounds_played,          -- halves played (informational)
    pvs.rounds_as_surv,
    pvs.rounds_as_inf,
    pvs.current_win_streak,
    pvs.longest_win_streak,
    pvs.current_loss_streak,
    pvs.longest_loss_streak,
    CASE WHEN (pvs.matches_won + pvs.matches_lost) > 0
         THEN ROUND(100.0 * pvs.matches_won / (pvs.matches_won + pvs.matches_lost), 2)
         ELSE 0 END AS match_winrate_pct,
    CASE WHEN (pvs.maps_won + pvs.maps_lost) > 0
         THEN ROUND(100.0 * pvs.maps_won / (pvs.maps_won + pvs.maps_lost), 2)
         ELSE 0 END AS round_winrate_pct
FROM player_versus_stats pvs
JOIN players   p ON p.id = pvs.player_id
JOIN gamemodes g ON g.id = pvs.gamemode_id;

SET FOREIGN_KEY_CHECKS = 1;
