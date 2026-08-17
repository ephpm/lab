# ePHPm Lab

Author: Benjamin Pace

A reproducible Kubernetes lab for people deciding whether ePHPm belongs in their PHP deployment. It compares published ePHPm PHP 8.4 images (`v0.5.0` and the current worker retest on `v0.6.0`) with the official PHP 8.4 FPM image and nginx across small scripts, synthetic apps, Krayin CRM, Laravel, Redis/Predis, ePHPm native KV, worker mode, and clustered OPcache invalidation.

> This is not "ePHPm beats PHP-FPM." It is "ePHPm can beat PHP-FPM when the app and deployment model are adapted to ePHPm's worker/native-service architecture."

## Relationship to ePHPm v0.7.0

> **Historical (pre-v0.7.0).** The database suites pin `ephpm/ephpm:v0.6.3` and
> parts of them exercise machinery that **no longer exists upstream**. ePHPm
> v0.7.0 removed the rusqlite engine (`[db.sqlite] engine = "sqlite"` is now a
> **hard startup error**), the sqld sidecar, the `[db.sqlite.sqld]
> write_permits` admission knob, and the `cdc_experimental` knob; Turso is the
> only embedded engine and clustered replication runs over the in-process Turso
> CDC path. The `engines`, `admission`, and sqld-cluster lanes in
> [DB-BENCH.md](DB-BENCH.md) therefore run only against the pinned v0.6.3
> image and **will not run against v0.7.0+ images**. Their recorded numbers are
> retained as the parity evidence behind the engine switch — the same way
> ePHPm's own [benchmarking results page](https://ephpm.dev/benchmarking/results/)
> marks those sections historical.

## The Numbers

### Laravel Cache Workload

At `20 iterations/s` for `75s`, the persistent ePHPm worker plus native KV was the fastest path for average, median, and p95 latency. The short run also produced a worse p99 than request mode, so the chart should be read as a strong signal, not a promise about every tail percentile.

![Laravel cache workload latency comparison](docs/assets/laravel-v4-latency.svg)

### Medium-Traffic Pressure Test

At `160 iterations/s` for `45s`, ePHPm worker mode stayed close to the target rate while PHP-FPM plus Redis/Predis could only sustain about 100 iterations/s. Both runs had zero HTTP failures; the visible difference is scheduled work that could not start in time.

![Laravel pressure test throughput comparison](docs/assets/laravel-v4-rate160.svg)

### Krayin CRM, Three Ways

Krayin is the useful reality check. In a real Laravel CRM at `8 iterations/s` for `75s`, ePHPm request mode was slightly behind PHP-FPM. Adding the Octane-style ePHPm worker changed the result: it completed the most work and had the lowest average latency, while PHP-FPM retained the best p95 and p99.

![Krayin three-way comparison](docs/assets/krayin-v3b-three-way.svg)

### WordPress / WooCommerce v5

The current, fair comparison uses the same plugin-heavy fixture, MySQL database, `8 iterations/s` for `120s` k6 profile, and a dedicated four-vCPU LKE node. Each application lane ran alone. PHP-FPM used nginx, `phpredis`, and Redis; ePHPm request and worker modes used native KV.

| Lane | Completed | Dropped | Average | p95 | HTTP failures |
| --- | ---: | ---: | ---: | ---: | ---: |
| PHP-FPM/nginx/Redis | 953 | 8 | 414ms | 1.11s | 0% |
| ePHPm request/native KV | **960** | **0** | **192ms** | **246ms** | 0% |
| ePHPm worker/native KV | 730 | 231 | 2.05s | 8.94s | 0% |

In this one sequential dedicated-node run, ePHPm request mode was the fastest valid lane. PHP-FPM is close in sustained rate and remains the stronger boring-production default. The result needs randomized repeated runs, alternating lane order, and a production-like cache mix before it should influence an adoption decision. ePHPm worker mode now passes the two-user WooCommerce cart-isolation gate and is stable under load, but it needs a dedicated worker-count sweep before it is a competitive throughput option. The [follow-up investigation](docs/wordpress-worker-investigation.md) preserves the original functional failures, fixes, and capacity evidence.

![WordPress WooCommerce normal-request comparison](docs/assets/wordpress-v5-browse.svg)

### The Database Path

Measured on a different tier from everything above: one host, podman, `--cpus 1`,
`oha`. The effects here are microseconds wide, so a cluster run would be less
sensitive, not more realistic. Never read these next to a k6 number.

ePHPm's database proxy inserts an extra wire hop between PHP and the database in
order to pool backend connections. Both halves of that trade are now measurable
— on v0.6.0 they were not, because two pool defects made every pooled lane
return HTTP 500 at 876 requests per second:

| `db.php` (10 sequential SELECTs), c=1 | RPS | p50 |
| --- | ---: | ---: |
| PHP → litewire, no proxy | 323 / 323 | 3.05 ms |
| PHP → proxy (no reuse) → litewire | 218 / 217 | 4.53 ms |
| PHP → proxy (pooled) → litewire | 249 / 249 | 3.97 ms |

The middle row is the honest cost of the hop: about 1.5 ms per request. The
bottom row is what reusing an authenticated backend session gives back — some
of it, not all. At c=1 the proxy is still a net loss on the MySQL wire
(−19 % to −23 % vs no proxy at all).

At c=16 it inverts: litewire +44 %, `mysql:8` +36 %, `postgres:16` +117 %. The
proxy buys **concurrency headroom, not single-request latency**. PostgreSQL is
the exception that wins at both, because the proxy takes a per-request
SCRAM-SHA-256 handshake off PHP — the direct PG path does not scale at all
(104 → 97 RPS from c=1 to c=16).

The full four-upstream matrix, the two pool defects, and the PostgreSQL
pool-exhaustion cliff that v0.6.1 removed are in
[the v0.6.1 database matrix](docs/ephpm-0.6.1-db-matrix.md).

### v0.7.0 Verification Runs (source tier)

Three recorded suites on a from-source ephpm main binary (`180d0ac`,
sha256-pinned in each doc) — source-tier provenance, never comparable with the
image-pinned numbers above:

- **[shed-verify](docs/shed-verify-v070.md)** — the open-loop overload matrix
  from the imported SHEDDING report, re-run on the post-fix binary: zero
  SIGABRTs in 10 floods (was 3/10), `overload_policy = "shed"` converts 100%
  of excess arrivals into 503s answered in p50 1.7 ms with **zero client
  timeouts and full capacity retained as goodput**; the default-config black
  hole and the deep-flood spawn_blocking wedge still reproduce (the remedy is
  opt-in config / the preview preset).
- **[kv-micro](docs/kv-micro-v070.md)** — first measurement behind the KV
  guide's published numbers: `ephpm_kv_get` ≈ 116 ns at 64 B (the "~100 ns"
  claim holds for small gets; sets ≈ 160 ns; 64 KB is copy-bound at 1–2 µs);
  RESP round-trips 79–111 µs (inside the guide's "10–100 µs" band, but pinned
  to its top end on this host).
- **[containment-tax](docs/containment-tax-v070.md)** — `crash_containment`
  A/B: happy-path deltas −0.4%…+0.8% (inside noise — "performance-free"
  verified); a 500-crash storm: 500/500 contained, exact counter/log
  accounting, concurrent traffic p99 0.86 ms with 0 errors, and the bounded
  leak quantified at **~857 KB RSS per contained crash**.

### Clustered OPcache Invalidation

One `ephpm deploy` invalidated OPcache across two ePHPm pods without rolling PHP processes. The PHP-FPM comparison used a rolling restart, which remained available but took longer at every recorded latency percentile.

![OPcache invalidation latency comparison](docs/assets/opcache-invalidation.svg)

## Match Your App

| Your deployment shape | What this lab says | Why |
| --- | --- | --- |
| Arbitrary PHP app as a drop-in replacement | Start with PHP-FPM | ePHPm request mode is not a universal performance win. |
| Laravel or another framework in normal request mode | Test both | Krayin request mode favored FPM; the synthetic Laravel request path was competitive. |
| Persistent Laravel / Octane-style worker | Worth serious testing | Worker mode improved Krayin and won the Laravel cache workload. |
| Plugin-heavy WordPress/WooCommerce in normal request mode | Promising; reproduce against your store | One sequential dedicated-node run favored ePHPm request mode, but it needs randomized repeated runs and a production-like cache mix before it supports an adoption claim. |
| WooCommerce storefront in ePHPm worker mode (`v0.5.0`) | Functionally valid; tune before adoption | The cart gate and HTTP correctness pass, but four workers did not sustain the 8/s target. |
| Cache-heavy hot paths that can use native ePHPm KV | Strongest lab signal, not a universal result | Avoiding the FPM-to-Redis/Predis path produced the clearest advantage; PHP-FPM with `phpredis` remains a required fairness rerun. |
| Clustered app with deploy-time OPcache invalidation | Strong ePHPm operational case | One deploy signal invalidated the cluster without a PHP process rollout. |
| Need maximum production familiarity today | PHP-FPM remains king | Extension expectations, documentation, and operator experience still matter. |

## Benchmark Map

| Test | Workload | Compared shapes | Result |
| --- | --- | --- | --- |
| v1 | Tiny PHP routes | PHP-FPM/nginx vs ePHPm request | ePHPm won average latency; too small to drive a platform decision. |
| v2 | Synthetic front controller | PHP-FPM/nginx vs ePHPm request | ePHPm won average and p95. |
| v3 | Krayin CRM request mode | PHP-FPM/nginx vs ePHPm request | PHP-FPM won. |
| v3b | Krayin CRM worker mode | PHP-FPM/nginx vs ePHPm request vs ePHPm worker | Worker led completed work and average latency; FPM had the best p95/p99. |
| v4 | Cache-heavy Laravel | FPM/Redis/Predis vs ePHPm request/native KV vs ePHPm worker/native KV | Worker mode won average, median, and p95 at the baseline rate. |
| v4 pressure | Same Laravel workload | FPM/Redis/Predis vs ePHPm worker/native KV | ePHPm worker held `159.27/s` of a `160/s` target; FPM held `100.02/s`. |
| OPcache | Two-pod deploy invalidation | ePHPm deploy vs FPM rolling restart | ePHPm won latency and avoided rolling PHP processes. |
| v5 dedicated | Plugin-heavy WordPress/WooCommerce browse | FPM/nginx/phpredis/Redis vs ePHPm request/native KV vs ePHPm worker/native KV | ePHPm request led: 960 completed, zero drops, 192ms average, 246ms p95. FPM sustained the rate closely; worker needs tuning. |
| db engines | 10 sequential PDO queries / 1 INSERT | ePHPm SQLite vs Turso, single-node vs clustered sqld | Single-node is sound; clustered sqld completed zero requests at 16 concurrent writes until `write_permits = 1` (v0.6.1). |
| db proxy | Same fixtures, four upstreams | ePHPm DB proxy pooled vs unpooled vs no proxy | Hop costs 1.3–2.2 ms; pooling wins at c=16, loses at c=1 on the MySQL wire. Two v0.6.0 pool defects fixed in v0.6.1. |

Raw data, workload details, and the original test narrative live in [the WordPress v5 report](docs/wordpress-v5.md), [the 0.4.0 retest report](docs/ephpm-0.4.0-retest.md), [the OPcache follow-up](docs/follow-up-opcache.md), [the v0.6.1 database matrix](docs/ephpm-0.6.1-db-matrix.md), and [the chronological lab report](docs/ephpm-vs-php-fpm-lab-report.md).

## Reproduce It

The manifests are plain Kubernetes YAML and the load generator is k6. Start with the [reproduction guide](docs/reproduction.md) for the exact sequence, then inspect the [manifest map](k8s/README.md) for the workload files.

The database suites are the exception: they run on a single host under podman, because the effects they measure are tens of microseconds wide and cluster jitter is larger than the signal. See [DB-BENCH.md](DB-BENCH.md) for that tier and `./scripts/run-db-bench.sh` to drive it. Never put a number from that tier in a table with a k6 number from `k8s/`.

There is a third tier: [`scale/`](scale/README.md), the **source tier** — multi-tenant N-sites scaling, memory/fd models, engine comparison, and open-loop overload behavior, measured on a **from-source ePHPm binary on a bare host** (imported from [ephpm/multitenant-scalebench](https://github.com/ephpm/multitenant-scalebench), which remains the historical record of its results). **Never compare its numbers against the image-pinned tiers**: three provenance classes (published image on k8s, published image under podman, from-source on bare host), three separate tables, always.

## What Comes Next

- Run a worker-count sweep on the dedicated node, then repeat the three-way WordPress comparison at the tuned worker count.
- Add WordPress variations with an importer-generated catalog, a page-builder-heavy home page, and logged-in/cart paths.
- Drupal, Symfony, and additional representative Laravel applications.
- PHP-FPM with `phpredis`, not only Predis/TCP.
- Larger nodes and Metrics API data so latency can be connected to CPU and memory behavior.
- Ten to thirty minute runs, multiple worker counts, and restart/failure testing for persistent workers.
- A direct Octane, Swoole, RoadRunner, and ePHPm comparison.

## Traps That Taint A Run

Documented mistakes that produced confidently wrong numbers before they were
caught. Check them before trusting any measurement from this repo:

- **The server's working directory must be on a native filesystem.** A
  from-source ePHPm launched with its cwd (or state dir) on a WSL DrvFs mount
  (`/mnt/c/...`) pays a 9p syscall penalty on the hot request path that
  silently cost **~3.8×** throughput on light workloads — same binary, same
  config, 4,164 vs 15,900 RPS — and mislabelled a mutex-contention story
  before the erratum landed (see the BEFORE-AFTER erratum in
  [ephpm/multitenant-scalebench](https://github.com/ephpm/multitenant-scalebench)).
  Assert the cwd/state filesystem is native (ext4 in WSL2, not `/mnt/*`)
  before measuring.
- **Check the status-code distribution before trusting a throughput number.**
  The image's default config ships a per-IP rate limit that clamps a
  single-IP load generator (see `RUNTIMES-BENCH.md`), and `oha` counts an
  HTTP 500 as a transport success — three proxy lanes once recorded 876 RPS
  of pure 500s (see `DB-BENCH.md`, gate 5).

## Caveats

This is a reproducible lab, not a universal benchmark. Earlier phases used three small `g6-standard-1` LKE nodes; the current WordPress three-way rerun used a dedicated four-vCPU node and Metrics Server. The manifests generate applications in init containers, and the Krayin benchmark credentials are throwaway test-only credentials. The public repo intentionally omits kubeconfigs, tokens, local environment files, built images, and upstream source checkouts. See [the WordPress v5 report](docs/wordpress-v5.md) before applying these numbers to a production decision.

## Repository Layout

| Path | Purpose |
| --- | --- |
| `docs/` | Results, methodology, history, and reproduction instructions. |
| `docs/assets/` | Rendered comparison charts used by this README. |
| `k8s/` | Kubernetes manifests and k6 jobs for each benchmark phase. |
| `scale/` | The source tier: multi-tenant scaling / overload harness and its recorded reports, imported from ephpm/multitenant-scalebench. Never table its numbers with the image-pinned tiers. |
| `kv/` | kv-micro suite: `ephpm_kv_*` SAPI ns/op and RESP µs/op (source tier). |
| `containment/` | containment-tax suite: `crash_containment` happy-path A/B and crash-storm lanes (source tier). |
| `wordpress-v5/` | Account-free WordPress/WooCommerce fixture, seed scripts, and k6 probes. |
| `patches/` | Local patch retained from an older source-built worker-mode experiment. |
| `scripts/` | Helper scripts retained from earlier source-build experiments and v4 worker runs. |

## License

This lab repository is licensed under the MIT License, matching ePHPm.
