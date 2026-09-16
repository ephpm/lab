# Auto-pinning ePHPm to the latest published release

The lab pins ePHPm by **Docker image tag** (no digests). Some of those pins are
**active** — they should always track the newest published `ephpm/ephpm`
version — and some are **historical** and must never move (bumping them breaks
the code paths they exercise or falsifies recorded numbers).

`.github/workflows/pin-ephpm.yml` keeps the active pins current by opening a PR
whenever a newer version appears. It never touches the historical suites.

## The moving parts

| File | Role |
|------|------|
| `.github/ephpm-active-pins.txt` | The **manifest** — the single source of truth for which files (and which shell variables) are active. Anything not listed is never modified. |
| `.github/scripts/bump-ephpm-pin.sh` | The **bump script** — deterministic edits, `--dry-run` and `--version X.Y.Z` modes, idempotent. |
| `.github/workflows/pin-ephpm.yml` | The **workflow** — resolves the target version, runs the script, opens/updates a PR. |

## What counts as "latest"

The script determines the latest version from **Docker Hub**, not GitHub
Releases. A known dind CI bug in `ephpm/ephpm` means images can publish without
a corresponding Release, so Releases are an unreliable signal. "Latest" is the
newest semver tag on `https://hub.docker.com/v2/repositories/ephpm/ephpm/tags`
for which **both** the `-php8.4` and `-php8.5` variants exist (k8s pins use
php8.4, the DB cluster suite uses php8.5).

## What the bump script edits — and what it never touches

Active (bumped, `-php<minor>` suffix preserved):

- The 12 k8s manifest image pins in `k8s/*.yaml` (`ephpm/ephpm:vX-php8.4`).
- The DB **cluster** suite pins: `IMG` in `db/bench-cluster.sh` and
  `CURRENT_IMAGE` in `scripts/run-db-bench.sh` (`-php8.5`).
- "Current pin" prose in `README.md`, `RUNTIMES-BENCH.md`,
  `k8s/OPCACHE-CLUSTER.md`.

Never touched (historical, by design):

- Pre-v0.7.0 rusqlite/sqld scripts: `db/bench-{engines,proxy,bridge,wordpress-bridge,admission}.sh`, `db/probe-*.sh` (`v0.6.3`).
- `scripts/run-db-bench.sh`'s `HISTORICAL_IMAGE` variable — the file is listed
  for `CURRENT_IMAGE`, but `HISTORICAL_IMAGE` is protected two ways: it is not
  the named variable, and the script skips any line containing `HISTORICAL_IMAGE`.
- Recorded-result markdown: `DB-BENCH.md`, `docs/*`, `scale/reports/*`.
- `rr/Dockerfile` (RoadRunner competitor image, not ePHPm).

Belt-and-suspenders: the script skips any line containing `HISTORICAL_IMAGE` or
the literal marker `ephpm-pin:historical` (`<!-- ephpm-pin:historical -->` in
markdown), even inside a listed file. Use that marker to freeze a single pin
inside an otherwise-active file.

## Running it by hand

```sh
# Show what would change against the latest published version (writes nothing):
.github/scripts/bump-ephpm-pin.sh --dry-run

# Dry-run against a specific version:
.github/scripts/bump-ephpm-pin.sh --dry-run --version 0.11.0

# Actually apply (the workflow does this, then opens a PR):
.github/scripts/bump-ephpm-pin.sh --version 0.11.0

# Just print the resolved latest version:
.github/scripts/bump-ephpm-pin.sh --print-version
```

Requires `curl` + `jq` for the Docker Hub query (both preinstalled on
`ubuntu-latest`); `perl` does the byte-exact edits (line endings preserved).

## Triggers

- **`schedule`** — daily at 06:17 UTC. Zero extra auth; covers everything on its
  own.
- **`workflow_dispatch`** — manual run, with an optional `version` input.
- **`repository_dispatch`** (`types: [ephpm-released]`) — an optional immediacy
  hook (see below).

## Review, not auto-merge

The workflow opens a PR for review rather than auto-merging. The
active/historical distinction and bench-pin changes deserve a human glance. To
enable auto-merge later, add a `gh pr merge --auto --squash` step after the
create-PR step (repo settings must allow auto-merge), or wire the branch into a
ruleset that auto-merges.

The `peter-evans/create-pull-request` action is **pinned by commit SHA**
(`22a9089034f40e5a961c8808d113e2c98fb63676` == v7.0.11) for supply-chain
hygiene — the same discipline `cargo deny` enforces on Rust dependencies.

## Optional: instant pinning via `repository_dispatch`

The scheduled daily poll needs no extra setup and no cross-repo credentials.
This repo's PR is intentionally scoped to the lab only.

If you want the lab to pin the *instant* an image publishes, `ephpm/ephpm`'s
release pipeline can send a `repository_dispatch` to this repo:

```sh
curl -X POST \
  -H "Authorization: Bearer $LAB_WRITE_TOKEN" \
  -H "Accept: application/vnd.github+json" \
  https://api.github.com/repos/ephpm/lab/dispatches \
  -d '{"event_type":"ephpm-released","client_payload":{"version":"0.11.0"}}'
```

This requires a **lab-write token** stored as a secret in `ephpm/ephpm` (the
built-in `GITHUB_TOKEN` there cannot write to another repo). That change lives
in the `ephpm/ephpm` release pipeline and is **not** made here — the scheduled
poll already covers the need with zero extra auth. If `client_payload.version`
is omitted, the workflow falls back to the Docker Hub poll.
