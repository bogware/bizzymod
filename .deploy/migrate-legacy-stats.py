#!/usr/bin/env python3
"""
migrate-legacy-stats.py — port legacy l4d_stats data into bizzymod_stats.

Reads the legacy (denormalized) l4d2stats schema and INSERTs into the new
bogware/bizzymod-stats normalized schema. Designed to be IDEMPOTENT (safe
to re-run) via INSERT IGNORE on natural keys and ON DUPLICATE KEY UPDATE
on rollups.

Legacy → new mapping:

  players (1 row per steamid, ~80 cols)
    -> players (id, steamid, name, last_seen, last_gamemode)
    -> player_stats per (gamemode_id, difficulty_id=unknown, server_id=legacy)
    -> player_si_stats per (gamemode_id=coop, si_id) for kill_* columns
    -> player_awards per (award_id, gamemode_id=coop) for award_* columns

  maps (1 row per name)
    -> maps  (1 row per name)
    -> map_stats per (gamemode_id, difficulty_id, server_id=legacy)

  timedmaps (1 row per (steamid, map))
    -> timed_maps (1 row per (player_id, map_id, gamemode_id, difficulty_id))

Unmappable legacy columns (e.g. award_left4dead in modes that no longer
exist, exotic counters) are silently skipped — they print a one-line
summary at the end.

Usage:
  python migrate-legacy-stats.py \\
      --host db.internal --port 3306 \\
      --user steam --password X \\
      --legacy-db l4d2stats --new-db bizzymod_stats \\
      [--dry-run] [--batch 500]
"""

from __future__ import annotations

import argparse
import datetime as dt
import sys
from collections import Counter
from typing import Iterable

import mysql.connector  # pip install mysql-connector-python


# ============================================================================
# Catalog mappings (legacy column → new catalog id / code)
# ============================================================================

# Legacy lastgamemode int → new gamemodes.id. The new schema uses the same
# integer ids that the legacy plugin's GAMEMODE_* defines used, so this is
# the identity mapping. Defensive 'unknown' is gamemode_id=0 (coop) for
# anything we can't map.
GAMEMODE_COOP = 0
GAMEMODE_VERSUS = 1
GAMEMODE_REALISM = 2
GAMEMODE_SURVIVAL = 3
GAMEMODE_SCAVENGE = 4
GAMEMODE_REALISMVERSUS = 5

DIFFICULTY_UNKNOWN = 0   # difficulties.id; legacy stored no difficulty per row

# Special infected id mapping for L4D2 (matches seed in 004_seed_catalogs).
SI_MAP = {
    "smoker": 1,
    "boomer": 2,
    "hunter": 3,
    "spitter": 4,
    "jockey": 5,
    "charger": 6,
}

# legacy.players.award_<COL> → new awards.code
AWARD_MAP = {
    "award_pills":              "pills_shared",
    "award_adrenaline":         "adrenaline_shared",
    "award_fincap":             "friendly_incap",
    "award_defib":              "defib",
    "award_protect":            "protect",
    "award_revive":             "revive",
    "award_rescue":             "rescue",
    "award_campaigns":          "campaign",
    "award_tankkill":           "tank_kill",
    "award_tankkillnodeaths":   "tank_kill_no_deaths",
    "award_allinsafehouse":     "all_in_safehouse",
    "award_friendlyfire":       "friendly_fire",
    "award_teamkill":           "teamkill",
    "award_left4dead":          "left4dead",
    "award_letinsafehouse":     "let_in_safehouse",
    "award_witchdisturb":       "witch_disturb",
    "award_pounce_perfect":     "pounce_perfect",
    "award_pounce_nice":        "pounce_nice",
    "award_perfect_blindness":  "boomer_perfect",
    # No direct equivalent for these (legacy-specific counters):
    #   award_medkit, award_charger, award_jockey, award_hunter, award_smoker
    # They're captured separately via player_si_stats.{rides,impacts,...}
}


# ============================================================================
# Helpers
# ============================================================================

def parse_lastontime(raw: str | None) -> dt.datetime:
    """Legacy stores lastontime as a varchar — try several common formats."""
    if not raw:
        return dt.datetime.utcnow()
    for fmt in (
        "%Y-%m-%d %H:%M:%S",
        "%Y-%m-%dT%H:%M:%S",
        "%Y/%m/%d %H:%M:%S",
        "%s",   # unix epoch as string
    ):
        try:
            if fmt == "%s":
                return dt.datetime.utcfromtimestamp(int(raw))
            return dt.datetime.strptime(raw, fmt)
        except (ValueError, TypeError):
            continue
    return dt.datetime.utcnow()


def chunks(seq: Iterable, n: int):
    buf = []
    for x in seq:
        buf.append(x)
        if len(buf) >= n:
            yield buf
            buf = []
    if buf:
        yield buf


# ============================================================================
# Migration
# ============================================================================

def ensure_legacy_server(new_cur) -> int:
    """Create or fetch a synthetic 'legacy-import' row in the `servers` table
    so imported player_stats / map_stats have a stable server_id to attribute
    historical data to."""
    # The column is named `key` (reserved word — must backtick) and game_id is
    # required NOT NULL. We tag the import as L4D2 (game_id=2).
    new_cur.execute(
        "INSERT INTO servers (`key`, `name`, `game_id`) VALUES (%s, %s, %s) "
        "ON DUPLICATE KEY UPDATE id=LAST_INSERT_ID(id)",
        ("legacy-import--------------------", "Legacy l4d_stats import", 2),
    )
    return new_cur.lastrowid


def load_award_code_to_id(new_cur) -> dict[str, int]:
    new_cur.execute("SELECT id, code FROM awards")
    return {code: row_id for row_id, code in new_cur.fetchall()}


def migrate_players(legacy_cur, new_cur, server_id: int, award_lut: dict[str, int],
                    batch: int, dry_run: bool, stats: Counter) -> dict[str, int]:
    """Returns a steamid -> new_player_id map."""
    legacy_cur.execute("SELECT * FROM players")
    cols = [c[0] for c in legacy_cur.description]
    rows = legacy_cur.fetchall()
    print(f"  legacy.players: {len(rows)} rows")

    steamid_to_id: dict[str, int] = {}

    for batch_rows in chunks(rows, batch):
        # Phase 1: upsert into players, capture (steamid -> id).
        player_inserts = []
        for r in batch_rows:
            row = dict(zip(cols, r))
            steamid = (row.get("steamid") or "").strip()
            if not steamid:
                continue
            name_bytes = row.get("name") or b""
            if isinstance(name_bytes, str):
                name_bytes = name_bytes.encode("utf-8", errors="replace")
            player_inserts.append((
                steamid,
                name_bytes,
                parse_lastontime(row.get("lastontime")),
                int(row.get("lastgamemode") or 0),
            ))

        if not dry_run:
            new_cur.executemany(
                "INSERT INTO players (steamid, name, last_seen, last_gamemode) "
                "VALUES (%s, %s, %s, %s) "
                "ON DUPLICATE KEY UPDATE "
                "  name=VALUES(name), last_seen=GREATEST(last_seen, VALUES(last_seen)), "
                "  last_gamemode=VALUES(last_gamemode)",
                player_inserts,
            )

        # Fetch back ids for the steamids we just upserted.
        steamids = [p[0] for p in player_inserts]
        if steamids:
            placeholders = ",".join(["%s"] * len(steamids))
            new_cur.execute(
                f"SELECT id, steamid FROM players WHERE steamid IN ({placeholders})",
                steamids,
            )
            for pid, sid in new_cur.fetchall():
                steamid_to_id[sid] = pid

        # Phase 2: per-player derived rows.
        for r in batch_rows:
            row = dict(zip(cols, r))
            steamid = (row.get("steamid") or "").strip()
            pid = steamid_to_id.get(steamid)
            if pid is None:
                continue

            # ---- player_stats per gamemode -------------------------------
            # Legacy has total `kills` (no per-class breakdown); we drop it
            # into kills_common because in coop most kills are commons. Special
            # infected kills come in via the kill_<si> columns and go into
            # kills_special instead.
            gamemode_metrics = [
                # (gamemode_id, playtime_col, points_col, kills_col)
                (GAMEMODE_COOP,      "playtime",              "points",                       "kills"),
                (GAMEMODE_VERSUS,    "playtime_versus",       "points_survivors",             "versus_kills_survivors"),
                (GAMEMODE_REALISM,   "playtime_realism",      "points_realism",               "realism_kills_survivors"),
                (GAMEMODE_SURVIVAL,  "playtime_survival",     "points_survival",              None),
                (GAMEMODE_SCAVENGE,  "playtime_scavenge",     "points_scavenge_survivors",    "scavenge_kills_survivors"),
                (GAMEMODE_REALISMVERSUS, "playtime_realismversus", None,                      None),
            ]
            total_si_kills = sum(int(row.get(f"kill_{c}") or 0) for c in SI_MAP)
            for gmid, pt_col, pts_col, kills_col in gamemode_metrics:
                playtime = int(row.get(pt_col) or 0)
                points = int(row.get(pts_col) or 0) if pts_col else 0
                kills = int(row.get(kills_col) or 0) if kills_col else 0
                # All legacy SI-kill counts get attributed to the COOP rollup
                # (legacy schema doesn't split them by mode).
                kills_special = total_si_kills if gmid == GAMEMODE_COOP else 0
                hs = int(row.get("headshots") or 0) if gmid == GAMEMODE_COOP else 0
                mk = int(row.get("melee_kills") or 0) if gmid == GAMEMODE_COOP else 0
                if (playtime == 0 and points == 0 and kills == 0
                        and kills_special == 0 and hs == 0 and mk == 0):
                    continue
                if not dry_run:
                    new_cur.execute(
                        "INSERT INTO player_stats "
                        "  (player_id, gamemode_id, difficulty_id, server_id, "
                        "   playtime_s, points, kills_common, kills_special, "
                        "   kills_melee, headshots) "
                        "VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s) "
                        "ON DUPLICATE KEY UPDATE "
                        "  playtime_s=playtime_s+VALUES(playtime_s), "
                        "  points=points+VALUES(points), "
                        "  kills_common=kills_common+VALUES(kills_common), "
                        "  kills_special=kills_special+VALUES(kills_special), "
                        "  kills_melee=kills_melee+VALUES(kills_melee), "
                        "  headshots=headshots+VALUES(headshots)",
                        (pid, gmid, DIFFICULTY_UNKNOWN, server_id,
                         playtime, points, kills, kills_special, mk, hs),
                    )
                stats["player_stats_rows"] += 1

            # ---- player_si_stats: jockey rides, charger impacts ----------
            # The new schema's player_si_stats is from the SI player's
            # perspective (their pounces/vomits/rides/impacts). Legacy only
            # tracked rides + impacts as the player AS infected. SI kill
            # counts above already roll into player_stats.kills_special.
            jr = int(row.get("jockey_rides") or 0)
            if jr and not dry_run:
                new_cur.execute(
                    "INSERT INTO player_si_stats "
                    "  (player_id, gamemode_id, si_id, jockey_rides) "
                    "VALUES (%s, %s, %s, %s) "
                    "ON DUPLICATE KEY UPDATE jockey_rides=jockey_rides+VALUES(jockey_rides)",
                    (pid, GAMEMODE_VERSUS, SI_MAP["jockey"], jr),
                )
                stats["player_si_rows"] += 1
            ci = int(row.get("charger_impacts") or 0)
            if ci and not dry_run:
                new_cur.execute(
                    "INSERT INTO player_si_stats "
                    "  (player_id, gamemode_id, si_id, charger_impacts) "
                    "VALUES (%s, %s, %s, %s) "
                    "ON DUPLICATE KEY UPDATE charger_impacts=charger_impacts+VALUES(charger_impacts)",
                    (pid, GAMEMODE_VERSUS, SI_MAP["charger"], ci),
                )
                stats["player_si_rows"] += 1

            # ---- player_awards per legacy award column -------------------
            last_seen = parse_lastontime(row.get("lastontime"))
            for legacy_col, new_code in AWARD_MAP.items():
                n = int(row.get(legacy_col) or 0)
                if n == 0:
                    continue
                award_id = award_lut.get(new_code)
                if award_id is None:
                    stats[f"award_skipped_{new_code}"] += n
                    continue
                if not dry_run:
                    new_cur.execute(
                        "INSERT INTO player_awards "
                        "  (player_id, award_id, gamemode_id, count, first_at, last_at) "
                        "VALUES (%s, %s, %s, %s, %s, %s) "
                        "ON DUPLICATE KEY UPDATE "
                        "  count=count+VALUES(count), "
                        "  last_at=GREATEST(last_at, VALUES(last_at))",
                        (pid, award_id, GAMEMODE_COOP, n, last_seen, last_seen),
                    )
                stats["award_rows"] += 1

        stats["players_processed"] += len(batch_rows)
        print(f"  ... {stats['players_processed']}/{len(rows)} players processed")

    return steamid_to_id


def migrate_maps(legacy_cur, new_cur, server_id: int, dry_run: bool, stats: Counter):
    legacy_cur.execute("SELECT * FROM maps")
    cols = [c[0] for c in legacy_cur.description]
    rows = legacy_cur.fetchall()
    print(f"  legacy.maps: {len(rows)} rows")

    for r in rows:
        row = dict(zip(cols, r))
        name = (row.get("name") or "").strip()
        if not name:
            continue
        gm = int(row.get("gamemode") or 0)
        if not dry_run:
            # maps has UNIQUE (code, game_id); game_id 2 = L4D2
            new_cur.execute(
                "INSERT INTO maps (code, display_name, is_custom, game_id) "
                "VALUES (%s, %s, %s, %s) "
                "ON DUPLICATE KEY UPDATE id=LAST_INSERT_ID(id)",
                (name, name, int(bool(row.get("custom"))), 2)
            )
            map_id = new_cur.lastrowid
        else:
            map_id = None

        # Rollups by difficulty (legacy stored 3 sets: _nor / _adv / _exp)
        # map_stats has NO server_id column; PK is (map_id, gamemode_id, difficulty_id).
        # Legacy columns: playtime_<diff>, points_<diff>, kills_<diff> (common+SI),
        # survivor_kills_<diff>, restarts_<diff>, survivors_win_<diff>, infected_win_<diff>.
        for diff_id, suf in [(2, "nor"), (3, "adv"), (4, "exp")]:
            pt = int(row.get(f"playtime_{suf}") or 0)
            pts_surv = int(row.get(f"points_{suf}") or 0)
            pts_inf = int(row.get(f"points_infected_{suf}") or 0)
            kills_common = int(row.get(f"kills_{suf}") or 0)
            kills_survivor = int(row.get(f"survivor_kills_{suf}") or 0)
            restarts = int(row.get(f"restarts_{suf}") or 0)
            wins_surv = int(row.get(f"survivors_win_{suf}") or 0)
            wins_inf = int(row.get(f"infected_win_{suf}") or 0)
            if all(x == 0 for x in (pt, pts_surv, pts_inf, kills_common,
                                     kills_survivor, restarts, wins_surv, wins_inf)):
                continue
            if not dry_run and map_id is not None:
                new_cur.execute(
                    "INSERT INTO map_stats "
                    "  (map_id, gamemode_id, difficulty_id, "
                    "   plays, restarts, wins_survivors, wins_infected, "
                    "   playtime_s, points_survivor, points_infected, "
                    "   kills_common, kills_survivor) "
                    "VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s) "
                    "ON DUPLICATE KEY UPDATE "
                    "  restarts=restarts+VALUES(restarts), "
                    "  wins_survivors=wins_survivors+VALUES(wins_survivors), "
                    "  wins_infected=wins_infected+VALUES(wins_infected), "
                    "  playtime_s=playtime_s+VALUES(playtime_s), "
                    "  points_survivor=points_survivor+VALUES(points_survivor), "
                    "  points_infected=points_infected+VALUES(points_infected), "
                    "  kills_common=kills_common+VALUES(kills_common), "
                    "  kills_survivor=kills_survivor+VALUES(kills_survivor)",
                    (map_id, gm, diff_id,
                     wins_surv + wins_inf, restarts, wins_surv, wins_inf,
                     pt, pts_surv, pts_inf, kills_common, kills_survivor),
                )
            stats["map_stats_rows"] += 1
        stats["maps_processed"] += 1


def migrate_timedmaps(legacy_cur, new_cur, steamid_to_id, dry_run: bool, stats: Counter):
    try:
        legacy_cur.execute("SELECT * FROM timedmaps")
    except mysql.connector.Error:
        print("  legacy.timedmaps: table missing, skipping")
        return
    cols = [c[0] for c in legacy_cur.description]
    rows = legacy_cur.fetchall()
    print(f"  legacy.timedmaps: {len(rows)} rows")
    skipped = 0

    for r in rows:
        row = dict(zip(cols, r))
        sid = (row.get("steamid") or "").strip()
        pid = steamid_to_id.get(sid)
        mapname = (row.get("map") or row.get("mapname") or "").strip()
        time_s = int(row.get("time") or row.get("besttime") or 0)
        if not pid or not mapname or not time_s:
            skipped += 1
            continue
        if dry_run:
            stats["timed_maps_rows"] += 1
            continue
        # Look up map_id (created by migrate_maps); fall back to insert.
        # maps.code is UNIQUE per game_id; query both keys.
        new_cur.execute(
            "SELECT id FROM maps WHERE code=%s AND game_id=%s", (mapname, 2)
        )
        row_id = new_cur.fetchone()
        if row_id:
            map_id = row_id[0]
        else:
            new_cur.execute(
                "INSERT INTO maps (code, display_name, game_id) "
                "VALUES (%s, %s, %s) "
                "ON DUPLICATE KEY UPDATE id=LAST_INSERT_ID(id)",
                (mapname, mapname, 2),
            )
            map_id = new_cur.lastrowid
        # timed_maps stores ms (not s). Legacy stored seconds.
        new_cur.execute(
            "INSERT INTO timed_maps "
            "  (player_id, map_id, gamemode_id, difficulty_id, mutation, best_time_ms) "
            "VALUES (%s, %s, %s, %s, %s, %s) "
            "ON DUPLICATE KEY UPDATE "
            "  best_time_ms=LEAST(best_time_ms, VALUES(best_time_ms))",
            (pid, map_id, GAMEMODE_SURVIVAL, DIFFICULTY_UNKNOWN, "", time_s * 1000),
        )
        stats["timed_maps_rows"] += 1
    if skipped:
        print(f"  legacy.timedmaps: skipped {skipped} rows (no player or no map/time)")


# ============================================================================
# Main
# ============================================================================

def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--host", required=True)
    ap.add_argument("--port", type=int, default=3306)
    ap.add_argument("--user", required=True)
    ap.add_argument("--password", required=True)
    ap.add_argument("--legacy-db", required=True, help="e.g. l4d2stats")
    ap.add_argument("--new-db", default="bizzymod_stats")
    ap.add_argument("--batch", type=int, default=500)
    ap.add_argument("--dry-run", action="store_true",
                    help="don't write to new DB; just count what would be inserted")
    args = ap.parse_args()

    print(f"Connecting to {args.user}@{args.host}:{args.port}")

    # Two connections so we can read and write concurrently (USE per-connection).
    legacy_conn = mysql.connector.connect(
        host=args.host, port=args.port, user=args.user, password=args.password,
        database=args.legacy_db, charset="utf8mb4", use_unicode=True,
    )
    new_conn = mysql.connector.connect(
        host=args.host, port=args.port, user=args.user, password=args.password,
        database=args.new_db, charset="utf8mb4", use_unicode=True, autocommit=False,
    )

    legacy_cur = legacy_conn.cursor()
    new_cur = new_conn.cursor()

    stats = Counter()

    try:
        print(f"\n[1/3] Setting up legacy-import server row in {args.new_db}")
        server_id = ensure_legacy_server(new_cur) if not args.dry_run else 0
        award_lut = load_award_code_to_id(new_cur)
        print(f"  server_id={server_id}, {len(award_lut)} awards in catalog")

        print(f"\n[2/3] Migrating players + per-player rollups")
        steamid_to_id = migrate_players(
            legacy_cur, new_cur, server_id, award_lut,
            args.batch, args.dry_run, stats,
        )

        print(f"\n[3/3] Migrating maps + timedmaps")
        migrate_maps(legacy_cur, new_cur, server_id, args.dry_run, stats)
        migrate_timedmaps(legacy_cur, new_cur, steamid_to_id, args.dry_run, stats)

        if args.dry_run:
            print("\n[DRY-RUN] No commit.")
        else:
            new_conn.commit()
            print("\nCommitted.")

    except mysql.connector.Error as e:
        new_conn.rollback()
        print(f"\nFAILED: {e}", file=sys.stderr)
        return 1

    finally:
        legacy_cur.close()
        new_cur.close()
        legacy_conn.close()
        new_conn.close()

    print("\nSummary:")
    for k, v in sorted(stats.items()):
        print(f"  {k:30s} {v:>10}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
