# servers/vanilla — scaffold (not built yet)

Placeholder for a plain / vanilla game-mode server. **Nothing deploys from here
yet** — `campaign` is the only wired server.

To stand it up:

1. Populate this folder as a self-contained overlay (mirror `servers/campaign/`).
   Vanilla runs **no** zonemod overlay.
2. Add `servers/vanilla/deploy.env`:
   ```sh
   APPLY_ZONEMOD_OVERLAY=false
   QUARANTINE_MATCHMODE=false
   QUARANTINE_FIXES=""
   SOURCEMOD_VERSION=1.12.x
   ```
3. Add `vanilla` to the `server` input options in `.github/workflows/deploy.yml`.
4. Create the GitHub Environments `vanilla-dev` and `vanilla-prod` with the
   per-target secrets/vars (see `DEPLOY.md`).
