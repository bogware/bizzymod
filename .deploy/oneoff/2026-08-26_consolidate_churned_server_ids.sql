-- =====================================================================
-- One-off DB cleanup — 2026-08-26 — consolidate churned server_ids -> 218
-- =====================================================================
-- Before bogware/bizzymod-stats#6 was fixed, the stats plugin failed to
-- persist its server key and generated a fresh random key (=> a fresh
-- servers.id) on every boot. Over ~a week of testing this one physical
-- server registered as server_id 208..219. #6 fixed the cause (the key now
-- persists in addons/sourcemod/data/; the server is stably 218). This
-- one-off repoints the per-event rows written under the churned IDs onto 218.
--
-- Why this is safe:
--   * player_stats is EXCLUDED — it is always written with server_id=0 (the
--     "aggregated across all servers" row that the leaderboard views read),
--     so it was never fragmented, and it is the only table with server_id in
--     a unique key. Nothing to repoint there.
--   * The four affected tables key on their own auto-increment PK, so a plain
--     UPDATE of server_id cannot collide.
--
-- Executed against production on 2026-08-26 (218 rows repointed). Recorded
-- here for provenance; it is NOT part of the normal deploy (.deploy/ is
-- excluded from the game rsync).
-- =====================================================================
UPDATE sessions            SET server_id = 218 WHERE server_id BETWEEN 208 AND 219 AND server_id <> 218;  -- 94 rows
UPDATE tank_records        SET server_id = 218 WHERE server_id BETWEEN 208 AND 219 AND server_id <> 218;  -- 23 rows
UPDATE witch_records       SET server_id = 218 WHERE server_id BETWEEN 208 AND 219 AND server_id <> 218;  -- 31 rows
UPDATE director_placements SET server_id = 218 WHERE server_id BETWEEN 208 AND 219 AND server_id <> 218;  -- 70 rows
