# shed-verify — do the v0.7.0 overload fixes actually hold? (open-loop re-run)

**TL;DR: the fixes hold.** Across all 10 flood points (plus probes): **zero
SIGABRTs** (was 3 of 10 — the #300/#305 `HeldSession` fix holds), shed lanes
turned **every** excess arrival into a fast 503 (p50 **1.7 ms**, max 9.8 ms,
measured mid-flood) with **zero client timeouts**, while **retaining full
closed-loop capacity as goodput** (344 delivered 2xx/s vs 340 RPS measured
capacity, even at 2.4× flood). The one behavior that still reproduces from the
old findings: a **default-config** (`wait`, no workers cap) `spawn_blocking`
instance under a deep flood still bloats to ~6 GB and wedges — the remedy is
the opt-in shed/pool config, not a change to the default.

## Why this re-run exists

The imported source-tier report [`scale/reports/SHEDDING.md`](../scale/reports/SHEDDING.md)
(recorded 2026-08-15, binary @ `b9f56db`, pre-#298/#300/#301/#305) found, in its own words,
"the honest answer is ugly":

1. nothing sheds without `max_connections` — excess arrivals vanish into client timeouts;
2. `max_connections` sheds almost nothing and protects nothing;
3. `spawn_blocking` wedges permanently (RSS 5.3–6.2 GB, zero probe responses);
4. 3 of 10 flooded instances died of the `HeldSession` TLS-destructor SIGABRT.

Since then ePHPm shipped: the `[server] preview` preset (#298), request-granularity
load shedding — `[php] overload_policy = "shed"` / `shed_after_ms`, counted by
`ephpm_php_shed_total` (#301), and DB-session parking at thread teardown (#300/#305,
the SIGABRT fix). `config.md` now claims shed "turns overload into fast, countable
errors instead of client timeouts". **None of that had been re-verified under the
traffic shape that produced the original findings.** This document is that verification.

## Method

Same harness, same workload, same shape as SHEDDING.md — the imported
[`scale/`](../scale/) copy of the harness (this run is also the validation that the
fold-in works), with one addition: `run_overload.sh` grew a `POLICIES` axis
(`wait` | `shed` | `preview`), injected via env override and **hard-gated on the
startup log** ("load shedding ON" / "preview mode ON" must appear for the lane to
count, and must NOT appear for a `wait` lane).

- **Workload:** wp-real — real WordPress core (7.0.3) + the ephpm/db-wordpress
  drop-in, N=10 sites, per-site Turso DBs seeded from one installer-created
  template, `max_open_dbs = 4096`.
- **Load:** open-loop constant-rate arrivals (the scale loadgen), 10 s client
  timeout, 5 s warmup + 60 s flood, then 30 s idle cooldown and a closed-loop
  recovery probe (c=4, 10 s) against the same instance. Latency percentiles are
  over 2xx successes only.
- **Matrix:** fresh instance per point.
  - `pool` × {`wait`, `shed` (`shed_after_ms=0`), `preview`} × {400, 800}/s
  - `spawn_blocking` × {`wait`, `shed` (`shed_after_ms=200`, `[php] workers = 32`)} × {400, 800}/s
- **Host:** WSL2 on Windows 11, 32 vCPU, 62 GiB. Run dir `/root/ephpm-overload-run`
  on **native ext4** (asserted by the harness — see the DrvFs trap in the README);
  server cwd is the native run dir. No sibling load during the matrix.

### Provenance

| | |
| --- | --- |
| Binary | from-source `cargo xtask release 8.5`, ephpm main @ `180d0ac` (post-#306) |
| sha256 | `afa19edfc262854259da7ed33d4995954614047c550917fd7a9e489fdd0fd3c4` |
| PHP | 8.5 ZTS glibc (php-sdk) |
| Date | 2026-08-17 |
| Tier | **source tier** — never compare with the image-pinned tiers |

## Results

**Capacity calibration first:** closed-loop (c=128, 20 s) on this binary =
**339.7 RPS, 0 errors** (p50 336 ms / p99 859 ms). The original SHEDDING run
measured ~262–276 RPS for the same workload — this binary is ~1.25× faster on
wp-real, so 400/s here is ≈1.2× capacity and 800/s ≈2.4×. The recovery-probe
healthy reference on this binary is ~82 RPS at c=4.

Every row: 60 s flood, all arrivals accounted for (`200 + 503 + 429 + timeout
= arrivals`, no other statuses observed, `conn_*` = 0 everywhere).

| engine | policy | rate/s | arrivals | 200 | 503 | 429 | client-timeout | delivered 2xx/s | p50 / p99 ms (2xx) | RSS peak → post-cooldown MB | survived | probe @ +30 s |
|---|---|--:|--:|--:|--:|--:|--:|--:|---|---|---|---|
| pool | wait | 400 | 24,001 | 23,148 | 0 | 0 | 853 | 385.8 | 2,209 / 9,202 | 545 → 545 | yes | 59 RPS, p50 56 ms |
| pool | wait | 800 | 48,001 | 3,465 | 0 | 0 | 44,536 | 57.8 | 378 / 9,927 | 803 → 629 | yes | 82 RPS, p50 51 ms |
| pool | **shed** | 400 | 24,001 | 20,646 | 3,355 | 0 | **0** | **344.1** | **185 / 239** | 514 → 477 | yes | 82 RPS, p50 51 ms |
| pool | **shed** | 800 | 48,001 | 20,650 | 27,351 | 0 | **0** | **344.2** | **190 / 237** | 507 → 468 | yes | 84 RPS, p50 51 ms |
| pool | preview | 400 | 24,001 | 300 | 0 | 23,701 | **0** | 5.0 | 49 / 59 | 497 → 490 | yes | healthy, rate-limited (see below) |
| pool | preview | 800 | 48,001 | 425 | 0 | 47,576 | **0** | 7.1 | 49 / 59 | 480 → 491 | yes | healthy, rate-limited |
| spawn_blocking | wait | 400 | 24,001 | 11,794 | 0 | 0 | 12,207 | 196.6 | 6,064 / 9,932 | 6,001 → 2,421 | yes | **82 RPS — recovered** |
| spawn_blocking | wait | 800 | 48,001 | 857 | 0 | 0 | 47,144 | 14.3 | 9,193 / 9,986 | 6,179 → 5,754 | yes | **0 responses — wedged** |
| spawn_blocking | **shed** (200 ms, workers=32) | 400 | 24,001 | 20,128 | 3,873 | 0 | **0** | **335.5** | **296 / 336** | 552 → 271 | yes | 82 RPS, p50 51 ms |
| spawn_blocking | **shed** (200 ms, workers=32) | 800 | 48,001 | 19,195 | 28,806 | 0 | **0** | **319.9** | **304 / 356** | 579 → 300 | yes | 79 RPS, p50 53 ms |

**How fast is a shed 503?** Measured directly (60 timed side-probes against a
pool+shed instance mid-flood at 600/s): the 44 that were shed answered in
**p50 1.7 ms / p95 7.1 ms / max 9.8 ms**; the 16 that got a slot completed in
p50 194 ms. `config.md`'s "fast, countable errors instead of client timeouts"
is measured, not aspirational. (`ephpm_php_shed_total` counts them; the
per-point 503 tallies above are the client-side view of the same events.)

**The preview lanes measure the per-IP limiter, and that is the correct
reading, not a flaw:** the preset fills in per-IP rate/connection caps sized
for a small preview box, and this harness's load generator is a single IP — so
~99% of its arrivals get instant 429s (p50 ≈ 49 ms for the 200s that passed,
zero timeouts, RSS flat ≈ 490 MB, process healthy throughout). A preview box
under a single-source flood answers everything immediately and does almost no
PHP work, which is precisely the preset's contract. What this lane does *not*
measure is multi-client goodput under preview — that needs a multi-IP
generator (future work, proposal C5).

## Verdicts on the four original findings

1. **"Nothing sheds without `max_connections`" — still true for the default,
   and now fixable with one knob (verified).** The `wait` lanes reproduce the
   black hole: 0 shed responses, excess vanishes into client timeouts.
   `overload_policy = "shed"` (or `preview`) converts **100%** of excess into
   fast 503s/429s — zero timeouts in all six shed/preview points.
2. **"`max_connections` sheds almost nothing / rejected connections are served
   anyway" — not re-tested.** This matrix ran `limits = 0` throughout; the
   serve-after-503 behavior of `[server.limits] max_connections` was not
   re-examined. Request-granularity shed makes it moot as an overload defense,
   but the original finding stands unverified either way.
3. **"spawn_blocking wedges permanently" — partially remediated, and the
   remaining wedge is opt-out-able (verified).** At 400/s (≈1.2× capacity) a
   default spawn_blocking instance now *recovers* (82 RPS probe; the original
   never recovered at any tested point). At 800/s the wedge still reproduces
   exactly as documented — 6.2 GB RSS, 0 probe responses — because tokio's
   blocking queue is still unbounded and uncancellable *when nothing bounds
   admission*. With `workers = 32` + shed, the same engine is bounded (579 MB
   peak, 300 MB after cooldown) and recovers instantly. The engine default is
   unchanged; the fix is configuration, and the preview preset applies it.
4. **The `HeldSession` TLS-destructor SIGABRT — fixed (verified).** 0 process
   deaths across 10 floods + cooldowns + SIGTERM shutdowns on a binary
   carrying #300/#305 (the original run lost 3 of 10 instances to it,
   including one during idle cooldown). Every instance in this matrix
   survived its flood and shut down cleanly.

One more delta worth naming: the old run's best flood outcome was "a trickle
of goodput" (26–60 2xx/s in-matrix). On this binary the shed lanes deliver
**full capacity** under 2.4× flood — overload no longer costs the goodput of
the requests that could have been served.

Raw per-point JSON (flood + 1 Hz resource series + recovery probe, plus
`.startup.txt` gate sidecars) is written to
`scale/results/wp-real-openloop/engine-*/pol-*.json` — gitignored per the
lab's raw-output convention; the tables above are the record.

## Caveats

Single run per point on a WSL2 dev box — shape, not SLA. The original SHEDDING
run measured closed-loop capacity ~262–276 RPS for this workload; this binary is
measurably faster (see the capacity note in the results), so the same nominal
rates sit at different multiples of capacity than they did in the original.
