# servers/competitive — scaffold (not built yet)

Placeholder for the competitive / zonemod game-mode server. **Nothing deploys
from here yet** — `campaign` is the only wired server.

To stand it up:

1. Populate this folder as a self-contained overlay (mirror `servers/campaign/`:
   `addons/`, `cfg/`, `scripts/`, `host.txt`/`motd.txt`/`myhost.txt`/`mymotd.txt`).
   Competitive keeps zonemod's matchmode plugins **loaded**.
2. Add `servers/competitive/deploy.env`:
   ```sh
   APPLY_ZONEMOD_OVERLAY=true
   ZONEMOD_RELEASE_TAG=v1.0.0
   QUARANTINE_MATCHMODE=false      # competitive WANTS matchmode
   QUARANTINE_FIXES=""
   SOURCEMOD_VERSION=1.12.x
   ```
3. Add `competitive` to the `server` input options in
   `.github/workflows/deploy.yml`.
4. Create the GitHub Environments `competitive-dev` and `competitive-prod` with
   the per-target secrets/vars (see `DEPLOY.md`).
