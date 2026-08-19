# ePHPm Database Path Benchmarks

This suite measures the part of ePHPm that the Kubernetes suites cannot see: the
path between PHP and its database. It covers the embedded SQLite engines
(rusqlite and Turso), the clustered sqld replication path, and the in-process
connection-pooling proxy (`[db.mysql]` / `[db.postgres]`) in front of four
different upstreams.

> This is not "ePHPm's database path is fast." It is "ePHPm's database path has
> a connect cost that dominates short requests, and its proxy exists to amortise
> that cost — which it does, when the pool is actually reused."

## Relationship to ePHPm v0.7.0

The v0.7.0 pin bump **split this file's suites in two**, because v0.7.0
removed the rusqlite engine (`[db.sqlite] engine = "sqlite"` is now a hard
startup error with a migration message), the sqld sidecar, the
`[db.sqlite.sqld] write_permits` knob, and `cdc_experimental`.

| Suite | Pin | Why |
| --- | --- | --- |
| `proxy` | **v0.7.0** | Measures the wire hop and the pool in front of litewire / `mysql:8` / `postgres:16`. Its litewire lanes now run the **Turso** engine on both releases, so the suite is comparable across the bump. |
| `bridge` | **v0.7.0** | The Turso lane is the whole suite now; the rusqlite lane is opt-in and separately pinned (below). |
| `wp-bridge` | **v0.7.0** | Same split as `bridge`. |
| `engines` | **v0.6.3, hard-pinned** | Three of four lanes are removed machinery. |
| `admission` | **v0.6.3, hard-pinned** | Sweeps a knob that no longer exists. |

The two historical suites **ignore `--image` / `EPHPM_IMAGE`** and read
`EPHPM_ENGINES_IMAGE` / `EPHPM_ADMISSION_BASE_IMAGE` instead. That is
deliberate: `scripts/run-db-bench.sh` now defaults to a v0.7.0 image, and
letting these inherit it would give `engines` three dead lanes plus one
*silently mislabelled* one — `cluster-turso-primary.toml` sets
`replication.cdc_experimental = true`, `ephpm-config` does not reject unknown
fields, so on v0.7.0 that line is ignored and lane D would be a different
topology wearing lane D's name.

The rusqlite halves of `bridge` and `wp-bridge` survive the same way: opt-in
via `BRIDGE_LEGACY_SQLITE=1` / `WP_BRIDGE_LEGACY_SQLITE=1`, and then hard-run
on the v0.6.3 image. **A v0.6.3 rusqlite lane and a v0.7.0 Turso lane differ
by a whole release, not by an engine** — the scripts print each lane's image
in its banner and warn on the legacy lane for exactly that reason. Never put
them in one table.

> **Historical numbers stay historical.** Every recorded table below was taken
> on the v0.6.0/v0.6.1/v0.6.3 lines and is retained as the parity evidence
> behind the v0.7.0 engine switch — the same way ePHPm's own
> [results page](https://ephpm.dev/benchmarking/results/) marks its pre-v0.7.0
> engine and admission sections historical. Replacing the `engines` matrix for
> v0.7.0 means a **new** Turso-single vs Turso-CDC-clustered suite, not edits
> to these lanes.

## Why This Runs On Podman, Not Kubernetes

Every other suite in this lab runs k6 jobs against a real cluster, because the
things they measure — framework boot, opcache behaviour, worker capacity — are
milliseconds wide and survive network jitter. The effects here are not. A wire
protocol hop, a connection-pool checkout and a write-admission semaphore are
tens to hundreds of microseconds apart, and inter-pod scheduling noise on a
shared cluster is larger than the entire signal.

So these suites are the **local single-node tier**: one host, podman, `--cpus 1`
per ePHPm container, `oha` as the load generator, warmup plus two timed reps per
cell. They answer *"did this change cost anything, and where"*. They do not
answer *"what throughput will production see"* — the Kubernetes suites are still
the place for that, and the two tiers must never be put in the same table.

> **Which image these numbers need.** The proxy results below require a build
> with the v0.6.1 pool fixes (ePHPm main `bdc9861` or later). The harness now
> defaults to `ephpm/ephpm:v0.7.0-php8.5`, which contains those fixes and the
> `ephpm_db_*` in-process bridge, so `proxy`, `bridge` and `wp-bridge` all run
> on the default image. On anything older than v0.6.1 the pooled lanes
> reproduce the two defects rather than the numbers, and on anything older than
> v0.6.3 the `bridge` suite fails its function-registration gate. The
> `engines` and `admission` suites do **not** follow this default — see
> "Relationship to ePHPm v0.7.0" above.

## Suites

| Suite | Question | Runs on |
| --- | --- | --- |
| `engines` | rusqlite vs Turso, single-node vs clustered sqld | **v0.6.3 only** (historical; hard-pinned) |
| `admission` | Does bounded write admission fix the clustered write collapse? | **v0.6.3 only** (historical; hard-pinned) |
| `proxy` | What does the DB proxy cost (a hop) and buy (pooling)? | v0.6.1+ (pool fixes in ephpm#221) |
| `bridge` | What does skipping the wire entirely buy? `ephpm_db_*` vs pdo_mysql | v0.6.3+ (bridge shipped in ephpm#257/#258) |
| `wp-bridge` | Does the bridge move a real app? WordPress with the db-wordpress drop-in vs mysqli | v0.6.3+ |

```bash
./scripts/run-db-bench.sh engines          # historical, always v0.6.3
./scripts/run-db-bench.sh admission        # historical, always v0.6.3
./scripts/run-db-bench.sh proxy
./scripts/run-db-bench.sh bridge           # Turso lane only by default
./scripts/run-db-bench.sh wp-bridge        # needs network on first run
./scripts/run-db-bench.sh all --image docker.io/ephpm/ephpm:v0.7.0-php8.5

# Opt into the removed-engine lanes. These run on v0.6.3 no matter what
# --image says, and belong in their own table:
BRIDGE_LEGACY_SQLITE=1    ./scripts/run-db-bench.sh bridge
WP_BRIDGE_LEGACY_SQLITE=1 ./scripts/run-db-bench.sh wp-bridge
```

## Fixtures

The same two fixtures drive every lane, in three SQL dialects
(`db/fixtures/{sqlite,mysql,postgres}`):

- **`db.php`** — one connect plus **ten sequential** point `SELECT`s. Sequential
  is load-bearing: the fixture exists to measure per-query round-trip through
  whatever sits in the path, so the queries must not batch or pipeline. Returns
  the canonical `{"sum":55}`, which every lane is gated on.
- **`write.php`** — one `INSERT`, its own implicit transaction. This is the
  fixture that separates single-node from clustered: on a primary, a `SELECT`
  never touches replication.

`seed.php` and `count.php` are gates, never load. The dialects differ only where
they must (`AUTOINCREMENT` vs `AUTO_INCREMENT` vs `SERIAL`; a real server needs
a database named in the DSN, litewire has an implicit one). The connection code
is **inlined** in each fixture rather than `require`d from a shared file — an
include is per-request work the litewire lanes would not otherwise do, and a
lane-vs-lane comparison should not carry it.

The `bridge` suite adds a third workload, **wide-select** (one `SELECT`
returning 100 rows × 8 columns), and a bridge twin for each of the three
(`db/fixtures/bridge/{point,write,wide}.php`) — same SQL text, same tables,
through `ephpm_db_query()`/`ephpm_db_execute()` instead of PDO. Seed data is
deterministic by construction (values are fixed functions of the row id — a
"fixed seed" with no RNG to misreport), and every table is dropped and
re-created per lane.

## Gates

Every lane must prove itself before any of its numbers are believed:

1. **The config took effect.** Each lane asserts the listeners its topology
   requires are in the startup log — and, for the no-proxy control lanes, that
   *no* proxy listener is in the log at all. `ephpm-config` does not reject
   unknown fields, so a knob that silently did nothing would otherwise produce a
   confidently mislabelled result.
2. **The fixture is right.** `db.php` must return `sum: 55`.
3. **The data reached the upstream it claims to have reached.** The real-server
   lanes count the rows *inside* the `mysql:8` / `postgres:16` container.
4. **Replication actually converged**, for clustered lanes — write five rows on
   the primary, poll the replica until it agrees. Without this a cluster with
   broken replication benchmarks exactly like a fast single node, and gets
   reported as a great result.
5. **Every cell is 100% 2xx.** `db/parse.sh` prints the completed-2xx count and
   any non-2xx or transport error per cell and prefixes unclean rows with `!!`.
   A cell that is not fully 2xx is not a measurement.

The last one is the same trap `RUNTIMES-BENCH.md` documents for the rate
limiter, in a different costume — and it is not hypothetical here. Three lanes
in the proxy matrix recorded 876 requests per second in which **every single
response was an HTTP 500**. `oha` reports those cells as
`Success rate: 100.00%`, because it counts transport success rather than HTTP
status. Read as throughput, they say connection pooling is 2.9x faster than no
proxy at all. Read with the status distribution, they say the pooled path is
broken. Gate 5 is the only reason the second reading is the one in this repo.

## Local Reference Numbers

Measured on one developer machine: Windows 11 host, podman machine with 32
vCPU / 64 GiB, ePHPm containers pinned to `--cpus 1`, upstream `mysql:8` and
`postgres:16` containers at `--cpus 4` so the upstream is never the bottleneck.
`oha`, warmup plus two timed reps per cell (15 s for `admission` and `proxy`,
20 s for `engines`), every reported cell verified 100% HTTP 200. These exist so
you can sanity-check your own run; they are not claims about production
throughput, and they are not comparable to any k6 number in this repo.

### Provenance

| | |
| --- | --- |
| ePHPm | main `bdc9861` (v0.6.1 line, post #221/#222/#224), built from `docker/Dockerfile` |
| PHP | 8.5.7, ZTS, glibc |
| litewire | `github.com/ephpm/litewire` @ `62636c4c2ba8` |
| sqld | v0.24.32, embedded |
| Upstreams | `docker.io/library/mysql:8`, `docker.io/library/postgres:16` |
| Engine tables | Recorded earlier on the v0.6.0 line (`ephpm:v060-rc2`, litewire `d1c0b341`) and **not** re-recorded on v0.6.1 — do not read them against the proxy tables |
| Host caveat | Single host. Container-to-container lanes cross the podman bridge; in-process lanes do not. The two are labelled separately and the difference between them is reported, not hidden. |

### Engines (`db.php`, 10 sequential SELECTs)

| Lane | c=1 RPS | c=1 p50 | c=16 RPS | write c=16 RPS |
| --- | ---: | ---: | ---: | ---: |
| SQLite single-node (production default) | 321 / 321 | 3.09 ms | 612 / 609 | 1130 / 1119 |
| Turso single-node (experimental) | 367 / 371 | 2.66 ms | 644 / 646 | 1120 / 1117 |
| SQLite clustered (sqld) | 144 / 147 | 6.80 ms | 240 / 240 | **0 / 0** |
| Turso clustered (CDC, experimental) | 358 / 349 | 2.75 ms | 601 / 600 | 876 / 867 |

### Proxy (`db.php`, c=1) — all lanes on one build

| Lane | RPS | p50 | vs. no proxy |
| --- | ---: | ---: | ---: |
| litewire, no proxy | 323 / 323 | 3.05 ms | — |
| litewire via proxy, no reuse | 218 / 217 | 4.53 ms | −33% (the hop) |
| litewire via proxy, pooled | 249 / 249 | 3.97 ms | −23% |
| `mysql:8`, no proxy | 355 / 356 | 2.75 ms | — |
| `mysql:8` via proxy, no reuse | 241 / 241 | 4.09 ms | −32% (the hop) |
| `mysql:8` via proxy, pooled | 287 / 287 | 3.44 ms | −19% |
| `postgres:16`, no proxy | 104 / 104 | 9.39 ms | — |
| `postgres:16` via proxy, no reuse | 85 / 85 | 11.62 ms | −19% (the hop) |
| `postgres:16` via proxy, pooled | 125 / 125 | 7.91 ms | **+20%** |

At c=16 the picture inverts on the MySQL wire: litewire 490 → 705 (**+44%**),
`mysql:8` 454 → 617 (**+36%**), `postgres:16` 97 → 211 (**+117%**). The proxy
buys concurrency headroom, not single-request latency.

Both defects that made the v0.6.0 pooled lanes unmeasurable — `COM_QUIT`
relayed to the pooled backend, and a permit-accounting deadlock it was masking
— are fixed in v0.6.1. The full story, including the 876 RPS of pure HTTP 500s
that nearly became a headline, is in
[docs/ephpm-0.6.1-db-matrix.md](docs/ephpm-0.6.1-db-matrix.md).

### Re-recorded: litewire proxy lanes on `v0.6.3-php8.5`, Turso (2026-08-18)

Same host and method as the `bridge` recording below. Only the litewire lanes
ran; the `mysql:8` / `postgres:16` lanes (D/E/F/G/H/I and `F24-pg-cliff`) were
**skipped** because their upstream containers were not running — see the
skip-message change in `bench-proxy.sh`. Mean of 2 × 15 s reps, RPS.

| Lane | `db.php` c=1 | c=16 | `write.php` c=1 | c=16 |
| --- | ---: | ---: | ---: | ---: |
| A — litewire in-process, no proxy | 401.9 | 629.0 | 747.0 | 1239.2 |
| A2 — litewire sidecar, no proxy | 358.5 | 500.4 ⚠ | 346.5 ⚠ | 627.5 ⚠ |
| B2 — sidecar via proxy, pooled | 295.8 | 680.7 | 691.2 | 1235.1 |
| C2 — sidecar via proxy, no reuse | 230.7 | 334.1 ⚠ | 359.0 | 484.2 |

The v0.6.1-era shape holds: at c=1 the proxy is a net loss against the direct
sidecar (B2 296 vs A2 358, −17 %), and pooling is what buys it back at c=16
(B2 681 vs C2 334, **+104 %**). The hop itself still costs (A 402 → B2 296 at
c=1, though A is in-process and B2 crosses the podman bridge, so that pair is
not a clean hop measurement — A2 is the right control).

⚠ **Two integrity problems in this run, reported rather than smoothed:**

1. **A2 produced HTTP 500s.** `A2 write c=16 rep 2` returned **1454 × HTTP
   500** alongside 6867 × 200 — `db/parse.sh` flagged it `!!`. Per gate 5 that
   cell is not a measurement, and the A2 write row above should be read as
   suspect, not as a number.
2. **A2 is wildly unstable at c=1 on writes**: reps of 444.5 and 248.6 RPS
   (56 % spread) — far outside this suite's "treat <20 % as unresolved" rule.
   `C2 db c=16` (289.6 / 378.5) and `A2 db c=16` (403.0 / 597.8) are similarly
   unstable.

Whether that instability is the sidecar topology, the litewire frontend under
concurrent writes, or this host is **not established by this run**. It is
logged here as an open question, not as a v0.6.3 defect claim.

**Both problems are now diagnosed — see the A2 subsection below. They are a
harness artifact, not an ePHPm defect.**

### Re-recorded: litewire proxy lanes on `v0.7.0-php8.5` (2026-08-19)

Same host, same method, same session as the `bridge` v0.7.0 recording. Lanes
D/E/H and F/G/I + `F24-pg-cliff` **skipped** again — no `dbbench-mysql` /
`dbbench-pg` upstreams were running. Skipped is absence, not a measurement.
Mean of 2 × 15 s reps, RPS. The v0.6.3 column is the 2026-08-18 recording
(prior session — unlike the `bridge` table above, there is no same-session
control here).

| Lane | fixture | c | v0.6.3 | v0.7.0 | Δ |
| --- | --- | ---: | ---: | ---: | ---: |
| A — litewire in-process, no proxy | db | 1 | 401.9 | 362.0 | −9.9 % |
| A — litewire in-process, no proxy | db | 16 | 629.0 | 447.9 | **−28.8 %** |
| A — litewire in-process, no proxy | write | 1 | 747.0 | 657.9 | −11.9 % |
| A — litewire in-process, no proxy | write | 16 | 1239.2 | 1042.3 | −15.9 % |
| A2 — litewire sidecar, no proxy | db | 1 | 358.5 ⚠ | 314.4 ⚠ | not a measurement |
| A2 — litewire sidecar, no proxy | db | 16 | 500.4 ⚠ | 385.8 ⚠ | not a measurement |
| A2 — litewire sidecar, no proxy | write | 1 | 346.5 ⚠ | 370.5 ⚠ | not a measurement |
| A2 — litewire sidecar, no proxy | write | 16 | 627.5 ⚠ | 579.7 ⚠ | not a measurement |
| B2 — sidecar via proxy, pooled | db | 1 | 295.8 | 275.6 | −6.8 % |
| B2 — sidecar via proxy, pooled | db | 16 | 680.7 | 630.7 | −7.3 % |
| B2 — sidecar via proxy, pooled | write | 1 | 691.2 | 641.8 | −7.2 % |
| B2 — sidecar via proxy, pooled | write | 16 | 1235.1 | 1224.4 | −0.9 % |
| C2 — sidecar via proxy, no reuse | db | 1 | 230.7 | 219.0 | −5.1 % |
| C2 — sidecar via proxy, no reuse | db | 16 | 334.1 ⚠ | 330.7 ⚠ | −1.0 % (both noisy) |
| C2 — sidecar via proxy, no reuse | write | 1 | 359.0 | 363.3 | +1.2 % |
| C2 — sidecar via proxy, no reuse | write | 16 | 484.2 | 466.6 | −3.6 % |

The **shape** of the suite is unchanged across the release: the proxy is still
a net loss at c=1 and pooling still buys it back at c=16 (v0.7.0: B2 630.7 vs
C2 330.7 on `db` c=16, **+91 %**, against +104 % on v0.6.3).

The **level** carries the same wire regression the `bridge` suite found, and
localises it further. Lane A is the in-process litewire wire path — the same
thing `bridge`'s wire cells measure — and it is down 9.9–28.8 %. Lanes B2/C2
route through the proxy and move far less (−7.3 % to +1.2 %, mostly inside
noise). Pooling amortises whatever got more expensive; a per-request connect
pays it in full. See the `bridge` section for the litewire-0.2.0 hypothesis.

⚠ **A2's HTTP 500s and instability: diagnosed, and it is the harness.**

The A2 defect recurred on v0.7.0 — `A2 write c=16 rep 2` returned **581 ×
HTTP 500** alongside 8145 × 200 (v0.6.3 rep 2: 1454 × 500). Same lane, same
fixture, same concurrency, same rep, two releases, two sessions. That
reproducibility made it worth chasing, so this run reproduced it under a
body-capturing probe instead of leaving it as an open question. The error is:

```
SQLSTATE[HY000] [2002] Cannot assign requested address
```

That is `EADDRNOTAVAIL` — **client-side ephemeral TCP port exhaustion**, not a
database error. Confirmed inside the A2 PHP container during sustained load:

```
/proc/sys/net/ipv4/ip_local_port_range = 32768 60999   (28 231 ports)
/proc/net/sockstat                     = TCP: ... tw 5807
```

A2 is the one lane that opens a **fresh TCP connection to a remote host on
every request** with no reuse anywhere in the path. At ~500–800 req/s each
closed connection sits in `TIME_WAIT` for ~60 s, so steady-state demand is
~30 000–48 000 ports against a 28 231-port budget. `connect()` then fails, PHP
raises `PDOException`, and `write.php` returns its 500.

This explains every previously-unexplained feature of the A2 rows:

- **Why it is always rep 2.** `TIME_WAIT` accumulates across warmup + rep 1 +
  rep 2. The budget is not exhausted until ~60 s of sustained load — which
  lands in rep 2 every time.
- **Why the c=1 write cell is bimodal** (v0.6.3 444.5 / 248.6, 56 % spread;
  v0.7.0 449.3 / 291.8, 42 %). At ~450 req/s × 60 s `TIME_WAIT` ≈ 27 000
  sockets, the lane runs *right at* the 28 231-port boundary: one rep clears
  it, the next collapses.
- **Why only A2.** Lane A is in-process (no TCP). B2 pools. C2 has no reuse but
  runs at ~220–470 req/s through a localhost proxy hop, below the threshold.
- **Why it is release-independent.** It reproduces identically on v0.6.3 and
  v0.7.0 because it is a property of the topology, not of ePHPm.

**Conclusion: A2 is not a valid lane as configured, and never was.** It is
measuring the host's ephemeral-port recycling as much as ePHPm. Its four cells
are struck from both releases' tables above rather than compared. This is *not*
an ePHPm bug — but it *is* a real-world caveat worth stating plainly: **any PHP
app that opens a fresh remote `pdo_mysql` connection per request, with no
persistent connections and no proxy, will hit this ceiling at a few hundred
requests per second.** That is precisely the cost the in-process bridge and the
pooling proxy exist to remove, and A2 accidentally demonstrates it. Fixing the
lane (rather than deleting it) needs connection reuse, a widened
`ip_local_port_range`, or `tcp_tw_reuse` — all of which change what it measures,
so the lane should be re-scoped or dropped rather than patched into silence.

## The Formerly-Broken Config (proxy STEP 0) — **fixed upstream**

`db/configs/proxy-litewire-inprocess-BROKEN.toml` chains `[db.mysql]` (the
proxy) in front of the *same process's* in-process `[db.sqlite]` litewire, and
`db/bench-proxy.sh` runs it first ("STEP 0") on every invocation.

**Historically (v0.6.1 and earlier)** this was a topology ePHPm could not
start: `start_db_proxies()` awaited the proxy's backend connect inline and the
litewire branch ran after it, so the proxy spent its entire ~40 s ten-attempt
backoff dialling a listener that could not exist yet, then gave up
**non-fatally and nearly silently** — the server went on serving HTTP with
nothing bound to the proxy port and every database page returning
`[2002] Connection refused`, while liveness and readiness both looked healthy.
That is the behaviour recorded in the "Still true in v0.6.1" notes on ePHPm's
[results page](https://ephpm.dev/benchmarking/results/).

**It no longer reproduces.** Re-run on `v0.6.3-php8.5` (2026-08-18), STEP 0
produced a *working* chain. The proxy now binds first and resolves its upstream
asynchronously:

```
INFO ephpm_db::mysql: MySQL proxy listening (upstream connect continues in the
     background) listen=127.0.0.1:3306 upstream=127.0.0.1:3307
INFO ephpm_server: SQLite MySQL wire protocol enabled listen=127.0.0.1:3307
WARN ephpm_db::health: database proxy upstream connect failed: Connection
     refused (os error 111) ... failures=1
INFO ephpm_db::mysql: backend connection established after retry attempt=2
```

One refused attempt, then connected ~250 ms later; `db.php` returned a real SQL
error (`no such table: bench` — STEP 0 never seeds) instead of
`[2002] Connection refused`. The inline-await ordering defect is gone.

Two consequences, both of which should be carried upstream:

1. **ephpm.dev's results page is stale on this point** — the "Still true in
   v0.6.1" note describes behaviour that a v0.6.3 image does not exhibit.
2. **STEP 0 is no longer a gate.** It used to *prove* that the
   proxy-vs-litewire lanes (B2/C2) had to use a separate litewire sidecar
   container. That proof is gone; the sidecar is now a deliberate isolation
   choice (it keeps the proxy and the backend in separate `--cpus 1` cgroups,
   matching the other container-to-container lanes) rather than a forced one.

The step is retained because it still archives
`db/results-proxy/FINDING-startup-order.log` every run, which is what caught
the change. The config's `engine` was switched from `"sqlite"` to `"turso"` in
the v0.7.0 pin bump; the fix above is in proxy startup sequencing and is
engine-independent, but note the two changes landed in the same run.

## The Bridge Suites (`bridge`, `wp-bridge`)

v0.6.3 ships the in-process DB bridge
([ephpm#257](https://github.com/ephpm/ephpm/pull/257) /
[#258](https://github.com/ephpm/ephpm/pull/258)): `ephpm_db_query()` and
`ephpm_db_execute()`, registered whenever `[db.sqlite]` is active, executing
SQL through a per-thread litewire Session against the **same backend instance
the MySQL wire frontend serves**. Same dialect translation, same
`SHOW`/`information_schema` emulation, same error mapping — no TCP, no PDO, no
resultset protocol.

The `bridge` suite measures what that deletion is worth. One container per
engine — on the v0.7.0 pin that is the Turso lane alone (`single-turso.toml`);
the rusqlite lane (`single-sqlite.toml`) is opt-in and runs on v0.6.3, see
above — six cells each: {point-select, insert, wide-select} × {wire, bridge}.
Wire and
bridge cells run against the **same process**, so nothing differs but the
path. The wire cells keep their per-request PDO connect deliberately — that is
what a real PHP request pays without persistent connections, and removing it
is the bridge's whole pitch, not a confound. Warmup and reps are identical to
the other suites; `db/parse.sh` reports p50/p95/p99 per cell.

Its gates, beyond the usual ones: `bridge/seed.php` fails the lane loudly if
the `ephpm_db_*` functions are not registered (an older image would otherwise
404-or-fallback its way into a mislabelled lane), and the wide table is
written **through the bridge** then read back **over the wire**, proving both
paths hit the same backend rather than two databases wearing one label.

The `wp-bridge` suite asks whether any of this moves a real application.
WordPress is installed through the wire frontend (wp-cli → mysqli → litewire,
the same bootstrap as the
[turso-cluster-e2e demo](https://github.com/ephpm/turso-cluster-e2e)) with
deterministic content, then the front page and a single-post page are measured
twice per engine: stock mysqli `wpdb`, and the
[ephpm/db-wordpress](https://github.com/ephpm/db-wordpress) drop-in
(`wp-content/db.php`) routing `wpdb` through the bridge. The only difference
between the two cells is the drop-in file. Because the drop-in is designed to
**fall back to mysqli silently** when anything is off, every cell is gated on
an `X-Db-Driver` response header emitted by a mu-plugin (present in both
cells): `wpdb` for the wire cells, `Ephpm\Db\WordPress\Db` for the bridge
cells. A fallen-back bridge cell fails the gate instead of benchmarking the
wire path under the wrong label.

### Recorded: `bridge` on `ephpm/ephpm:v0.6.3-php8.5` (2026-08-18)

First recording of this suite with this harness. Host: Windows 11, podman
machine 32 vCPU / 62 GiB, ePHPm container `--cpus 1`, `oha`, 8 s warmup plus
**2 × 15 s** timed reps per cell, machine load average 0.00–0.96 throughout.
**Every cell below was 100 % HTTP 200.** Mean of the two reps, RPS.

Both lanes ran on the **same image**, differing only in `[db.sqlite] engine`,
so this is a clean rusqlite-vs-Turso A/B — the last release on which that
comparison is possible at all.

| Cell | rusqlite | Turso | Turso vs rusqlite |
| --- | ---: | ---: | ---: |
| wire-point c=1 | 384.6 | 403.6 | +4.9 % |
| wire-point c=16 | 629.3 | 560.1 | −11.0 % ⚠ |
| wire-write c=1 | 771.0 | 718.0 | −6.9 % |
| wire-write c=16 | 1333.4 | 1239.7 | −7.0 % |
| wire-wide c=1 | 704.9 | 655.4 | −7.0 % |
| wire-wide c=16 | 1214.7 | 1104.0 | −9.1 % |
| bridge-point c=1 | 663.7 | 915.7 | **+38.0 %** |
| bridge-point c=16 | 1108.5 | 1585.8 | **+43.1 %** |
| bridge-write c=1 | 1054.5 | 1037.3 | −1.6 % |
| bridge-write c=16 | 1543.2 | 1651.2 | +7.0 % |
| bridge-wide c=1 | 899.3 | 944.3 | +5.0 % |
| bridge-wide c=16 | 1617.3 | 1624.4 | +0.4 % |

⚠ `wire-point c=16` on Turso is the one noisy cell in the run: reps of 599.7
and 520.5 (13 % spread). Per this file's own two-reps caveat, treat it as
unresolved rather than as a −11 % result.

**What the bridge is worth** (same lane, wire vs its bridge twin):

| | rusqlite | Turso |
| --- | ---: | ---: |
| point-select c=1 | 1.73× | **2.27×** |
| point-select c=16 | 1.76× | **2.83×** |
| insert c=1 | 1.37× | 1.44× |
| insert c=16 | 1.16× | 1.33× |
| wide-select c=1 | 1.28× | 1.44× |
| wide-select c=16 | 1.33× | 1.47× |

Deleting the wire is worth 1.2–1.8× on rusqlite and 1.3–2.8× on Turso. The
engine choice barely moves the **wire** path (it is dominated by connect and
protocol cost) but moves the **bridge** path a lot — which is the expected
shape: the bridge is the only path where engine time is a large share of the
request.

For scale, the earlier ephpm-side development benches (dev box, WSL, LTO off —
*not* this harness, *not* the published image, do not table them with the
above) measured a bridge point-select at ~61 µs on rusqlite and ~3.4 µs on
Turso against ~200 µs over the wire. Those in-process microbench ratios do
**not** survive to the HTTP level: end to end the bridge is worth 2.3–2.8× on
Turso, not 60×, because a full request is mostly PHP and HTTP, not SQL.

**`wp-bridge` has still not been recorded** with this harness.

### Recorded: `bridge` on `ephpm/ephpm:v0.7.0-php8.5` (2026-08-19) — **wire-path regression**

`v0.7.0` published 2026-08-19, tag commit `c84e3c6`. Images verified pullable
before measuring: `v0.7.0-php8.3`, `-php8.4`, `-php8.5`, `v0.7.0`, `latest` —
all five present as manifest lists. Measured on
`docker.io/ephpm/ephpm:v0.7.0-php8.5`,
digest `sha256:c40689f2a8c019922fc1ed8a601a794d7ea5ccae117de7120738536730b49db8`
(`org.opencontainers.image.version = v0.7.0+php8.5.7`, `revision = c84e3c6…`).

**Both arms of this table were recorded in one session, back to back, on an
otherwise idle box.** The v0.6.3 arm is a *fresh control re-run*
(`v0.6.3-php8.5`, digest `sha256:2f93bfbb…`), not the 2026-08-18 recording
above — a −20 % cross-session delta is exactly the kind of claim that host
drift can manufacture, so the control removes drift as an explanation rather
than arguing about it. The control reproduced the 2026-08-18 baseline on every
cell (e.g. `wire-point c=1` 416.4 vs 403.6; `bridge-point c=16` 1662.1 vs
1585.8), which is also a small piece of evidence that this harness is stable
across sessions.

Method identical to the recording above: `--cpus 1`, `oha`, 8 s warmup plus
2 × 15 s timed reps, mean RPS. **All 24 v0.7.0 cells and all 24 control cells
were 100 % HTTP 200** (`db/parse.sh` flagged nothing). Load average on the
podman machine (32 vCPU), sampled every 30 s: v0.7.0 run median 1.37 / p90 2.57
/ max 7.57; control+proxy run median 1.25 / p90 2.73 / max 5.89 — matched
profiles, and all of it generated by the benchmark itself (`oha` is not
CPU-capped, so the c=16 cells drive loadavg to ~5–7 transiently). No other
workload ran: `ephpm` and `oha` were the only processes above 1 % CPU.

> The 2026-08-18 recording's "machine load average 0.00–0.96 throughout" does
> not survive denser sampling. At 30 s intervals the same harness reaches 5–7
> during c=16 cells. That earlier figure was sampled too sparsely to see the
> c=16 windows; it is corrected here rather than left standing.

| Cell | v0.6.3 (control) | v0.7.0 | Δ | rep spread (v0.6.3 / v0.7.0) |
| --- | ---: | ---: | ---: | --- |
| wire-point c=1 | 416.4 | 318.8 | **−23.4 %** | 1.7 % / 2.0 % |
| wire-point c=16 | 640.1 | 440.3 | **−31.2 %** | 0.2 % / 3.7 % |
| wire-write c=1 | 755.8 | 638.6 | −15.5 % | 0.1 % / 1.2 % |
| wire-write c=16 | 1235.3 | 1004.8 | −18.7 % | 2.1 % / 4.7 % |
| wire-wide c=1 | 671.8 | 575.2 | −14.4 % | 1.5 % / 10.0 % |
| wire-wide c=16 | 1108.5 | 878.3 | **−20.8 %** | 1.6 % / 5.3 % |
| bridge-point c=1 | 1052.9 | 1020.4 | −3.1 % | 2.8 % / 2.2 % |
| bridge-point c=16 | 1662.1 | 1647.8 | −0.9 % | 0.2 % / 0.4 % |
| bridge-write c=1 | 1046.9 | 1034.0 | −1.2 % | 2.7 % / 3.3 % |
| bridge-write c=16 | 1620.3 | 1541.3 | −4.9 % | 4.3 % / 9.3 % |
| bridge-wide c=1 | 989.9 | 988.5 | −0.1 % | 2.8 % / 0.2 % |
| bridge-wide c=16 | 1629.3 | 1664.6 | +2.2 % | 3.0 % / 0.3 % |

**The result is a clean split.** Every one of the six **bridge** cells is
within ±5 % — flat, at or below this harness's own rep-to-rep noise. Every one
of the six **wire** cells is down, by 14–31 %. Three wire cells clear this
file's "treat <20 % as unresolved" bar on their own (`wire-point` at both
concurrencies, `wire-wide c=16`); the other three sit at 14–19 %, under that
bar individually. But the bar exists to stop a single noisy cell being read as
a result, and this is not one cell: it is **6 of 6 wire cells moving the same
direction, in a run whose intra-cell spreads are 0.1–10 %, against a
same-session control that itself reproduces a prior-session recording.**
Collectively the wire regression is resolved. Individually, `wire-write c=1`,
`wire-write c=16` and `wire-wide c=1` are not.

**Where the cost is.** The wire cells and their bridge twins run in the *same
process* against the *same* backend instance. The only thing a wire cell does
that its bridge twin does not is open a `pdo_mysql` connection to litewire's
MySQL frontend and speak the protocol. The bridge cells did not move; the wire
cells did. So the regression is in the **per-request connect + MySQL frontend
path**, not in the Turso engine, not in PHP, and not in ePHPm's HTTP layer —
any of which would have moved both halves together.

The `proxy` suite recorded the same day agrees independently: its `A-lite-inproc`
lane (the same in-process wire path, different suite) is down 9.9–28.8 %, while
its pooled proxy lane `B2` — which reuses backend connections and so pays the
frontend handshake once per pooled connection rather than once per request — is
down only 0.9–7.3 %.

**Hypothesis, not a finding.** Between the two pins, litewire moved
`e34c63928ed9` → `10345a869d27` (0.2.0) and turso moved `=0.7.0` → `=0.7.2`.
litewire's MySQL frontend gained, over that range, a `ConnectionAuthenticator`
path with a random per-connection scramble, an `opensrv-mysql` TLS feature
fence, a server-side tenant-session SQL screen, and the litewire#28–#31
wire-fidelity fixes. Per-connection handshake work is the shape that would
produce exactly this signature — a cost paid once per connection, invisible to
the bridge, amortised away by pooling. **This has not been bisected and is not
established by this run.** The decisive next step is to bisect the litewire pin
against a fixed ePHPm build.

**This is a shipped regression.** v0.7.0 is published. Any deployment using
stock `pdo_mysql` against the embedded engine — which is the documented default
integration — gets 14–31 % less throughput than v0.6.3 on these fixtures.
Applications on the `ephpm_db_*` bridge are unaffected.

**What the bridge is worth**, per release (same lane, wire vs its bridge twin):

| | v0.6.3 (control) | v0.7.0 |
| --- | ---: | ---: |
| point-select c=1 | 2.53× | 3.20× |
| point-select c=16 | 2.60× | 3.74× |
| insert c=1 | 1.39× | 1.62× |
| insert c=16 | 1.31× | 1.53× |
| wide-select c=1 | 1.47× | 1.72× |
| wide-select c=16 | 1.47× | 1.90× |

> **Do not quote the v0.7.0 column as an improvement to the bridge.** The
> bridge did not get faster — every bridge cell is flat within noise. The
> multiplier grew because its *denominator* shrank. "The bridge is now worth
> 3.7×" and "the wire path lost 31 %" are the same measurement, and only the
> second one is news.

The ~60× in-process microbench ratio still does **not** survive to the HTTP
level, and the v0.7.0 numbers reinforce that: end to end the bridge is worth
1.5–3.7×, not 60×, because a full request is mostly PHP and HTTP, not SQL. The
2.3–2.8× recorded on 2026-08-18 and the 2.5–2.6× measured on the control here
are the honest figure for v0.6.3; 3.2–3.7× is the v0.7.0 figure and it is
inflated by a regression rather than earned.

## Caveats

- **`--cpus 1` is the point, not a limitation.** These fixtures are dominated by
  per-request setup, and an unconstrained host hides that behind spare cores.
  The constraint is what makes a connect cost visible.

- **Two reps is enough to spot a 2x effect and not enough to publish a 10%
  one.** Several cells in these tables show rep-to-rep spread well above 10%,
  especially the container-to-container lanes where two `--cpus 1` cgroups are
  scheduled against each other. Where that happens both reps are printed rather
  than averaged away. Treat any difference under about 20% between two lanes on
  this hardware as unresolved.

- **"Pooling off" is not a code path.** There is no such switch in ePHPm. It is
  `max_lifetime = "1ms"` plus `min_connections = 0`, which makes the pool treat
  every idle slot as expired at checkout and open a fresh backend connection per
  PHP request. The hop is preserved and only *reuse* is removed, which is what
  isolates the two effects. It does leave one artefact: on the write fixture the
  connection is dirty, so it still pays a `COM_RESET_CONNECTION` round trip
  before being discarded. Pool-off write numbers are therefore slightly
  pessimistic against a hypothetical true no-pool build.

- **The `engines` and `admission` numbers were recorded on the v0.6.0/v0.6.1
  lines and cannot be re-recorded.** As with the v0.5.0 autotuning note in
  `RUNTIMES-BENCH.md`, a version bump changes the effective configuration, so
  numbers recorded across a bump are not directly comparable — and here the
  bump deleted the mechanism outright, so there is no later version to
  re-record on. They are frozen evidence, not a baseline to compare against.

- **A v0.7.0 number and a v0.6.3 number on any database path are an engine
  comparison.** v0.7.0 has one embedded engine (Turso); v0.6.3's default was
  the genuine-SQLite C engine. A Turso-lane-to-Turso-lane comparison across
  the two releases *is* meaningful (same engine, different release); a
  v0.6.3 rusqlite lane against a v0.7.0 lane is not, and the harness keeps
  them apart deliberately. Say which you are reporting.

- **The `admission` suite needs v0.6.1 or later** — satisfied by its
  hard-pinned v0.6.3 image. The `write_permits` knob it sweeps merged in
  [ephpm#222](https://github.com/ephpm/ephpm/pull/222) and is not in v0.6.0 or
  earlier; on an older image the `baseline` row is all you get — which on its
  own demonstrates the collapse that motivated the knob. The suite gates on the
  startup log before measuring, because `ephpm-config` does not reject unknown
  fields: an image without the knob would silently ignore it and produce a
  baseline lane wearing a patched lane's label.

## Layout

```
DB-BENCH.md                  This file: recipe, gates, reference numbers
scripts/run-db-bench.sh      Driver: picks a suite, sets image/duration, parses
db/bench-engines.sh          4-lane engine + clustering matrix
db/bench-admission.sh        sqld write-admission sweep (default image)
db/bench-proxy.sh            Proxy cost/benefit matrix
db/bench-bridge.sh           In-process ephpm_db_* vs MySQL wire, per engine
db/bench-wordpress-bridge.sh WordPress: db-wordpress drop-in vs mysqli wire
db/parse.sh                  Shared results parser with response accounting
db/probe-clean-vs-dirty.sh   Mechanism probe: pooled-connection poisoning
db/probe-reset.sh            Mechanism probe: COM_RESET_CONNECTION against a pooled backend
db/probe-pg.sh               Mechanism probe: does pdo_pgsql pin the session?
db/configs/*.toml            One file per lane; pairs differ in as few keys as possible
db/fixtures/{sqlite,mysql,postgres}/*.php
db/fixtures/bridge/*.php     ephpm_db_* twins of the sqlite fixtures + wide-select
db/fixtures/wp/*.php         WordPress mu-plugin gates (X-Db-Driver)
db/results-*/                Raw oha output (gitignored) — keep it locally
```

Raw `oha` output is written per cell and never deleted by the harness. A
filtering bug in a summary script must not be able to silently discard a
measurement that was actually taken.
