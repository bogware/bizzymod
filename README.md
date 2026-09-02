# BIZZYMOD

> It makes a man watchful… and a little lonely.
>
> There's a stretch of country out past the lobby servers where the law is thin
> and the killers ride easy — griefers, cheats, a Smoker that grabs a man and
> won't pull him in. Somebody's got to hold the line out there. That's my job.
> I run these servers. It's a chancy job, and it makes a man watchful. But I made
> my peace with that a long time ago.

This is the territory: a **monorepo** of Left 4 Dead 2 dedicated-server content.
Every game mode is its own **town** under `servers/`, and every town stands on its
own two feet — nothing borrowed, nothing shared, so trouble in one never rides into
another. Campaign was the first town we tamed. There'll be others.

---

## The Territory

Lay of the land. What ships to a server, what stays home.

```
servers/
  campaign/      the coop town — tamed, hardened, running quiet.  (THIS ships)
  competitive/   a townsite staked out. Nobody's built on it yet. (scaffold)
  vanilla/       same. Open ground.                               (scaffold)
.github/         where the marshal keeps his orders — every workflow, every town
.deploy/         his saddlebags — build + deploy scripts, server-side rigging
.cicd/           the old circuit-court records (Azure DevOps export)
guide/           how a greenhorn stands up his own box from bare dirt
legacy/          boot hill — old code, left where it lies
DEPLOY.md        the strongbox key list
CLAUDE.md        the law of this land, written plain
```

A town — `servers/campaign/` — carries everything it needs: `cfg/` (with
`campaign.cfg`, the one book that says which plugins ride), `addons/` (the whole
outfit, SourceBans and stats and the Bizzymod plugins built from their own `.sp`),
`scripts/` (VScripts), the host and motd files, and a `deploy.env` that tells the
marshal how this particular town likes things done.

---

## Two Towns on the Line

Every mode runs in **two places**, and to the folks passing through they look the
same — both public, both live, both full of strangers.

| | **prod** | **dev** |
|---|---|---|
| the town | `<PROD_HOST>` | `<DEV_HOST>` |
| the road in | ssh `1989`, root | ssh `1989`, root |

`prod` is the town we keep spotless. `dev` we're harder on — we ride in, tear down
whatever fool built something wrong, and put it back the way it ought to be.

---

## The Marshal

There's just one man does the riding: a **self-hosted Linux runner**, wearing the
badges `self-hosted` and `Linux`, registered under the bogware brand. He builds the
plugins and he carries them to town — he's the only one with a horse fast enough to
reach both. He keeps his own tools on his belt (`sshpass`, `rsync`, `curl`, `tar`);
if he's missing one, he'll tell you straight and won't ride till it's fixed.

---

## Riding Out

You don't deploy by accident around here. Nothing rides on its own — no push, no
merge, ever puts a man on the road. You send him, by name, to a town:

```sh
gh workflow run deploy.yml -f server=campaign -f environment=dev
# or saddle up from the Actions tab: Deploy ▸ Run workflow
```

He'll compile the town's plugins, lay the zonemod ground where it's called for —
scraping the old town clean down to the boards first — token the cfgs, drop the
Bizzymod outfit on top, set the locks, and light the lamps. Then he waits five
seconds, looks back down the street, and makes sure `srcds_run` is still standing.
If it isn't, he says so.

The same man rides for two other errands when you call: **`diagnose.yml`** (he
reads the town's logs back to you) and **`migrate-stats.yml`** (he squares the
books — the stats database).

---

## The Strongbox

A marshal doesn't carry the keys in his pocket where any pickpocket can lift them.
Each town's keys — the SSH password, the RCON, the sudo — live locked in that
town's **GitHub Environment** (`campaign-prod`, `campaign-dev`), same names, kept
apart. The bank ledgers — the shared stats and SourceBans database creds — those
are held once, repo-wide, since every town banks at the same house.

The full list of what goes in the strongbox, and where, is written in
**[`DEPLOY.md`](DEPLOY.md)**. Read it before you set a single key.

---

## Trouble on the Line

Word came down the wire the Smokers had gone bad — grabbing a man and never
dragging him in. Wasn't the difficulty, wasn't the rates. It was three
competitive tongue plugins zonemod ships, meddling where they had no business in a
coop town. We ran them out. `campaign.cfg` keeps them out for good now. A town's
only as quiet as the last piece of trouble you handled.

---

## The Law of the Land

Every rule that keeps this territory from going wild — coop stays coop, towns stay
self-contained, tokens stay tokens, line-endings stay honest — is written down
plain in **[`CLAUDE.md`](CLAUDE.md)**. A man rides in not knowing the law, he reads
that first.

> Now I don't know that there's a moral to any of it. Out here you do your job, you
> keep the town standing, and you ride out again. That's about all a man can say.
