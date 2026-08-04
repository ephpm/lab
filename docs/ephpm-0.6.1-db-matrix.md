# ePHPm v0.6.1 Database Path Matrix

Three suites on the single-host podman tier described in
[DB-BENCH.md](../DB-BENCH.md). They cover the questions the Kubernetes suites
in this lab cannot reach: which embedded SQLite path ePHPm should use, whether
clustered writes survive concurrency, and whether the connection-pooling
database proxy earns the extra hop it inserts.

> None of these numbers belongs in a table with a k6 result from `k8s/`. They
> are single-host, `--cpus 1`, `oha`, and they exist to compare ePHPm
> configurations against each other.

## Provenance

| | |
| --- | --- |
| ePHPm | main `bdc9861` (v0.6.1 line, post [#221](https://github.com/ephpm/ephpm/pull/221)/[#222](https://github.com/ephpm/ephpm/pull/222)/[#224](https://github.com/ephpm/ephpm/pull/224)), built from `docker/Dockerfile` |
| PHP | 8.5.7, ZTS, glibc |
| litewire | `github.com/ephpm/litewire` @ `62636c4c2ba8` |
| sqld | v0.24.32, embedded via `include_bytes!()` |
| Upstreams | `docker.io/library/mysql:8`, `docker.io/library/postgres:16` |
| Host | Windows 11, podman machine 32 vCPU / 64 GiB. ePHPm containers `--cpus 1`; database upstreams `--cpus 4`. |
| Profile | 8 s warmup, 2 x 15 s reps per cell, every reported cell 100% HTTP 200 |
| Recorded | 2026-08-04 (proxy, admission re-confirmation); engine tables 2026-08-01 on the v0.6.0 line |

**The engine tables in section 1 are v0.6.0 numbers** (`ephpm:v060-rc2`,
litewire `d1c0b341`) and are labelled as such — they were not re-recorded on
v0.6.1. Sections 2 and 3 are `bdc9861`. Do not read a section-1 number against
a section-3 number.

**Host caveat.** One machine, two reps. Rep-to-rep spread exceeds 10% on
several cells, worst on the container-to-container lanes where two `--cpus 1`
cgroups compete. Both reps are printed rather than averaged. Differences under
roughly 20% on this hardware are unresolved, and are called out as such rather
than reported as results.

---

## 1. Engines: rusqlite vs Turso, single-node vs clustered

Four lanes, one fixture pair. `db.php` is ten sequential `SELECT`s; `write.php`
is one `INSERT`. The read fixture cannot separate clustered from single-node —
on a primary a `SELECT` never touches replication — so the write fixture is the
one that matters for the clustering question.

Every clustered lane was gated on **verified replication**: five rows written on
the primary, then the replica polled until it agreed. A cluster whose
replication is quietly broken benchmarks exactly like a fast single node.

| Lane | db c=1 RPS | db c=1 p50 | db c=16 RPS | write c=1 RPS | write c=16 RPS |
| --- | ---: | ---: | ---: | ---: | ---: |
| SQLite single-node (rusqlite, production default) | 321 / 321 | 3.09 ms | 612 / 609 | 648 / 636 | 1130 / 1119 |
| Turso single-node (experimental) | 367 / 371 | 2.66 ms | 644 / 646 | 665 / 666 | 1120 / 1117 |
| SQLite clustered (sqld sidecar, production) | 144 / 147 | 6.80 ms | 240 / 240 | 384 / 377 | **0 / 0** |
| Turso clustered (CDC-native, experimental) | 358 / 349 | 2.75 ms | 601 / 600 | 556 / 558 | 876 / 867 |

Two things are worth saying plainly.

**The Turso engine's advantage does not survive the wire path.** Phase 1
microbenchmarks at the litewire seam measured 28x on point `SELECT`s. Through
`mysqlnd` → MySQL wire → engine, on a one-CPU container, it is about 14% at
c=1 and 5% at c=16 — the same shape the `RUNTIMES-BENCH.md` Turso lane exists
to check on Kubernetes. The engine is not the bottleneck; the round trip is.

**Clustered SQLite via sqld does not survive concurrent writes.** The
`write c=16` cell completed **zero** requests in 15 seconds, twice. It does not
return 500s — it hangs, which is why response accounting rather than throughput
is what catches it. Clustered reads also cost roughly 2.2x their single-node
equivalent. The CDC-native Turso path does not have the collapse, but it is
experimental and single-node-engine only.

---

## 2. Admission: bounding sqld's concurrent writes

Follow-up to the collapse above. The hypothesis was that sqld degrades
catastrophically past a small number of in-flight writes, so ePHPm should bound
them rather than let PHP concurrency pass straight through. `write_permits = N`
is a bounded semaphore in front of sqld writes.

**Shipped in v0.6.1** ([ephpm#222](https://github.com/ephpm/ephpm/pull/222)),
default `0` (unlimited, i.e. the v0.6.0 behaviour). The sweep below was taken
against a prototype build; the `write_permits = 1` row was then **re-confirmed
on merged main `bdc9861`**, which is the number to trust.

| Setting | write c=1 | write c=4 | write c=8 | write c=16 | db c=16 |
| --- | ---: | ---: | ---: | ---: | ---: |
| baseline (no admission control) | 451 / 455 | 168 / 552 | **0 / 0** | **0 / 0** | 238 / 236 |
| `write_permits = 1` (prototype) | 443 / 445 | 569 / 573 | 560 / 527 | 551 / 570 | 239 / 237 |
| **`write_permits = 1` on `bdc9861`** | **447 / 453** | **581 / 581** | **619 / 566** | **602 / 597** | **245 / 242** |

Zero 5xx in every cell of the confirmation run, replication verified before
measuring, and the knob proven engaged from the startup log
(`sqld write admission control enabled (reads uncapped; excess writes queue)
write_permits=1`).

The collapse is between 4 and 8 concurrent writes — the c=4 baseline cell caught
it mid-wedge, with one rep at 552 RPS and the other at 168 with a p50 in
seconds. One permit removes it entirely and costs nothing measurable on the read
path (245 vs 238 RPS at c=16) or at c=1. Serialising writes is not a compromise
here; sqld was not doing them in parallel usefully in the first place.

**The default is still `0`,** so a default clustered deployment still wedges at
c>=8. Set `write_permits = 1` if you run clustered SQLite under write load.

The suite gates on the startup log for the knob before measuring, because
`ephpm-config` does not reject unknown fields: an image *without* the change
would silently ignore `write_permits` and produce a baseline lane wearing a
patched lane's label.

---
## 3. Proxy: what the hop costs and what pooling buys

ePHPm can put its own connection-pooling proxy (`[db.mysql]` /
`[db.postgres]`) between PHP and the database. That inserts an extra wire hop
in order to reuse authenticated backend sessions across PHP requests — a trade
worth measuring in both directions, because a PHP request without persistent
connections otherwise pays a fresh connect and handshake every single time.

Ten lanes, four upstreams, **all on one build** so pooled, unpooled and direct
are directly comparable. "Pooling off" is not a switch — there is none. It is
`max_lifetime = "1ms"` plus `min_connections = 0`, which makes `pool.rs` treat
every idle slot as expired at checkout and open a fresh backend connection per
request. The hop is preserved; only reuse is removed.

### Measuring it required fixing it first

Two defects, one hiding the other, both fixed in
[ephpm#221](https://github.com/ephpm/ephpm/pull/221):

1. **`COM_QUIT` was forwarded to the pooled backend**, which closed; the dead
   socket was parked as healthy; the resulting `BrokenPipe` was mapped to
   `Ok(..)` so the corpse was re-parked. v0.6.0 served roughly
   `min_connections` requests and then returned `[2006] MySQL server has gone
   away` to everything after, permanently — at ordinary request rates, while
   looking fine under sustained load.
2. **A permit-accounting deadlock the first defect was masking.**
   `Pool::recycle` parked the semaphore permit *inside* the idle slot, while
   `acquire` takes a permit *before* consulting the idle queue, so returning a
   connection **consumed** a permit rather than releasing one. Once
   `in-use + idle` reached `max_connections` nothing on the healthy path could
   free one again. Killing a connection per request had hidden it, because the
   constant discards released permits continuously.

Neither was visible in throughput. The pooled lanes recorded **876 RPS in which
every response was an HTTP 500**, and `oha` reports those cells as
`Success rate: 100.00%` because it counts transport success, not HTTP status.
Read as throughput they said pooling was 2.9x faster than no proxy at all.
Response accounting is the only reason that is not what this repo now says.

### The hop costs 1.3–2.2 ms per request

Both rows of each pair dial fresh per request, so the proxy is the only
difference between them.

| `db.php`, c=1 | RPS | p50 | Hop cost |
| --- | ---: | ---: | ---: |
| litewire, no proxy | 323 / 323 | 3.05 ms | — |
| litewire via proxy, no reuse | 218 / 217 | 4.53 ms | **−33%, +1.48 ms** |
| `mysql:8`, no proxy | 355 / 356 | 2.75 ms | — |
| `mysql:8` via proxy, no reuse | 241 / 241 | 4.09 ms | **−32%, +1.34 ms** |
| `postgres:16`, no proxy | 104 / 104 | 9.39 ms | — |
| `postgres:16` via proxy, no reuse | 85 / 85 | 11.62 ms | **−19%, +2.23 ms** |

An in-process litewire with no proxy and no container hop runs the same fixture
at 367 / 367 RPS (2.69 ms), so the sidecar container hop is itself worth about
0.36 ms — which is why the sidecar lane, not the in-process one, is the control
for the proxy lanes.

### What pooling buys

Same build, same host, reuse the only variable:

| `db.php` | c=1 no-reuse → pooled | c=16 no-reuse → pooled |
| --- | ---: | ---: |
| litewire | 218 → 249 (**+14%**) | 374 → 705 (**+89%**) |
| `mysql:8` | 241 → 287 (**+19%**) | 510 → 617 (**+21%**) |
| `postgres:16` | 85 → 125 (**+47%**) | 166 → 211 (**+27%**) |

Against connecting *directly*, the answer depends on concurrency and on the
wire protocol:

| vs. direct | c=1 | c=16 |
| --- | ---: | ---: |
| litewire | 323 → 249 (**−23%**) | 490 → 705 (**+44%**) |
| `mysql:8` | 355 → 287 (**−19%**) | 454 → 617 (**+36%**) |
| `postgres:16` | 104 → 125 (**+20%**) | 97 → 211 (**+117%**) |

On the MySQL wire the proxy is a **net loss at c=1 and a net win at c=16** — its
value is concurrency headroom and connection multiplexing, not single-request
latency. PostgreSQL wins at both, for a different reason: `pdo_pgsql` pays a
full SCRAM-SHA-256 handshake on every request and the proxy answers its client
with `AuthenticationOk`, so PHP never does that work. The direct PG path does
not scale at all (104 → 97 RPS from c=1 to c=16); the pooled path more than
doubles.

Write path, c=16, for completeness: litewire 510 → 1233 (**+142%**), `mysql:8`
681 → 1075 (**+58%**), `postgres:16` 336 → 854 (**+154%**).

### The PostgreSQL pool-exhaustion cliff is gone

v0.6.0 at the shipped default `max_connections = 20` collapsed past ~24
concurrent requests — 192 → 7 RPS with 41 of 74 responses 500, p50 pinned to
exactly `pool_timeout`. The original diagnosis here was session pinning; that
was wrong. It was the same permit deadlock. Swept again at the same default:

| concurrency | 16 | 20 | 24 | 32 |
| --- | ---: | ---: | ---: | ---: |
| `db.php` RPS | 210 | 209 | 208 | 208 |
| non-2xx | none | none | none | none |

Flat and clean through 32 concurrent requests against a cap of 20 — queueing,
as intended, rather than failing. `pdo_pgsql` does still pin a backend per PHP
request (the proxy logs `extended query protocol in use; pinning session to
primary`), so the cap is still a concurrency ceiling; it just no longer
collapses when reached.

### The engine gap is engine-side

`db.php` c=1 through an identical pooled path: SQLite p50 3.97 ms vs Turso
3.32 ms — a **650 µs gap, wider than the 440 µs baseline**, not closed.

This settles an open question from the v0.6.0 run, where handle reuse was
verifiably enabled yet the read gap did not move, and the recorded hypothesis
was that handles were being discarded on the disconnect path. A pooled proxy
holds one warm litewire session across many PHP requests — the first
configuration in which reuse has anything to reuse — and the gap still did not
close. The difference is the engine, not per-request connect cost.

### One lane still cannot be built

`[db.mysql]` in front of the **in-process** `[db.sqlite]` litewire still cannot
start on v0.6.1. `start_db_proxies()` awaits the proxy's backend connect inline
and the litewire branch runs after it, so the proxy spends its whole 10-attempt
(~40 s, not configurable) backoff dialling a listener that cannot exist yet,
then gives up. The failure is non-fatal and nearly silent: one `ERROR` line,
then HTTP serves normally with nothing bound to the proxy's port and every
database page returning `[2002] Connection refused`, while liveness and
readiness both look healthy. The config ships as
`db/configs/proxy-litewire-inprocess-BROKEN.toml` and the harness reproduces it
as step 0. The affected lanes use a litewire sidecar with a matched no-proxy
control instead.

## What This Changes

- **Single-node SQLite is the sound default.** The production rusqlite engine
  is within ~14% of the experimental Turso engine through the real wire path,
  and the gap is engine-side: a warm pooled session does not close it.
- **Clustered SQLite via sqld needs `write_permits = 1`.** The default is still
  `0` in v0.6.1, and a default clustered deployment still wedges at c>=8. The
  failure mode is a hang, not an error, so an error-rate dashboard will not see
  it.
- **The database proxy costs 1.3–2.2 ms per request** and buys +14–47% at c=1,
  +21–117% at c=16. On the MySQL wire that makes it a net loss at c=1 and a net
  win at c=16 — concurrency headroom, not latency. On PostgreSQL it wins at
  both, because it takes a per-request SCRAM-SHA-256 handshake off PHP.
- **Two pool defects made every v0.6.0 pooling number meaningless**, in both
  directions: the pooled lanes reported 876 RPS of pure HTTP 500s, and the
  unpooled baseline was achieved while discarding and redialling a connection
  per request. Both are fixed in v0.6.1.
- **The PostgreSQL cliff at the shipped `max_connections = 20` is gone.**
  `pdo_pgsql` still pins a backend per request so the cap remains a concurrency
  ceiling, but reaching it now queues instead of collapsing.

Almost all of that was found by counting response statuses rather than reading
throughput. Two of the findings are invisible in the RPS column and one of them
*looks like a win* there — 876 requests per second, none of them successful. If
this suite has a single methodological point, it is that one.
