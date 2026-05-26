-- =============================================================================
-- bizzymod-stats — 005_views
-- Convenience views. The plugin doesn't need them; the web/dashboard side
-- does. Drop and recreate; no migration tracking needed.
-- =============================================================================

SET NAMES utf8mb4;

DROP VIEW IF EXISTS `v_player_totals`;
CREATE VIEW `v_player_totals` AS
SELECT
    p.id                  AS player_id,
    p.steamid,
    CAST(p.name AS CHAR)  AS name,
    p.country_code,
    p.last_seen,
    SUM(ps.points)        AS points,
    SUM(ps.playtime_s)    AS playtime_s,
    SUM(ps.kills_common + ps.kills_special + ps.kills_tank + ps.kills_witch + ps.kills_survivor) AS kills,
    SUM(ps.headshots)     AS headshots,
    SUM(ps.shots_fired)   AS shots_fired,
    SUM(ps.shots_hit)     AS shots_hit,
    SUM(ps.deaths)        AS deaths,
    SUM(ps.damage_dealt)  AS damage_dealt,
    SUM(ps.damage_taken)  AS damage_taken,
    CASE WHEN SUM(ps.playtime_s) > 0
         THEN ROUND(SUM(ps.points) * 60.0 / SUM(ps.playtime_s), 2)
         ELSE 0 END       AS points_per_minute,
    CASE WHEN SUM(ps.shots_fired) > 0
         THEN ROUND(100.0 * SUM(ps.shots_hit) / SUM(ps.shots_fired), 2)
         ELSE 0 END       AS accuracy_pct,
    CASE WHEN SUM(ps.shots_hit) > 0
         THEN ROUND(100.0 * SUM(ps.headshots) / SUM(ps.shots_hit), 2)
         ELSE 0 END       AS headshot_pct
FROM players p
LEFT JOIN player_stats ps ON ps.player_id = p.id AND ps.server_id = 0
GROUP BY p.id;

DROP VIEW IF EXISTS `v_top_players`;
CREATE VIEW `v_top_players` AS
SELECT * FROM v_player_totals
WHERE playtime_s >= 1800
ORDER BY points DESC;

DROP VIEW IF EXISTS `v_player_awards_summary`;
CREATE VIEW `v_player_awards_summary` AS
SELECT
    pa.player_id,
    a.code,
    a.name,
    a.category,
    SUM(pa.count) AS total_count
FROM player_awards pa
JOIN awards a ON a.id = pa.award_id
GROUP BY pa.player_id, a.id;

DROP VIEW IF EXISTS `v_map_summary`;
CREATE VIEW `v_map_summary` AS
SELECT
    m.id           AS map_id,
    m.code,
    m.display_name,
    m.campaign,
    m.is_finale,
    m.is_custom,
    g.code         AS game,
    SUM(ms.plays)  AS plays,
    SUM(ms.playtime_s) AS playtime_s,
    SUM(ms.wins_survivors) AS wins_survivors,
    SUM(ms.wins_infected)  AS wins_infected
FROM maps m
JOIN games g ON g.id = m.game_id
LEFT JOIN map_stats ms ON ms.map_id = m.id
GROUP BY m.id;
