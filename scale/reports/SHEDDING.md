# What Does an Overloaded ePHPm Actually Return? (Open-Loop Shedding Test)

> **Erratum note (2026-08-15):** these runs predate the harness cwd fix
> (commit `e92483e`; see the erratum in `REPORT.md`). The workload here is
> CPU-bound wp-real, which the DrvFs handicap barely moved, and the findings
> below are behavioral (shed/no-shed, wedge, crash), not absolute-throughput
> claims — they stand. Absolute delivered-RPS values may read slightly low.

Answers the question left open by [ENGINE-COMPARISON.md](ENGINE-COMPARISON.md):
the closed-loop overload test (128/512 workers waiting for responses) showed
backpressure only as latency — **0 errors, nothing ever shed**. Real overload is
open-loop: requests arrive at a fixed rate whether or not earlier ones finished.
This run floods fresh instances with the loadgen's new open-loop mode and
records what actually comes back.

**TL;DR — the honest answer is ugly:**

1. **Nothing sheds without `max_connections`** — no 503, no 429, no 5xx of any
   kind. Excess requests vanish into client timeouts. (Prediction from code
   reading: confirmed.)
2. **`max_connections` sheds almost nothing and protects nothing.** The raw-503
   path fires (0.5–10 % of arrivals), but by code the rejected connection is
   *still served* — the 503 is a courtesy note, not load shedding.
3. **spawn_blocking wedges and never recovers** within any window we observed;
   RSS sits at 5.3–6.2 GB after the flood ends and a light probe gets zero
   responses. The pool stays at ~0.6 GB and recovers within 30 s.
4. **The process can crash.** Three of ten flooded instances died of the same
   SIGABRT: the `ephpm_php::db_bridge::HeldSession` thread-local's destructor
   panics ("cannot access a Thread Local Storage value during or after
   destruction") when a PHP-tainted tokio thread exits — once mid-flood, once
   during post-flood cooldown, once at SIGTERM. Not an OOM (62 GiB box, peak
   RSS 6.2 GB). Evidence: [`results/wp-real-openloop/evidence/sb-lim0-r400-rerun-crash.txt`](../results/wp-real-openloop/evidence/sb-lim0-r400-rerun-crash.txt).

## Method

- **Load model:** loadgen open-loop mode (added in this commit): constant-rate
  arrivals, each request fired at its scheduled time on its own goroutine
  regardless of in-flight count, 10 s per-request client timeout. Latency
  percentiles are computed over **2xx successes only**; non-responses are
  classified (timeout / conn_refused / conn_reset / eof / conn_error). The
  generator held its schedule everywhere (max scheduling lag ≤ 90 ms) and
  in-flight ceilings matched rate x timeout (≈4000 / ≈8000), i.e. the arrival
  process really was open-loop.
- **Workload:** wp-real (real WordPress core + the ephpm-db drop-in), N=10
  sites, `max_open_dbs = 4096`, per-site Turso DBs seeded from one
  installer-created template. Closed-loop capacity for this workload on this
  box is **~262–276 RPS** (ENGINE-COMPARISON point 3), so the tested arrival
  rates are **400/s ≈ 1.5x capacity** and **800/s ≈ 3x capacity**. 5 s warmup +
  60 s measured flood per point.
- **Matrix:** fresh instance per point, `{spawn_blocking, pool}` x
  `{no limits, [server.limits] max_connections = 256}` x `{400/s, 800/s}`.
  **Same binary for all points** — `/root/ephpm-target/release/ephpm`
  (php_linked release, PHP 8.5, built 2026-08-15 12:08 from main with #296 =
  `b9f56db`; same binary as ENGINE-COMPARISON). The only differences per point
  are `EPHPM_PHP__FPM_ENGINE` and the rendered `[server.limits]` block. Pool
  activation was hard-verified per point from the startup log
  (`thread_count=32`); the harness fails the point if the env didn't take.
- **After each flood:** survival check, 30 s idle cooldown, RSS re-read, then a
  light closed-loop probe (c=4, 10 s) against the *same* instance to measure
  recovery. Unloaded reference for that probe: ~58 RPS, p50 ≈ 68 ms.
- Harness: `scripts/run_overload.sh`; raw JSON under
  `results/wp-real-openloop/` (flood + resource sampler with 1 Hz RSS series +
  recovery probe per point).

**Environment caveats (read before quoting numbers):** WSL2 dev box (32 cores,
62 GiB), single run per point — **shape, not SLA**. Sibling agents were active
on the box during parts of the session (a wp-lite closed-loop bench overlapped
the two rerun points; load averages after floods ranged 29–88). Matrix points
ran back-to-back, so later points inherit OS-level TCP state (tens of
thousands of TIME_WAIT sockets) from earlier ones — the reruns below suggest
this matters. One confound applies *equally* to every point: each wp-real
front-page request tries to INSERT a ~30 KB `_site_transient_wp_theme_files_patterns`
row that litewire's tenant-path SQL screen rejects ("statement type `malformed
SQL` is not permitted"), and ephpm logs the full failed query — one 65 s flood
produced **532 MB of server log** (16,000 lines x ~33 KB). The closed-loop
baseline had the same behavior, so capacity numbers are comparable, but it is
extra per-request I/O that a clean workload wouldn't pay.

## The matrix (every row run, nothing extrapolated)

Delivered = 2xx completions per second of the 60 s window. Latencies are of
successes only. `drift` = last-quarter mean RSS minus first-quarter mean RSS
during the flood (growth shape).

| engine | max_conn | rate/s | delivered 2xx/s | % of arrivals | status distribution (of 24k/48k arrivals) | p50/p95/p99 s (2xx) | RSS steady/peak MB | drift MB | CPU cores | survived flood | probe @ +30s (ref: 58 RPS / 68 ms) |
|---|--:|--:|--:|--:|---|---|---|--:|--:|---|---|
| spawn_blocking | — | 400 | 41.4 | 10.4 % | 200: 2486 · timeout: 21515 | 7.6 / 9.7 / 9.9 | 5832 / 6014 | +1455 | 26.0 | yes, wedged | **0 responses in 12 s** |
| spawn_blocking | — | 800 | **0** | 0 % | timeout: 48001 (100 %) | — | 6068 / 6185 | +1964 | 23.1 | yes, wedged | **0 responses** |
| spawn_blocking | 256 | 400 | **0** | 0 % | 503: 2370 (9.9 %) · conn_error: 54 · timeout: 21577 | — | 5673 / 5770 | +2525 | 14.1 | yes, wedged | **0 responses** |
| spawn_blocking | 256 | 800 | **0** | 0 % | 503: 1586 (3.3 %) · conn_error: 49 · timeout: 46366 | — | 5425 / 5581 | +1840 | 8.7 | yes, wedged | **0 responses** |
| pool | — | 400 | 26.1 | 6.5 % | 200: 1568 · timeout: 22433 | 3.7 / 9.3 / 9.9 | 567 / 602 | +4 | 14.1 | **died in cooldown** | probe hit dead port (302 k conn_refused) |
| pool | — | 800 | 28.9 | 3.6 % | 200: 1731 · timeout: 46270 | 0.35 / 9.9 / 10.0 | 675 / 748 | −34 | 23.7 | yes | 18.3 RPS, p50 214 ms (degraded) |
| pool | 256 | 400 | 59.5 | 14.9 % | 200: 3571 · 503: 1317 (5.5 %) · conn_error: 37 · timeout: 19076 | 8.2 / 10.0 / 10.0 | 562 / 602 | −5 | 18.6 | yes | 45.9 RPS, p50 87 ms |
| pool | 256 | 800 | **0** | 0 % | 503: 248 (0.5 %) · timeout: 47753 | — | 690 / 733 | −14 | **0.5** | yes | **56.1 RPS, p50 72 ms — fully recovered** |

Reruns of the two headline points ~45 min later (fresh TCP state, sibling
closed-loop bench running — see variance note):

| rerun | delivered 2xx/s | status | outcome |
|---|--:|---|---|
| pool / — / 400 | **222.6** (56 %) | 200: 13356 · timeout: 10645 | sustained ~220–250 2xx/s the whole window (p50 5.3 s); survived, clean SIGTERM shutdown |
| spawn_blocking / — / 400 | 49.6 | 200: 2977 · **conn_refused: 13681** · timeout: 7343 | 2xx climbing 65→177/s, then **process died mid-flood (SIGABRT)**; everything after is conn_refused |

Raw: `results/wp-real-openloop/engine-{spawn_blocking,pool}/lim-{0,256}-rate-{400,800}.json`
(+ `.startup.txt` sidecars), reruns under `results/wp-real-openloop/followup/`.

## Answers to the four questions

### 1. Does anything return 503 without `max_connections`? — **No. Confirmed.**

Both no-limit columns contain exactly two outcomes: `200` and client `timeout`.
Zero 503, zero 429, zero 5xx of any kind, zero resets. An overloaded ePHPm with
default settings is a black hole: requests are accepted (or sit in the SYN
backlog) and the client's own timeout is the only terminator. The server also
keeps executing abandoned requests after the client gives up — its own
`[server.timeouts] request = 60` is the only server-side bound.

### 2. Does the raw-503 path fire with `max_connections = 256`? — Yes, but it's nearly irrelevant.

It fires (`lib.rs::acquire_connection`): 5.5–9.9 % of arrivals got the raw 503
at 400/s, 0.5–3.3 % at 800/s. Two reasons it doesn't matter:

- **Most excess arrivals never reach the limiter.** Under flood the accept
  loop can't keep up, the listen backlog fills, and dials hang until the
  client's timeout — 80–96 % of arrivals ended as client timeouts, not 503s.
  Shedding is bounded by the accept rate, and an overloaded instance barely
  accepts.
- **The 503 doesn't actually reject anything.** Code reading
  (`crates/ephpm-server/src/lib.rs:1016-1037` + `dispatch_main_connection`):
  on rejection, `acquire_connection` best-effort-writes the raw 503 and
  returns `None` — and the accept loop then **dispatches the connection to
  hyper anyway** (a `None` guard is indistinguishable from "no limiter
  configured", and nothing downstream checks it). The client sees 503 and
  closes; the server still parses the request the client already sent and
  runs it through PHP. `max_connections` therefore bounds *counted* guards,
  not work. The data agrees: with the limit set, spawn_blocking's RSS
  (5.4–5.8 GB), wedge behavior, and fd counts (~4000/~8000 held sockets ≈
  rate x timeout, far above 256) are identical to the no-limit rows.

So today's `[server.limits] max_connections` is a **client-visible courtesy
signal on a small fraction of arrivals, with zero backend protection**.

### 3. Pool vs spawn_blocking under flood

- **RSS shape:** pool is **bounded and flat** — 560–750 MB steady, drift −34
  to +4 MB over the window, back to ~550–630 MB after cooldown. spawn_blocking
  **climbs** — +1.4 to +2.5 GB drift *within* the 75 s window to 5.4–6.2 GB
  peak, and it does **not** come back down (5.3–5.9 GB still resident 30 s
  after the flood ended). Not a true OOM on a 62 GiB box, but the shape is
  "grows with backlog, never returns", i.e. it *would* OOM a small node.
- **Delivered goodput:** both engines collapse well below the ~260 RPS
  capacity — under open-loop flood there is no config that "serves capacity
  and sheds the rest". The pool keeps a trickle (26–60 2xx/s in the matrix;
  the rerun sustained **223 2xx/s**, suggesting the matrix figure was
  depressed by inter-point TCP state) and its successes include a fast lane
  (p50 0.35 s at 800/s — requests that caught a free pool slot). spawn_blocking
  delivers a burst in the first ~10–15 s and then **goes to zero and stays
  there** (per-second series in the JSONs: 46→235 2xx/s for a few seconds,
  then flat 0 for the rest of the window). 800/s: literally 48,001 arrivals,
  48,001 timeouts, 0 delivered.
- **Recovery after the flood (30 s cooldown):** the pool recovers — fully with
  the limit set (56 RPS / p50 72 ms / p99 107 ms, indistinguishable from the
  unloaded reference), partially at 800/s without it (18 RPS / p50 214 ms,
  still draining). **spawn_blocking never recovered**: at +30 s a 12 s probe
  got zero responses in all four configs, with RSS unchanged. We never
  observed a wedged spawn_blocking instance come back; the rerun attempt to
  probe at +300 s ended earlier — the process crashed mid-flood instead.
- **Why the asymmetry (mechanism, from code):** `spawn_blocking` closures are
  committed to tokio's **unbounded, uncancellable** blocking queue — dropping
  the connection does not dequeue the work, so tens of thousands of abandoned
  requests (each still worth ~100–500 ms of PHP) sit in FIFO ahead of any new
  request; at ~260 RPS capacity a 40 k backlog is minutes-to-hours of stale
  work, which *is* the wedge. The pool engine's hyper task awaits a send
  permit into a **bounded** backlog (`async_channel::bounded(32)`); when the
  client disconnects, hyper drops the task and the queued-but-unstarted
  request **is cancelled** — so the pool's queue stays honest and the instance
  drains in seconds.
- **Survival:** see the crash section — neither engine is safe from it, and it
  is the single worst behavior found.
- **Anomaly (flagged, unexplained):** pool/256/800 spent the whole flood near
  idle (0.5 CPU cores, ~8000 held sockets, 248 503s, zero 200s) and then
  probed perfectly healthy 30 s later. Single run; not reproduced or explained.

### 4. The crash: `HeldSession` TLS destructor aborts the process

Three separate instances died with the identical signature (captured in full
on the rerun, exit status 134):

```
thread 'tokio-rt-worker' panicked at library/std/src/thread/local.rs:428:25:
cannot access a Thread Local Storage value during or after destruction: AccessError
fatal runtime error: thread local panicked on drop, aborting
signal: SIGABRT ... in __call_tls_dtors
  std::sys::thread_local::native::eager::destroy::
      <RefCell<Option<ephpm_php::db_bridge::HeldSession>>>
```

When a tokio thread that has executed PHP work exits — the blocking pool reaps
threads idle >~10 s, which is exactly what happens right after a burst — its
TLS destructors run, and `HeldSession`'s drop (the per-thread per-site DB
session from `crates/ephpm-php/src/db_bridge.rs`) touches another TLS value
that is already gone. A panic inside a TLS destructor is a **process abort**.
Observed: once mid-flood (spawn_blocking rerun), once during the idle cooldown
after a survived flood (pool, matrix), once at SIGTERM shutdown
(spawn_blocking, matrix). It is stochastic (depends on which thread dies with
what teardown order), engine-independent, and it means **a traffic burst can
kill the whole multi-tenant process minutes after the burst ends**. This is an
ephpm bug to file: `HeldSession::drop` must be TLS-teardown-safe
(`try_with`, or no TLS access in drop).

## Verdict: what should a preview deployment set to fail gracefully?

Nothing in today's knobs produces graceful failure; the choices only pick
*which* failure you get. With that said:

1. **`[php] fpm_engine = "pool"` — yes** (experimental label notwithstanding).
   It is the difference between 0.6 GB flat / recovers-in-30 s and
   5.5–6.2 GB pinned / never-recovers-until-restart. On a preview node sized
   like the LKE-SIZING sheet (1–2 GB), spawn_blocking under a flood is an OOM
   kill; the pool is not.
2. **`[server.limits] max_connections` — set it (e.g. 256), but know what it
   buys**: a 503 for the minority of arrivals that get accepted while at cap,
   nothing more. It does not bound PHP work (rejected conns are served anyway
   — bug worth fixing: the guard-`None` ambiguity in `acquire_connection` /
   `dispatch_main_connection`), and most flood arrivals time out in the SYN
   backlog before ever seeing it.
3. **Lower `[server.timeouts] request` below your clients' patience** (e.g.
   10 s, not the 60 s used here) so abandoned work is at least bounded
   server-side. This doesn't dequeue spawn_blocking backlog, but with the pool
   engine it shortens the stale-work window.
4. **Put real shedding in front** (LB/proxy rate limit or concurrency cap
   ≲ 250 concurrent for this box class) — ePHPm currently has no mechanism
   that rejects work at request granularity.
5. **Fixes ePHPm needs before it can fail gracefully on its own** (findings,
   not knobs): the `HeldSession` TLS-dtor abort (crash under exactly this
   traffic shape); serve-after-503; and an immediate 503/429 when the pool
   backlog is full (the bounded queue already exists — rejecting instead of
   backpressuring at, say, backlog > N x pool would have turned most of the
   47 k timeouts at 800/s into instant, honest 503s).

**Weight-bearing caveat:** single-run WSL2 numbers, sibling load present for
parts of the session, and the two reruns differed from their matrix twins by
up to 8x on delivered goodput (26 vs 223 2xx/s) — treat every number here as
*shape*. The shapes, however, were consistent every time: no shedding without
limits, near-no shedding with them, pool bounded-and-recovering,
spawn_blocking bloated-and-wedged, and a process that sometimes just dies.
