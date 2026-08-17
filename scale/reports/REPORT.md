# Multi-tenant scaling report — one ePHPm instance, N WordPress sites

**What this is:** the cost, in CPU / memory / throughput, of ePHPm's v0.7.0
per-site multi-tenancy (per-site Turso DB #284, per-vhost temp/session #285, the
open-database LRU) as one instance goes from 10 to 1000 tenant sites under
concurrent load.

> ## ⚠ ERRATUM (2026-08-15): the original throughput and CPU numbers were
> ## harness-tainted — read this first
>
> Validation of ePHPm PR #303 found that `scripts/run_sweep.sh` launched the
> server with a **DrvFs (`/mnt/c`) working directory**. A DrvFs cwd puts a 9p
> syscall penalty on the hot request path: with the **same binary, config, and
> provisioned state**, the warm wp-lite point measured **4,164 RPS with a
> `/mnt/c` cwd vs 15,900 RPS with a native ext4 cwd (~3.8×)**. Every
> throughput, latency, and CPU figure in the original tables below carried
> that handicap; the "~4.7k RPS plateau at ~5 of 32 cores = per-site registry
> mutex" story built on them is **wrong** — the plateau was the harness, not
> the registry. The harness is fixed (the server now starts with a WSL-native
> cwd, commit `e92483e`), and the re-based numbers live in
> [`report/BEFORE-AFTER.md`](BEFORE-AFTER.md). Corrected headlines, measured
> on the fixed harness (medians of 3 interleaved runs each):
>
> * **Warm multi-tenant wp-lite (N=250, cap=4096): ~14.9k RPS at ~16.5 of 32
>   cores** on the pre-#303 binary (`b9f56db`), **~18.9k RPS at ~22.8 cores**
>   on current `main` (`a634dff`, with #303's sharded registry) — not ~4.6k
>   at ~5 cores.
> * **The past-cap churn collapse was real** (it was mutex/LRU serialization,
>   not DrvFs): N=500 at cap=256 still measures ~1.44k RPS at ~2.1 cores on
>   the pre-#303 binary. #303 lifts it to **~3.3k RPS (+132%)**.
> * **wp-real (real WordPress) was essentially untainted** — it is CPU-bound,
>   so the per-request DrvFs penalty was lost in WP's own cost: corrected
>   ~270 RPS at ~28 cores → **~9.5–9.7 req/s/core (~105 ms CPU/request)**,
>   confirming the published 9–10 req/s/core sizing figure.
> * **What still stands unchanged:** the RSS-per-open-site and fd-per-open-site
>   models (~2.2 MB/site, ~2 fd/site — fd max 641 reproduced exactly at
>   N=250), the LRU bounded-vs-linear memory tradeoff, the 0-error/100%-2xx
>   correctness record, and every *shape* claim (flat under cap, collapse past
>   cap, linear RSS with cap ≥ N).
>
> Original text is left below for the record; tainted claims are annotated
> inline with **[ERRATUM: …]** notes.

## TL;DR

* Under the **default `max_open_dbs = 256`**, one ePHPm instance serves up to
  ~250 always-warm sites at a ~~flat ~4.6–4.8k RPS~~ **[ERRATUM: ~14.9k RPS
  (pre-#303) / ~18.9k RPS (main) on the fixed harness]** on the front-page
  workload, using **~1.2 GB RSS** and ~~**~5 of 32 cores**~~ **[ERRATUM:
  ~16.5–22.8 cores — the ~5-core figure was the DrvFs handicap]**. RSS grows
  **~2.2 MB per open site**; fds grow **~2 per open site** (both re-verified).
* Past the cap the LRU does exactly its job: at **N = 1000, cap = 256** RSS stays
  **bounded at ~1.5 GB** and fds at **~790** — but throughput **collapses to
  ~1.3–1.4k RPS** and CPU *drops* to ~2.2 cores, because every request now churns
  the open/evict path through a single registry mutex. **[Confirmed on the fixed
  harness at N=500: ~1.44k RPS, ~2.1 cores — this collapse was real, not a
  harness artifact. The collapse is now ~4.5× (from ~15k, not from ~4.7k), and
  ePHPm #303 (sharded registry) lifts the churn point to ~3.3k RPS.]**
* Raise the cap so every site stays open (**cap = 4096**) and throughput at
  **N = 1000 holds** ~~at ~4.5k RPS~~ **[ERRATUM: the absolute level was
  harness-capped; at N=250 the fixed harness measures ~14.9k/18.9k RPS — the
  N=1000 point was not re-run, but the *flat-past-250* shape stands]** — but RSS
  scales **linearly to ~2.9 GB** and fds to **~2141**. That is the whole
  tradeoff: **memory-bounded-but-throttled** vs **fast-but-linear-memory**.
* **Real WordPress (wp-real anchor, N≤50) is CPU-bound, not mutex-bound:**
  ~250–270 front-page RPS pins **~27–28 of 32 cores** → **≈ 9–10 req/s per
  core** (~105 ms CPU/request) — re-confirmed on the fixed harness (~270 RPS,
  ~28 cores, ~9.5–9.7 req/s/core; wp-real was essentially untainted because WP's
  own CPU cost dwarfed the DrvFs penalty). ~~~1.8 GB RSS~~ **[ERRATUM: the
  corrected steady RSS at N=50, C=128 is ~2.9–3.4 GB with the default
  spawn_blocking engine (one in-flight PHP context per concurrent request); the
  original ~1.8 GB was a low outlier run. The `pool` engine cuts this to well
  under 1 GB — see BEFORE-AFTER.md.]** This is the number to size real tenants
  on — one 32-core box tops out near ~250–300 real-WP front-page RPS; throughput
  scales with cores.
* **We reached 1000 sites** with the WP-shaped `wp-lite` workload, cleanly, 0
  errors, 100% 2xx at every point. The ceiling we hit was **not** file
  descriptors (`ulimit -n` was 1,048,576; peak use 2,141) and **not** memory
  saturation (peak 3 GB on a 62 GB box) — it was ~~the **per-site registry
  mutex** (throughput) and, at the default cap, **LRU open/evict churn**~~
  **[ERRATUM: below the cap the ceiling was the *harness* (DrvFs cwd), not the
  registry mutex; past the cap it really was mutex/LRU churn. On the fixed
  harness the warm ceiling is ~15–19k RPS at 16–23 cores.]**

## Setup

| | |
|---|---|
| Binary | ePHPm `origin/main` @ `3352445` (v0.7.0, Turso-only), PHP **8.5.7**, ZTS |
| Build | stock `cargo xtask release 8.5` — **no** hand-tuned LTO; release profile as shipped |
| Host | WSL2 on Windows 11, **32 vCPU**, 62 GB RAM, run dir on **ext4 (native VHD)** — not `/mnt/c` |
| Server | `php.mode = fpm` (per-request; worker mode is unsupported with `sites_dir`), `memory_limit = 256M` |
| Workload | **wp-lite** — a WordPress-*shaped* front controller (~20 read queries/front page) hitting each site's own Turso DB via the `ephpm_db_*` bridge. Shared docroot across all N vhosts (shared opcache); per-site divergence is the database. |
| Load | Go generator, **concurrency 128** (4× cores), round-robin Host across all N vhosts, mix 3:1:1 front / permalink / REST, 8 s warmup + 20 s measured per point |
| Content | modest: 12 posts/pages + meta/terms per site |

Every `(cap, N)` point is a **fresh instance serving exactly N sites**, seeded
from one template DB copied N times.

## Results — wp-lite

**[ERRATUM: every RPS / latency / CPU value in the two tables below is
DrvFs-tainted (~3.8× low on throughput below the cap; CPU misleadingly flat at
~5 cores). The RSS, fd, 2xx, and error columns are valid — the resource sampler
read `/proc` directly and the memory/fd behavior does not depend on the cwd.
Corrected throughput/CPU numbers at the re-measured points are in
`BEFORE-AFTER.md`. Tables kept for the record.]**

Host: 32 cores, concurrency 128, `ulimit -n` 1,048,576.

### max_open_dbs = 256 (default)

| N sites | RPS | p50 ms | p95 ms | p99 ms | RSS steady MB | RSS peak MB | CPU cores | fd max | 2xx | err |
|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| 10 | 4803 | 26.6 | 28.3 | 29.6 | 676 | 712 | 4.99 | 161 | 96060 | 0 |
| 25 | 4780 | 26.7 | 28.3 | 29.9 | 704 | 756 | 4.69 | 191 | 95598 | 0 |
| 50 | 4693 | 27.1 | 29.5 | 31.5 | 780 | 851 | 4.91 | 242 | 93860 | 0 |
| 100 | 4663 | 27.3 | 29.4 | 30.6 | 887 | 940 | 4.88 | 342 | 93258 | 0 |
| 250 | 4631 | 27.5 | 29.7 | 31.2 | 1212 | 1306 | 4.88 | 641 | 92628 | 0 |
| 500 | 1366 | 93.0 | 99.6 | 103.5 | 1484 | 1488 | 2.27 | 655 | 27312 | 0 |
| 1000 | 1287 | 98.3 | 108.1 | 114.7 | 1540 | 1549 | 2.23 | 790 | 25731 | 0 |

### max_open_dbs = 4096 (all sites stay open)

| N sites | RPS | p50 ms | p95 ms | p99 ms | RSS steady MB | RSS peak MB | CPU cores | fd max | 2xx | err |
|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| 10 | 4498 | 28.4 | 30.3 | 31.5 | 669 | 719 | 5.12 | 161 | 89957 | 0 |
| 25 | 3936 | 31.1 | 40.1 | 59.5 | 1020 | 1041 | 4.78 | 191 | 78722 | 0 |
| 50 | 4120 | 31.0 | 34.1 | 35.6 | 782 | 858 | 4.89 | 241 | 82396 | 0 |
| 100 | 4220 | 30.2 | 32.8 | 34.4 | 862 | 908 | 4.85 | 341 | 84405 | 0 |
| 250 | 4456 | 28.7 | 30.3 | 31.3 | 1216 | 1332 | 4.80 | 641 | 89123 | 0 |
| 500 | 4454 | 28.7 | 30.5 | 31.7 | 1719 | 1958 | 4.79 | 1142 | 89086 | 0 |
| 1000 | 4485 | 28.5 | 30.2 | 31.1 | 2844 | 3074 | 4.79 | 2141 | 89706 | 0 |

*(The cap=4096 N=25 row — 3936 RPS / 1020 MB — is a measured outlier from
concurrent sibling-agent build load on the box, not smoothed away. See Honesty.)*

## Scaling curves

```
RSS steady (MB) vs N            cap=256 (bounded by LRU)      cap=4096 (linear)
N=10    676   |###                              669   |###
N=25    704   |###                             1020   |####          (jitter)
N=50    780   |####                             782   |####
N=100   887   |####                             862   |####
N=250  1212   |######                          1216   |######
N=500  1484   |#######  <- LRU cap holds        1719   |#########
N=1000 1540   |#######  <- ~flat past cap       2844   |################  <- linear

RPS vs N                        cap=256                       cap=4096
N=10   4803  |################                 4498  |###############
N=250  4631  |###############                  4456  |###############
N=500  1366  |####     <- churn collapse       4454  |###############   <- holds
N=1000 1287  |####     <- churn collapse       4485  |###############   <- holds

CPU cores vs N (of 32)          cap=256                       cap=4096
N=250   4.9  |#################                4.8  |################
N=500   2.3  |########  <- blocked, not busy   4.8  |################
N=1000  2.2  |########  <- blocked, not busy   4.8  |################
```

The inflection is entirely about **N vs the cap**. Below the cap the two
configs are the same instance. Above it, cap=256 turns every request into an
open/evict operation; cap=4096 keeps every site resident.

## The per-site resource model

Fitting the **cap=4096** points (where *open sites = N*, no eviction):

* **RSS** ≈ **0.67 GB baseline** + **~2.2 MB per open site**
  — baseline is the PHP ZTS runtime (128-way `spawn_blocking` contexts) +
  opcache + server; the per-site term is the open Turso `Database` factory + WAL
  + the per-site KV store. Fit: (2844−1216 MB)/(1000−250) = **2.17 MB/site**.
* **File descriptors** ≈ **~140 base** + **~2.0 per open site**
  (Turso `db` + `-wal`). Fit: (2141−161)/(1000−10) = **2.0 fd/site**.
* Under the LRU, substitute **open sites = min(N, max_open_dbs)** into both — so
  memory and fds are **bounded by the cap, not by N**. Measured: cap=256 pins
  RSS at ~1.5 GB and fds at ~655–790 whether N is 500 or 1000.
* ~~**Throughput ceiling** ≈ **4.6–4.8k front-page req/s** ≈ **~90k bridge
  queries/s**, at only **~5 of 32 cores**~~ **[ERRATUM: harness artifact. On
  the fixed harness the warm N=250 point measures ~14.9k req/s at ~16.5 cores
  (pre-#303) and ~18.9k req/s at ~22.8 cores (main) — ~285–360k bridge
  queries/s.]**
* **CPU per request** ≈ 16.5 cores / 14.9k RPS ≈ **~1.1 core-ms/request**
  (~22 µs CPU per bridge query) on the warm path — the *per-request CPU cost*
  from the original fit survives almost unchanged (4.8/4500 ≈ 1.07 core-ms);
  the DrvFs handicap wasted wall-clock, not CPU.

**Headline sizing (front-page workload, this box):**
> **N sites ≈ 0.67 GB + 2.2 MB × min(N, max_open_dbs) of RSS** — *provided the
> cap is ≥ N*. **[ERRATUM: the throughput half of this headline was
> harness-capped. Corrected: ~15–19k aggregate RPS at 16–23 cores with cap ≥ N;
> below the cap you trade throughput (down to ~1.4k RPS pre-#303, ~3.3k on
> main) for a memory/fd ceiling.]**

## Where — and why — it topped out

1. **It is not fd-bound.** `ulimit -n` was **1,048,576**; the worst case
   (N=1000, cap=4096) used **2,141** fds. The 1000-sites × WAL-fd concern does
   not bite on a normally-configured host. It *would* matter under a low
   `RLIMIT_NOFILE` (e.g. a 1024-fd container): cap × ~2 + ~140 must fit, so
   size `max_open_dbs` under the limit — the default 256 needs ~650 fds.

2. **It is not memory-bound here.** Peak 3.0 GB on a 62 GB box. On a memory-
   constrained host the default LRU is what keeps you alive: it holds RSS at
   ~1.5 GB regardless of N.

3. ~~**The real ceiling is the per-site registry mutex.**~~ **[ERRATUM: this
   paragraph was the report's central mistake. The ~4.7k plateau at ~5 cores
   was the DrvFs-cwd syscall penalty in the harness, not `SiteBackends`'
   registry mutex — the same binary measured ~15.9k RPS the moment the server
   got a native cwd. What the mutex *did* cause, verified on the fixed
   harness: (a) the **past-cap churn collapse** (item 4 below — real, and
   worth ~4.5× once the harness stopped hiding it), and (b) a **bistable
   warm-point collapse** seen during #303 validation, where some baseline runs
   fell into a ~1.6k-RPS convoy and stayed there. ePHPm #303 shards the
   registry and removes both. On current `main` the warm ceiling is ~18.9k RPS
   at ~22.8 of 32 cores — at that point CPU genuinely starts to matter.]**

4. **Past the cap, churn compounds it.** With N > `max_open_dbs`, a round-robin
   over all sites makes almost every request a *miss*: it must open a file
   (held **across** the mutex, by design, for the single-open-handle invariant)
   and evict an idle victim. Requests queue behind that serialized open path, so
   RPS falls to ~1.4k and CPU *drops* (threads block, they don't spin).
   Correctness held throughout — 0 errors, 100% 2xx. **[Re-verified on the
   fixed harness (N=500, cap=256): pre-#303 ~1.44k RPS / ~2.1 cores /
   p50 ~89 ms; #303's sharded registry + eviction outside the shard lock lifts
   this to ~3.3k RPS / ~10.5 cores / p50 ~42 ms.]**

## Capacity-planning takeaway

For a **multi-tenant / PR-preview host** on hardware like this (front-page-heavy
WordPress traffic):

* **Size `max_open_dbs` ≥ your count of *simultaneously-active* sites.** The LRU
  is a memory/fd safety valve, not a performance feature — crossing it on a
  spread-out workload costs **~4.5× throughput pre-#303 (~10× measured
  15k → 1.4k), ~5.7× on main (18.9k → 3.3k)** and ~2–10× latency. If 1000 sites
  can all be hot at once and you have the RAM, set the cap ≥ 1000 and budget
  **~0.67 GB + 2.2 MB/site (~2.9 GB at 1000)** plus **~2 fd/site**.
* **If memory is the hard limit, keep the default cap and accept the throughput
  ceiling** — you get a predictable ~1.5 GB ceiling at any N, at ~1.4k RPS
  (pre-#303) / ~3.3k RPS (main). Good for many *idle* tenants (PR previews
  mostly parked), bad for 1000 *busy* ones.
* **Right-size `RLIMIT_NOFILE`** to `~2 × max_open_dbs + 200` with headroom.
* ~~**Don't expect one instance to use all cores** on the bridge path today; the
  registry mutex caps a single instance near ~4.7k front-page RPS regardless of
  core count.~~ **[ERRATUM: withdrawn — the ~4.7k cap was the harness. On the
  fixed harness one instance reaches ~18.9k front-page RPS at ~22.8 of 32
  cores (main); the bridge path does scale with cores now. Sharding tenants
  across instances is still how you scale *past* one box, but there is no
  ~5-core single-instance wall.]**

## Results — wp-real (real WordPress anchor)

**[ERRATUM note: wp-real is CPU-bound, so the DrvFs harness bug barely moved
it — the fixed harness measures ~266–272 RPS at ~28 cores (vs 243–253 below),
i.e. ~9.5–9.7 req/s/core. The 9–10 req/s/core sizing figure is CONFIRMED. The
"~1.8 GB RSS" anchor below did not reproduce: corrected steady RSS at N=50,
C=128 is ~2.9–3.4 GB with the default spawn_blocking engine; the pool engine
runs the same load in well under 1 GB. See BEFORE-AFTER.md.]**

Real WP core + the `ephpm/db-wordpress` drop-in, one web install copied to all N
sites behind a dynamic-host `wp-config.php`. `cap=4096`, concurrency 128, same
box. This is the workload that anchors **absolute** WordPress cost.

| N sites | RPS | p50 ms | p95 ms | p99 ms | RSS steady MB | CPU cores mean | fd max | 2xx | err |
|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| 10 | 253 | 516 | 751 | 3363† | 2340† | 27.2 | 184 | 3802 | 0 |
| 50 | 243 | 546 | 738 | 818 | 1738 | 26.8 | 254 | 3642 | 0 |
| 100 | 243 | 501 | 792 | 3200† | 2656† | 27.4 | 374 | 3650 | 0 |
| 250 | 249 | 505 | 809 | 3752† | 2979† | 27.5 | 671 | 3740 | 0 |

†Tail-latency / RSS spikes at N=10/100/250 are contaminated by two sibling
php_linked builds hammering the box during those points; **N=50 ran cleanest**
and is the trustworthy anchor. Every point: **0 errors, 100% HTTP 200.** RPS is
flat 243–253 across all four N — adding tenants does not change the per-request
cost, it time-slices the same saturated cores across more sites.

**This inverts the bottleneck.** Real WordPress does ~18× more PHP work per
request than wp-lite, so it is **CPU-bound, not mutex-bound**: ~250 RPS pins
**~27 of 32 cores** (vs wp-lite's ~4.7k RPS at only ~5 cores). The registry
mutex that caps wp-lite never even becomes the limit for real WP — PHP execution
saturates the cores first. So the two workloads bracket reality:

* **wp-lite** = the *DB/LRU path* cost in isolation → ~4.7k RPS, ~5 cores, mutex-bound.
* **wp-real** = *actual WordPress* → **~250–270 RPS, ~27–28 cores → ≈ 9–10
  front-page req/s per core** (~105 ms CPU/request; re-confirmed on the fixed
  harness), ~~**~1.8 GB RSS**~~ **[ERRATUM: ~2.9–3.4 GB steady at N=50, C=128
  with spawn_blocking]** at N≤50.

For capacity planning **use the wp-real number**: real tenants run real
WordPress, and on that workload **CPU is the wall** — throughput scales with
cores (~9–10 req/s/core), and one 32-core box tops out near ~250–300 front-page
RPS regardless of how many sites are open. The per-site memory/fd model from
wp-lite (0.67 GB + 2.2 MB/site, 2 fd/site, LRU-bounded) still governs footprint;
wp-real just replaces the throughput ceiling with a per-core one.

*(wp-real was anchored at N ≤ 250; the 1000-site curve was run on wp-lite
because real WP × 1000 sites × concurrent builds would not fit the box, and at
~27 cores real WP is CPU-saturated by N=10 already — higher N only spreads the
same throughput thinner. The per-site DB/LRU **shape** is identical between the
two — only the throughput ceiling differs, and it moves the right way for
planning: lower and CPU-governed.)*

## Honesty

* **The original harness had a bug that invalidated the absolute wp-lite
  throughput/CPU numbers** (server launched with a DrvFs cwd — see the erratum
  at the top). Found during ePHPm PR #303 validation, fixed in harness commit
  `e92483e`, re-based in `BEFORE-AFTER.md`. The annotations in this file are
  the honest reconciliation; the original values are preserved for the record.
* **Dev-box / WSL2 numbers.** Absolute RPS and RSS will differ on bare metal or
  under cgroup limits. The **shape** (flat-under-cap, churn-collapse, linear-RSS)
  is the result, not the absolute RPS.
* **No LTO tuning** — stock `cargo xtask release`.
* **wp-lite is WP-*shaped*, not WordPress** — clearly labeled. The wp-real path
  (real WP core + drop-in) **was** run, at N=10/50/100/250, and is reported
  above; it anchors the absolute per-core WordPress cost (~9–10 req/s/core,
  CPU-bound). Only the 1000-site *curve* is wp-lite.
* **Concurrent interference:** two sibling agents were building php_linked in
  WSL during the sweep; the cap=4096 N=25 point (and the mild RPS dip across
  small-N cap=4096) reflect that contention. Left in, not smoothed.
* **Measured vs extrapolated:** every row above was **run**. The per-site model
  is a fit over measured points; nothing is projected past N=1000.
