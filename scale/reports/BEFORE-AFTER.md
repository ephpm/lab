# Before/After: ePHPm #297 + #302 + #303 on the corrected harness

**What this is:** the definitive A/B of the 2026-08-15 ePHPm work — litewire
bump (#297), PHP crash containment (#302), per-site registry sharding (#303) —
measured on the **fixed** benchmark harness, and the re-baseline for every
throughput number this repo publishes. Companion to the erratum in
[`REPORT.md`](REPORT.md).

## The harness fix (why every older number needed re-basing)

PR ephpm/ephpm#303's validation discovered that `scripts/run_sweep.sh` (and
`run_overload.sh`) launched ephpm with the working directory inherited from the
shell — the repo checkout on `/mnt/c`, a WSL DrvFs mount. A DrvFs cwd adds a
9p syscall penalty to the hot request path. Same binary, same config, same
provisioned state, only the server's cwd differing:

| server cwd | wp-lite warm RPS |
|---|--:|
| `/mnt/c/...` (DrvFs) | 4,164 |
| `/root/...` (native ext4) | 15,900 |

**~3.8× — the entire "~4.7k RPS plateau at ~5 of 32 cores" story in the
original report was this bug**, not the per-site registry mutex. Fixed in
commit `e92483e`: `start_server` now `cd`s to the WSL-native run dir before
exec'ing the binary, and both drivers fail fast if the run dir itself is on
`/mnt/*`. `sample.sh` was audited and needs no change (it only reads `/proc`
of an existing pid; it never launches the server). **Every number in this file
was produced on the fixed harness, for both arms.**

## Binaries

| | BEFORE | AFTER |
|---|---|---|
| Rev | `b9f56dbac3f59554a6609258e21be1aad275bae0` (main pre-#297, post-#296: pool engine in, none of today's work) | `a634dffe747620c232c997e2726cb64db80b02d5` (`origin/main`: #297 litewire, #302 crash containment, #303 registry sharding) |
| Build | `cargo xtask release 8.5` on WSL2 ext4, PHP SDK 8.5.7 (`-gnu`), ZTS, stock release profile | same |
| Built (fresh, this session) | 2026-08-15 18:40:10 -0700 | 2026-08-15 18:46:33 -0700 |
| sha256 | `25de42fe7b8e65ebdd1160e830a5f95663c027805d625e9bfac26edf6b62d267` | `8e2d7429eff17573a8671c23e75e362a451a962613a1c0372367cf7ef77495a5` |
| Size | 126,895,776 B | 126,936,744 B |
| String check | has `"fpm execution pool started"` (#296); **zero** `crash_containment` hits (pre-#302) | has both, incl. the `"crash_containment is ON"` startup line |

Build integrity note: the two revs were built **sequentially** in the shared
`/root/ephpm-target`. The first AFTER attempt failed to compile — cargo's
mtime-based fingerprints considered the freshly-cloned AFTER tree "unchanged"
after the BEFORE build and reused b9f56db's `ephpm-config` rlib (exactly the
two-revs-one-target-dir thrash this run planned for). That mis-link was caught
as a hard compile error (`no field crash_containment on PhpConfig`), fixed by
force-touching the AFTER workspace sources, and the final binaries were
string-verified as above. No `cargo clean` was used.

## Method

- Harness: this repo at `e92483e`+ (fixed cwd), `scripts/run_sweep.sh`.
- **Interleaved A/B**: per point, 3 alternating before/after pairs
  (B,A,B,A,B,A), each run a **fresh ephpm instance** with freshly re-copied
  per-site template DBs. Tables report **median of 3 (min–max)**.
- Load: closed-loop Go loadgen, **C=128**, round-robin Host over all N vhosts,
  3:1:1 front/permalink/REST, 8 s warmup + 25 s measured.
- Config: `cap = max_open_dbs = 4096` except point 2 (cap=256);
  `php.mode=fpm`; `query_stats=false`; ports 8121/13321 (own lane, no sibling
  collision).
- Box: WSL2, 32 logical cores, 62 GiB, `ulimit -n` 1,048,576. Every instance
  autotuned identically:
  `autotune (serve): cpu_quota=unlimited mem=64261MiB (system-total) ->
  workers=32[host_parallelism] opcache.memory_consumption=512MB
  memory_limit=1990M interned=32MB jit_buffer=64MB (buffer-only, jit off)
  max_files=20000 realpath=16M/ttl=600 validate_timestamps=0 assertions=-1`
- **Shape, not SLA**: single dev box. Two idle ephpm servers from a sibling
  agent's E2E work existed on the box (different ports, no traffic); load
  average before the sweep was ~1 of 32. Nothing below is extrapolated; every
  cell was run.

Raw per-run JSON (loadgen + `/proc` sampler + startup lines + containment
check) is committed under [`results/before-after/`](../results/before-after/).

---

## Point 1 — wp-lite N=250, cap=4096, C=128 (warm multi-tenant path)

| Metric | BEFORE (b9f56db) | AFTER (main) | Δ |
|---|--:|--:|--:|
| RPS | 14,907 (14,640–15,167) | 18,908 (18,885–18,919) | **+26.8%** |
| p50 ms | 8.5 (8.4–8.7) | 6.0 | −29% |
| p95 ms | 9.6 (9.4–9.8) | 13.6 (13.5–13.6) | +42% |
| p99 ms | 10.4 (10.1–10.8) | 18.2 (18.1–18.3) | +75% |
| RSS steady MB | 1,277 (1,267–1,303) | 1,927 (1,908–1,931) | +51% |
| RSS peak MB | 1,286 (1,286–1,314) | 1,944 (1,927–1,952) | +51% |
| CPU cores (of 32) | 16.5 (16.5–16.9) | 22.8 (22.7–22.8) | +38% |
| fd max | 642 (641–644) | 641 (641–642) | ~0 |
| 2xx / errors | 372,669 / 0 | 472,713 / 0 | |

**Verdict vs expectation (+34% from #303's own validation): direction
reproduced, magnitude slightly lower — +26.8%.** Spread across the 3
interleaved pairs was tight (before ±1.8%, after ±0.1%). None of the 3
baseline runs fell into the ~1.6k-RPS bistable convoy #303's validation saw in
3-of-8 baseline runs — 3 runs is too few to confirm that fix statistically,
but no collapse was observed anywhere in this session. Two honest costs on the
AFTER side: the **tail moved out** (p99 10.4 → 18.2 ms — sharded resolve gets
more requests in flight, queueing at the now-busier cores) and **RSS is +650 MB
at this point** (more concurrent PHP work in flight at +4k RPS). fd model
unchanged (~140 + 2/site = 641 exactly).

## Point 2 — wp-lite N=500, cap=256, C=128 (past-cap churn path)

| Metric | BEFORE (b9f56db) | AFTER (main) | Δ |
|---|--:|--:|--:|
| RPS | 1,437 (1,437–1,452) | 3,332 (3,331–3,358) | **+132%** |
| p50 ms | 88.7 (87.8–88.9) | 41.6 (41.5–41.8) | −53% |
| p95 ms | 91.8 (91.7–91.9) | 59.7 (59.2–59.7) | −35% |
| p99 ms | 94.4 (94.2–95.0) | 66.2 (65.8–66.5) | −30% |
| RSS steady MB | 1,520 (1,483–1,543) | 1,272 (1,266–1,298) | −16% |
| RSS peak MB | 1,532 (1,489–1,546) | 1,311 (1,292–1,328) | −14% |
| CPU cores (of 32) | 2.1 (2.0–2.1) | 10.5 (10.4–10.5) | +5× |
| fd max | 655 | 729 (727–729) | +11% |
| 2xx / errors | 35,930 / 0 | 83,310 / 0 | |

**Verdict vs expectation (~+145%): reproduced at +132%** (PR #303 itself
measured +130% under the old harness). This also confirms the original
report's churn collapse was **real, not a harness artifact**: the pre-#303
binary still craters to ~1.4k RPS at ~2.1 cores on the fixed harness. #303
turns the single-mutex convoy into per-shard contention: 2.3× the throughput,
half the latency, *lower* RSS, and 5× the CPU actually doing work. Still far
below the warm point — the LRU miss/evict path remains expensive; the sizing
advice "cap ≥ active sites" stands.

## Point 3 — wp-real N=50, cap=4096, C=128 (real WordPress, the sizing anchor)

| Metric | BEFORE (b9f56db) | AFTER (main) | Δ |
|---|--:|--:|--:|
| RPS | 272 (269–272) | 266 (265–267) | −2.2% |
| p50 ms | 456 (455–463) | 472 (457–480) | +3% |
| p95 ms | 736 (716–755) | 745 (731–756) | +1% |
| p99 ms | 1,172 (1,043–1,292) | 1,312 (1,019–1,688) | noisy |
| RSS steady MB | 3,144 (3,081–3,365) | 3,238 (2,890–3,363) | ~0 |
| CPU cores (of 32) | 28.0 (27.8–28.3) | 27.9 (27.7–27.9) | ~0 |
| fd max | 272 (271–278) | 269 (266–271) | ~0 |
| 2xx / errors | 6,797 / 0 | 6,655 / 0 | |
| **req/s per core** | **9.7** | **9.5** | |

**Verdict: parity (−2%, within run noise), and the published per-core sizing
figure is CONFIRMED.** Corrected constant: **~9.5–9.7 real-WP front-page req/s
per core (~105 ms CPU/request)** vs the published ~9–10 derived on the
handicapped harness — wp-real is CPU-bound, so the DrvFs penalty was lost in
WordPress's own per-request cost (the tainted absolute RPS was only ~7% low:
243–253 then, 266–272 now). **The LKE sizing sheet's divisor does not move**
(see `LKE-SIZING.md`). One correction that *did* fall out: steady RSS at this
point is ~2.9–3.4 GB with the default spawn_blocking engine, not the ~1.8 GB
the original wp-real anchor row showed — that was a low outlier run.

## Point 4 — wp-real N=50, `EPHPM_PHP__FPM_ENGINE=pool`, AFTER binary only

| Metric | AFTER spawn_blocking (pt 3) | AFTER pool | Δ (pool) |
|---|--:|--:|--:|
| RPS | 266 (265–267) | 285 (284–285) | **+7%** |
| p50 ms | 472 | 404 (404–412) | −14% |
| p95 ms | 745 | 777 (766–781) | +4% |
| p99 ms | 1,312 | 1,027 (998–1,028) | −22% |
| RSS steady MB | 3,238 | **574 (564–587)** | **−82%** |
| CPU cores (of 32) | 27.9 | 29.8 | +7% |
| fd max | 269 | 245 | |
| 2xx / errors | 6,655 / 0 | 7,116 / 0 | |
| pool startup | — | `fpm execution pool started … thread_count=32 backlog=32` | |

**Verdict: the pool engine's parity holds post-#303 — better than parity.**
+7% RPS, tighter tail (p99 −22%), and the same −82% RSS win ENGINE-COMPARISON
found pre-#303 (574 MB vs 3.2 GB). The engine comparison's wp-real verdict
transfers unchanged to the sharded-registry binary.

## Point 5 — wp-lite N=50, cap=4096, pool engine: `crash_containment` on vs off (AFTER only)

Both arms run the pool engine (containment requires it —
`is_crash_containment_active()`); the ONLY difference is
`EPHPM_PHP__CRASH_CONTAINMENT=true`. Armed state was verified per run: every
"on" instance logged `[php] crash_containment is ON (experimental)`, every
"off" instance logged nothing (`containment.txt` in each run dir).

| Metric | guard ON | guard OFF | Δ |
|---|--:|--:|--:|
| RPS | 25,897 (25,767–26,300) | 25,801 (25,659–26,113) | **+0.4%** |
| p50 ms | 4.5 (4.4–4.5) | 4.5 | 0 |
| p95 ms | 9.1 (8.9–9.1) | 9.1 (9.0–9.2) | 0 |
| p99 ms | 11.8 (11.5–11.9) | 11.9 (11.6–11.9) | 0 |
| RSS steady MB | 351 (347–361) | 346 (346–349) | +1.4% |
| CPU cores (of 32) | 23.5 (23.4–23.6) | 23.3 (23.3–23.5) | +0.9% |
| fd max | 241 | 241 | 0 |
| 2xx / errors | 647,452 / 0 | 645,028 / 0 | |

**Verdict: the crash guard costs ~nothing on the happy path — pinned.** +0.4%
RPS delta is inside the run-to-run spread; latency percentiles are identical
to the decimal; RSS within 5 MB. Enabling `[php] crash_containment = true`
(with the pool engine) is performance-free until a crash actually happens.
(Side observation: wp-lite N=50 on the pool engine reaches ~25.9k RPS — the
highest throughput measured in this repo to date.)

---

## Summary of verdicts

| Expectation | Result |
|---|---|
| Harness DrvFs-cwd bug handicaps server ~4× | **Confirmed** (4.2k vs 15.9k same-binary; fixed in `e92483e`) |
| #303 warm-path +34% at N=250 | **Direction reproduced, +26.8%** (14.9k → 18.9k; tails/RSS cost noted) |
| #303 past-cap churn +145%-ish | **Reproduced, +132%** (1.44k → 3.33k; churn collapse itself confirmed real) |
| wp-real per-core figure ~9–10 req/s/core | **Confirmed: 9.5–9.7 req/s/core** (~105 ms CPU/req); sizing sheet unchanged |
| Pool engine parity on wp-real post-#303 | **Confirmed** (+7% RPS, −82% RSS, tighter p99) |
| Crash containment ~free on happy path | **Confirmed** (+0.4% RPS, +5 MB RSS, identical percentiles) |

Corrections applied elsewhere: `REPORT.md` (erratum + inline annotations),
`LKE-SIZING.md` (constant re-verified, mutex caveat withdrawn),
`ENGINE-COMPARISON.md` / `SHEDDING.md` (erratum banners).
