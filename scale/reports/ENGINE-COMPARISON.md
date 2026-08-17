# FPM Execution Engine Comparison — `spawn_blocking` vs `pool`

> **⚠ Erratum (2026-08-15):** these runs predate the harness fix in commit
> `e92483e` — the server was launched with a DrvFs (`/mnt/c`) working
> directory, which capped the light **wp-lite** points ~3.8× low (the ~4.7–4.9k
> RPS plateaus below are the harness, not the engines). The **relative**
> engine-vs-engine comparisons and the RSS/tail-shape findings stand; the
> CPU-bound **wp-real** point was essentially unaffected. Re-based wp-real
> pool-vs-spawn_blocking numbers on the fixed harness (post-#303 `main`) are in
> `BEFORE-AFTER.md` — the parity verdict holds there too.

Head-to-head of ePHPm's two FPM execution engines: the default `spawn_blocking`
engine vs the opt-in `pool` engine added in **PR #296** (`[php] fpm_engine`,
merged to `main` as `b9f56db`). The knob is env-overridable
(`EPHPM_PHP__FPM_ENGINE`), so a fresh instance is stood up per engine with the
**same binary** — only that one env var differs.

## What the two engines are

- **`spawn_blocking`** (default) — each PHP request runs on tokio's blocking
  thread pool via `spawn_blocking`. Concurrency is effectively **unbounded** (up
  to tokio's blocking-pool ceiling); under N concurrent requests the runtime
  spins up ~N blocking threads, each of which registers its own PHP (ZTS/TSRM)
  context. Behaviour is unchanged from every release before #296.
- **`pool`** — a **fixed pool of dedicated OS threads** (not `spawn_blocking`).
  The pool size *is* the concurrency cap for PHP, and it equals the autotuned
  worker count (`PhpConfig::effective_worker_count`). Requests beyond the pool
  size wait in a bounded backlog (`async_channel::bounded`). Marked
  **experimental** in the startup log.

On this host both resolve the pool/worker count to **32** (autotune =
`available_parallelism` clamped to `[2,32]`; `[php] workers` unset). Startup
line for the pool engine:

```
INFO ephpm_server::fpm_pool: fpm execution pool started
     (experimental [php] fpm_engine = "pool") thread_count=32 backlog=32
```

The `spawn_blocking` engine emits no such line (verified: present only with the
env var set, absent when unset).

## Binary provenance

| | |
|---|---|
| Path | `/root/ephpm-target/release/ephpm` (WSL-native ext4) |
| Build time | 2026-08-15 12:08 (fresh, this session) |
| Type | `php_linked` release — **Zend Engine v4.5.7 (PHP 8.5)**, 126,897,008 bytes |
| `#296` present? | Yes — binary contains the `fpm_engine` config field and the pool strings (`"fpm execution pool started …"`, `"[php] workers is ignored when [php] fpm_engine = \"pool\""`) |
| Pool activation | `EPHPM_PHP__FPM_ENGINE=pool` → pool starts (`thread_count=32`); unset → no pool line. |

**Same binary for both engines — only `EPHPM_PHP__FPM_ENGINE` differs.**

## Method

- Harness: `scripts/run_sweep.sh` with the new **`ENGINES`** axis. Each
  `(engine × workload × N)` point is a *fresh* ephpm instance; the sweep exports
  `EPHPM_PHP__FPM_ENGINE=<engine>` into the spawned process and namespaces
  results under `results/<workload>[…]/engine-<engine>/`. Pool size is captured
  from the startup log into each result's `meta.pool_size`.
- Every point: `cap = max_open_dbs = 4096` (so the per-site-DB LRU never evicts
  and can't confound the engine comparison), fresh instance, closed-loop Go
  loadgen driving a round-robin front + permalink + REST mix across all N
  vhosts, 8 s warmup + 25 s measurement, `/proc` sampler for RSS/CPU/fd.
- **Environment caveat:** WSL2 dev box (32 logical cores, 62 GiB). These are
  **shape, not SLA** numbers — single run per point, so treat sub-~3 % deltas as
  noise. Runs were sequential (no sibling load). Nothing is extrapolated; every
  row below was measured.

---

## Point 1 — wp-lite, N=250, concurrency 128 (light, high-throughput)

The high-RPS path where per-request dispatch overhead is most visible. Pool
size = 32, so 128 clients oversubscribe the pool 4×.

| Metric | spawn_blocking | pool | Δ (pool vs sb) |
|---|--:|--:|--:|
| Pool size | — (unbounded) | 32 | |
| RPS | 4873.0 | 4773.0 | **−2.1 %** |
| p50 ms | 26.23 | 22.03 | −16 % |
| p95 ms | 27.67 | 49.73 | **+80 %** |
| p99 ms | 28.43 | 69.53 | **+145 %** |
| max ms | 33.09 | 166.52 | +403 % |
| RSS steady MB | 1244 | 811 | **−35 %** |
| RSS peak MB | 1392 | 864 | −38 % |
| CPU cores mean | 4.86 | 4.24 | −13 % |
| fd max | 641 | 641 | 0 |
| 2xx | 121 827 | 119 327 | |
| errors / non-2xx | 0 | 0 | |

**Read:** throughput within ~2 % (within run-to-run noise). Pool's **median is
actually lower** (22 vs 26 ms) — so there is *no measurable per-request dispatch
tax on the fast path*. The cost shows up in the **tail**: with 128 clients on 32
pool threads, requests queue, so p99 jumps to 69 ms (vs a very tight 28 ms for
spawn_blocking). spawn_blocking buys its uniform latency with ~35 % more memory
(it holds ~1 PHP context per in-flight request instead of 32).

## Point 2 — wp-lite, N=50, concurrency 512 (overload: 16× cores)

The decisive point. spawn_blocking is unbounded; pool is capped at 32.

| Metric | spawn_blocking | pool | Δ (pool vs sb) |
|---|--:|--:|--:|
| Pool size | — (unbounded) | 32 | |
| RPS | 4717.9 | 4751.3 | +0.7 % |
| p50 ms | 108.48 | 67.13 | −38 % |
| p95 ms | 111.19 | 271.21 | +144 % |
| p99 ms | 112.68 | 420.57 | **+273 %** |
| p99.9 ms | 123.59 | 582.99 | +372 % |
| max ms | 125.28 | 885.04 | +606 % |
| RSS steady MB | 2157 | 379 | **−82 %** |
| RSS peak MB | 2254 | 416 | −82 % |
| CPU cores mean | 4.43 | 4.24 | −4 % |
| fd max | 634 | 647 | |
| 2xx | 117 947 | 118 782 | |
| errors / non-2xx | 0 | 0 | |

**Read — the behavioral difference, not just the number:** at 512 concurrent,
spawn_blocking spins ~512 blocking threads, each with its own PHP context →
**RSS balloons to 2.16 GB**, but latency is a tight uniform band (108–125 ms)
because every request runs immediately and the 32 cores time-slice them evenly.
The pool holds the line at **32 threads / 379 MB — 5.7× less memory** — and
absorbs the extra 480 clients as *queue latency*: fast requests still clear in
67 ms (better median), but queued ones stretch the tail to p99 = 420 ms, max =
885 ms.

**Neither engine sheds** (0 errors, 100 % 2xx). This is a **closed-loop**
generator (fixed 512 in-flight), so the pool's bounded backlog manifests as
backpressure-via-latency (the HTTP handler awaits a send permit into the bounded
channel), **not** 503/504. So the "bounded vs unbounded" story here is
*memory-bounded with a long tail* (pool) vs *latency-uniform but memory-heavy*
(spawn_blocking) — not graceful shedding vs collapse. Under an *open-loop* client
that gives up, the pool's queue-depth backpressure is what would start shedding
first; that scenario was not exercised here.

## Point 3 — wp-real, N=50, concurrency 128 (real WordPress, CPU-bound)

Realistic WP core; confirms parity where the framework dominates. CPU sits near
saturation (~28–30 of 32 cores).

| Metric | spawn_blocking | pool | Δ (pool vs sb) |
|---|--:|--:|--:|
| Pool size | — (unbounded) | 32 | |
| RPS | 262.5 | 276.5 | +5.3 % |
| p50 ms | 465.64 | 401.09 | −14 % |
| p95 ms | 739.34 | 818.62 | +11 % |
| p99 ms | 2035.85 | 1146.70 | **−44 %** |
| p99.9 ms | 4693.17 | 1520.78 | −68 % |
| max ms | 4966.79 | 1879.41 | −62 % |
| RSS steady MB | 2702 | 581 | **−78 %** |
| RSS peak MB | 2776 | 634 | −77 % |
| CPU cores mean | 27.87 | 29.64 | +6 % |
| fd max | 278 | 244 | |
| 2xx | 6562 | 6913 | |
| errors / non-2xx | 0 | 0 | |

**Read:** throughput is parity (+5 %, within noise for a CPU-bound single run).
Here the pool is the **better** shape *and* the leaner one: with the CPU already
saturated, spawn_blocking's 128 threads add scheduling contention and a heavy
tail (p99 = 2.0 s, max = 5.0 s), while 32 pool threads (1/core) run cleaner
(p99 = 1.1 s, max = 1.9 s) and use **78 % less memory** (581 MB vs 2.70 GB).

---

## Verdict

1. **Is the pool's per-request dispatch overhead measurable on the light path?**
   **No, not on throughput or median.** On wp-lite the pool's *median* latency
   was lower in every case and RPS stayed within ±2 % — the queue → 32-thread
   dispatch does not tax the fast path. What the pool costs on the light path is
   **tail latency when clients exceed the pool size** (Point 1: p99 69 ms vs
   28 ms): that's queuing, not dispatch cost.

2. **Parity on real WP?** **Yes — better than parity on shape.** wp-real
   throughput is even (+5 %), and the pool actually *tightens* the tail
   (p99 −44 %, max −62 %) because it stops oversubscribing an already-saturated
   CPU. WordPress dominates the request, so the engine choice barely moves RPS.

3. **Bounded pool vs unbounded spawn_blocking under overload (the key finding).**
   The engines make opposite trades, and the trade is **memory vs tail latency**:
   - **spawn_blocking**: unbounded threads → **uniform, tight latency** but
     **RSS scales with concurrency** — 2.16 GB at 512 clients, 2.70 GB on real
     WP. One PHP/ZTS context per in-flight request.
   - **pool**: fixed 32 threads → **RSS bounded and flat** (5.7× lower under
     overload; ~78 % lower on real WP) at the cost of a **long tail** on the
     light path (queued requests wait). On the CPU-bound path the pool's tail is
     *better*, because bounding concurrency to core count avoids thrash.
   - **Neither sheds** under this closed-loop load (0 errors everywhere). The
     pool's backpressure is expressed as latency, not 5xx; open-loop shedding
     behavior was not tested.

**Bottom line (honest):** the `pool` engine's headline win is **bounded, flat
memory** — dramatic under high concurrency (5.7×) and on real WordPress (78 %),
with throughput at parity. Its rough edge is **tail latency on the light,
high-concurrency path** (p99 up 2–3× when clients exceed the pool size), the
direct consequence of capping concurrency at core count. For memory-constrained,
multi-tenant, real-framework deployments the pool looks like a clear win; for a
latency-tail-sensitive light endpoint driven well past core count, spawn_blocking's
uniform latency (paid for in RAM) is still preferable. No crashes, hangs, or
errors were observed with either engine. Single-run WSL2 dev-box numbers —
shape, not SLA.

### Raw results

`results/wp-lite/engine-{spawn_blocking,pool}/cap-4096-n-250.json`,
`results/wp-lite-overload/engine-{spawn_blocking,pool}/cap-4096-n-50.json`,
`results/wp-real/engine-{spawn_blocking,pool}/cap-4096-n-50.json`
(each carries `meta.engine` and `meta.pool_size`; a `*.startup.txt` sidecar holds
the engine's own autotune line).
