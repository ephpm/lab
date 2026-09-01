# The Source Tier (`scale/`) — multi-tenant scaling and overload

> **Provenance.** Imported from
> [`ephpm/multitenant-scalebench`](https://github.com/ephpm/multitenant-scalebench)
> @ `8e7e8544f11a4f7e7363393dbc2ab40939872fab`; the results referenced by the
> reports under [`reports/`](reports/) were **recorded there**, on the exact
> from-source binaries their provenance tables name. The reports
> (REPORT, BEFORE-AFTER, ENGINE-COMPARISON, SHEDDING, LKE-SIZING) are imported
> **as-is, errata included** — history is not rewritten here; new runs get new
> documents. In this layout the original repo's `report/` directory is
> [`reports/`](reports/), and `results/` is gitignored (raw JSON from your own
> re-runs stays local, per the lab's convention).
>
> **This is the lab's third provenance class — the source tier.** The k6/LKE
> suites (`k8s/`) measure **published images on a cluster**; the db suites
> (`DB-BENCH.md`) measure **published images under podman**; this tier measures
> a **from-source binary on a bare host (WSL2 dev box)**. Numbers from this
> tier must **never appear in the same table** as numbers from the other two —
> the same never-same-table rule the lab already enforces between its db and
> k6 tiers, extended to three classes.

# multitenant-scalebench — how much does one ePHPm instance cost per WordPress site?

A re-runnable lab benchmark that measures the CPU, memory, and throughput of a
**single ePHPm instance serving N WordPress sites** under concurrent load, for
N = 10, 25, 50, 100, 250, 500, 1000.

It exists to put numbers on the cost of ePHPm's **v0.7.0 per-site
multi-tenancy** — per-site Turso database (#284), per-vhost temp/session dirs
(#285), the open-database LRU (`max_open_dbs`), per-site KV — so someone sizing
a multi-tenant or PR-preview host can answer "how many sites fit on this box?"

> Numbers here are **dev-box / WSL2** figures (32 vCPU, 62 GB, WSL2 on Windows,
> ext4 on a native VHD — *not* `/mnt/c`). They are a **relative** scaling model,
> not a datacenter SLA. See [Honesty](#honesty).

## What it measures

For every `(max_open_dbs, N)` point it stands up one fresh ePHPm instance
serving exactly N vhosts (`site-0001` … `site-<N>`) off **one shared read-only
docroot**, each vhost with its **own** Turso database at `<db.dir>/<site>.db`,
then drives concurrent round-robin traffic across all N vhosts and records:

* **Memory** — steady RSS and peak RSS (`VmHWM`) of the ephpm process.
* **CPU** — mean/peak cores at steady state under load.
* **Throughput / latency** — aggregate RPS, p50/p95/p99, status mix.
* **File descriptors** — max open fds (the 1000-sites × WAL-fd budget).

## The two knobs under test

* **N** — number of tenant sites. Shared code (realistic: production runs
  identical WP core across tenants, and it exercises the **shared opcache** the
  way production would); the per-site divergence is the **database**.
* **`max_open_dbs`** — the LRU cap on simultaneously-open per-site databases
  (default **256**). The sweep runs each N at the default **and** a raised cap
  (**4096**) to expose the central tradeoff: *does RSS stay bounded by the LRU
  as N grows past the cap, and what does the open/evict churn cost in CPU and
  latency?*

## Two workloads

| Workload | What it is | Why | Reaches |
|----------|-----------|-----|---------|
| **wp-lite** (default) | A WordPress-*shaped* front controller (`workloads/wp-lite`) doing the ~20-query front page / single-post / REST pattern against the per-site DB via the `ephpm_db_*` bridge. **Not** WordPress. | Lets the sweep reach N=1000 without provisioning 1000 real WP installs, while still exercising the multi-tenant path that matters (site-key → per-site DB open / LRU hit-miss → ~20 reads). | 1000 |
| **wp-real** | Real WordPress core + the [`ephpm/db-wordpress`](https://github.com/ephpm/db-wordpress) drop-in (`wp-content/db.php` → `ephpm_db_*` → per-site Turso DB), one seeded install copied to all N sites with a dynamic-host `wp-config.php`. | Anchors the *real* per-request cost at lower N. | see report |

Both are driven by the **same** load generator and request mix, so the wp-lite
curve and the wp-real anchor are directly comparable.

## Layout

```
config/ephpm.tmpl.toml   server config template (sites_dir, db.sqlite dir, max_open_dbs, wire port)
workloads/wp-lite/       seed.php + index.php — the WP-shaped bridge workload
workloads/wp-real/       dynamic-host wp-config.php + install notes for real WordPress
loadgen/                 Go load generator: round-robin Host across N vhosts, mixed paths, latency percentiles
scripts/provision.sh     symlink N vhosts to one shared docroot
scripts/sample.sh        /proc sampler: RSS (steady/peak), CPU cores, fd count
scripts/seed_wp_real.sh  drive the WordPress web installer once (wp-real only)
scripts/run_sweep.sh     the orchestrator — build, template, seed, load, measure, per (cap,N) point
reports/report.go         turn results/*.json into a Markdown table + ASCII scaling curves
results/<workload>/      one merged JSON per (cap,N) point
reports/REPORT.md         the writeup: tables, curves, resource model, capacity takeaway
```

## Running it

Prerequisites: a **php_linked release** ephpm binary (`cargo xtask release 8.5`
from ephpm `origin/main`), Go, and a WSL-native run directory (the per-site
Turso files and KV socket cannot live on DrvFs / `/mnt/c`).

```bash
export BIN=/path/to/target/x86_64-unknown-linux-gnu/release/ephpm
export RUN=~/ephpm-scalebench-run          # MUST be WSL-native, not /mnt/c
export NS="10 25 50 100 250 500 1000"
export CAPS="256 4096"                      # default LRU cap and a raised cap
export C=$(( $(nproc) * 4 ))                # concurrency
export WARMUP=8 DUR=20
bash scripts/run_sweep.sh                    # wp-lite by default

# real WordPress anchor at lower N:
export WORKLOAD=wp-real WP_DOCROOT=/path/to/wordpress-with-dropin
export NS="10 25 50 100"
bash scripts/run_sweep.sh

# build the report from results:
cd reports && go run . -dir ../results/wp-lite > REPORT.md
```

`WIREPORT` (default 13306) moves the per-site MySQL wire listener off 3306 so
concurrent instances don't collide — multi-tenant mode starts that listener
even when only the `ephpm_db_*` bridge is used.

## Honesty

* **Dev-box / WSL2 numbers.** 32 vCPU, 62 GB, WSL2. RPS ceilings and absolute
  RSS will differ on bare metal / in a container with cgroup limits. Treat the
  **shape** (RSS-vs-N, the LRU inflection at N > cap) as the result, not the
  absolute RPS.
* **LTO / build profile:** the binary is the stock `cargo xtask release` profile
  (see `reports/REPORT.md` for the exact commit and profile) — **not** a
  hand-tuned LTO build.
* **wp-lite is not WordPress.** It is deliberately WP-*shaped*. Where the report
  gives a 1000-site number from wp-lite and a lower-N number from real WP, both
  are labeled; the wp-lite curve is not silently presented as WordPress.
* **Measured vs extrapolated:** the report never draws a curve past the largest
  N actually run without labeling it.
