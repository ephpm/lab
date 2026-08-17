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

> **Historical (pre-v0.7.0).** This file's suites pin `v0.6.3`, and three of
> them exercise machinery that was **removed upstream in v0.7.0**: the rusqlite
> engine (`[db.sqlite] engine = "sqlite"` is now a hard startup error with a
> migration message), the sqld sidecar, the `[db.sqlite.sqld] write_permits`
> knob, and `cdc_experimental`. Concretely, on a v0.7.0+ image:
>
> - the `engines` suite's rusqlite and sqld-cluster lanes fail at startup
>   (`single-sqlite.toml`, `cluster-sqlite-*.toml`), and the rusqlite half of
>   `bridge` fails the same way;
> - the entire `admission` suite sweeps a knob that no longer exists — the
>   startup-log gate will correctly refuse every permit lane;
> - the Turso-vs-rusqlite comparison itself is no longer reproducible on any
>   shippable image, because there is only one engine.
>
> These suites are retained **as the historical record against the pinned
> v0.6.3 image** — the parity evidence behind the v0.7.0 engine switch — the
> same way ePHPm's own
> [results page](https://ephpm.dev/benchmarking/results/) marks its pre-v0.7.0
> engine and admission sections historical. A future v0.7.0 pin bump replaces
> them with a Turso-single vs Turso-CDC-clustered matrix rather than editing
> these lanes.

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
> defaults to `ephpm/ephpm:v0.6.3-php8.5`, which contains those fixes, the
> `write_permits` admission knob, and the `ephpm_db_*` in-process bridge — so
> every suite in this file, including `bridge`, runs on the default image. On
> anything older than v0.6.1 the pooled lanes reproduce the two defects rather
> than the numbers, and on anything older than v0.6.3 the `bridge` suite fails
> its function-registration gate.

## Suites

| Suite | Question | Runs on |
| --- | --- | --- |
| `engines` | rusqlite vs Turso, single-node vs clustered sqld | Published image |
| `admission` | Does bounded write admission fix the clustered write collapse? | v0.6.1+ (knob merged in ephpm#222) |
| `proxy` | What does the DB proxy cost (a hop) and buy (pooling)? | v0.6.1+ (pool fixes in ephpm#221) |
| `bridge` | What does skipping the wire entirely buy? `ephpm_db_*` vs pdo_mysql, per engine | v0.6.3+ (bridge shipped in ephpm#257/#258) |
| `wp-bridge` | Does the bridge move a real app? WordPress with the db-wordpress drop-in vs mysqli | v0.6.3+ |

```bash
./scripts/run-db-bench.sh engines
./scripts/run-db-bench.sh admission        # needs v0.6.1+ (default image is fine)
./scripts/run-db-bench.sh proxy
./scripts/run-db-bench.sh bridge           # needs v0.6.3+ (ephpm_db_* functions)
./scripts/run-db-bench.sh wp-bridge        # needs v0.6.3+ and network on first run
./scripts/run-db-bench.sh all --image docker.io/ephpm/ephpm:v0.6.3-php8.5
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

## The Deliberately-Broken Config (proxy STEP 0)

`db/configs/proxy-litewire-inprocess-BROKEN.toml` is broken **on purpose**, and
`db/bench-proxy.sh` runs it first ("STEP 0") on every invocation. It chains
`[db.mysql]` (the proxy) in front of the *same process's* in-process
`[db.sqlite]` litewire — a topology ePHPm cannot start: `start_db_proxies()`
awaits the proxy's backend connect inline and the litewire branch runs after
it, so the proxy spends its entire ~40 s ten-attempt backoff dialling a
listener that cannot exist yet, then gives up **non-fatally and nearly
silently** — the server goes on serving HTTP with nothing bound to the proxy
port and every database page returning `[2002] Connection refused`, while
liveness and readiness both look healthy (see the "Still true in v0.6.1" notes
on ePHPm's [results page](https://ephpm.dev/benchmarking/results/), which this
step reproduces). STEP 0 archives the evidence as
`db/results-proxy/FINDING-startup-order.log` each run. It is a gate in its own
right: it *proves* the proxy-vs-litewire lanes (B2/C2/J2) had to use a separate
litewire sidecar container, instead of leaving that as an assertion in prose.

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
engine (rusqlite and Turso, `single-sqlite.toml` / `single-turso.toml`), six
cells each: {point-select, insert, wide-select} × {wire, bridge}. Wire and
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

**No lab numbers yet.** These suites landed with the v0.6.3 pin bump and have
not been recorded with this harness. For scale, the ephpm-side development
benches this week (dev box, WSL, LTO off — *not* this harness, *not* the
published image, do not put them in a table with anything above): a bridge
point-select ran ~61 µs on rusqlite and ~3.4 µs on the Turso engine, against
roughly 200 µs for the same query over the wire path, and WordPress pages
rendered 10–16% faster with the drop-in. Treat those as the hypothesis this
suite exists to check on a published image, not as results. Reference numbers
will be recorded on `ephpm/ephpm:v0.6.3-php8.5` and added here.

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
  lines and the harness defaults have since moved to v0.6.3.** As with the
  v0.5.0 autotuning note in `RUNTIMES-BENCH.md`, a version bump changes the
  effective configuration, so numbers recorded across a bump are not directly
  comparable. Re-record rather than assume.
- **The `admission` suite needs v0.6.1 or later** — satisfied by the default
  image since the v0.6.3 pin bump. The `write_permits` knob it sweeps merged in
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
