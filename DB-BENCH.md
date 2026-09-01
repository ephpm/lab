# ePHPm Database Path Benchmarks

This suite measures the part of ePHPm that the Kubernetes suites cannot see: the
path between PHP and its database. It covers the embedded Turso engine
single-node and CDC-clustered, whole-database and per-vhost (the `cluster`
suite), and the in-process connection-pooling proxy (`[db.mysql]` /
`[db.postgres]`) in front of four different upstreams. It also retains, as the
historical record, the suites that measured the rusqlite engine and the sqld
replication path — both removed upstream in v0.7.0.

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
> engine and admission sections historical.
>
> **The promised replacement now exists.** That Turso-single vs
> Turso-CDC-clustered matrix is the [`cluster` suite](#the-cluster-suite-turso-single-vs-turso-cdc-clustered),
> added alongside these lanes rather than by editing them, and it extends the
> promise in one direction the original note did not anticipate: it also covers
> **per-vhost** clustered replication, which did not exist when that note was
> written. The historical lanes below are unchanged.
>
> Because the two generations need different images, **the default image is now
> per suite** (see the box below). Bumping the historical suites would not
> modernise them; `engine = "sqlite"` is a hard startup error on v0.7.0+, so it
> would only replace a real measurement with a failed launch.

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

> **Which image these numbers need.** There are two image lines here and the
> harness picks per suite:
>
> | Suites | Default image | Why that one |
> | --- | --- | --- |
> | `engines`, `admission`, `proxy`, `bridge`, `wp-bridge` | `ephpm/ephpm:v0.6.3-php8.5` | The newest image that still has the rusqlite engine, the sqld sidecar and `write_permits`. It also has the v0.6.1 pool fixes and the `ephpm_db_*` bridge, so all five run on it. |
> | `cluster` | `ephpm/ephpm:v0.8.5-php8.5` | The newest **published** image. |
>
> `--image` (or `EPHPM_IMAGE`) overrides whichever default applies. Below
> v0.6.1 the pooled proxy lanes reproduce two defects rather than the numbers;
> below v0.6.3 `bridge` fails its function-registration gate; at v0.7.0 and
> above the rusqlite and sqld lanes fail at startup by design.
>
> v0.8.6 is tagged upstream but its images are not on Docker Hub at the time of
> writing, which is why the `cluster` default is v0.8.5 — and why two of that
> suite's five lanes cannot run on a published image yet. See the `cluster`
> section for exactly which, and for the environment variable that points them
> at a newer build.

## Suites

| Suite | Question | Runs on |
| --- | --- | --- |
| `engines` | rusqlite vs Turso, single-node vs clustered sqld | v0.6.0–v0.6.3 only (**historical**) |
| `admission` | Does bounded write admission fix the clustered write collapse? | v0.6.1–v0.6.3 only (**historical**; knob merged in ephpm#222, removed in v0.7.0) |
| `proxy` | What does the DB proxy cost (a hop) and buy (pooling)? | v0.6.1–v0.6.3 (pool fixes in ephpm#221; two lanes use the removed rusqlite engine) |
| `bridge` | What does skipping the wire entirely buy? `ephpm_db_*` vs pdo_mysql, per engine | v0.6.3 (bridge shipped in ephpm#257/#258; lane A is rusqlite) |
| `wp-bridge` | Does the bridge move a real app? WordPress with the db-wordpress drop-in vs mysqli | v0.6.3 (lane `wp-sqlite` is rusqlite) |
| `cluster` | What does Turso CDC replication cost — whole-database, and per vhost? | v0.8.5+ for three of five lanes; **v0.8.6+** for the two per-site clustered lanes |

```bash
./scripts/run-db-bench.sh engines           # historical: pins v0.6.3 automatically
./scripts/run-db-bench.sh admission         # historical: pins v0.6.3 automatically
./scripts/run-db-bench.sh proxy             # historical: pins v0.6.3 automatically
./scripts/run-db-bench.sh bridge            # historical: pins v0.6.3 automatically
./scripts/run-db-bench.sh wp-bridge         # historical: + network on first run
./scripts/run-db-bench.sh cluster           # current: pins the newest published image
./scripts/run-db-bench.sh all               # each suite gets its own default image
```

There is deliberately **no single `--image` that runs everything**. The first
five suites and the sixth measure two different generations of the same
subsystem; a flag that forced them onto one image would necessarily break one
group or the other.

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
`oha`, warmup plus two timed reps per cell (15 s for `admission` and `proxy`;
the `engines` numbers were taken with `DUR=20s`, which is **not** the harness
default of 15 s — set it explicitly to reproduce them), every reported cell
verified 100% HTTP 200. These exist so
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

## The `cluster` Suite: Turso Single vs Turso CDC-Clustered

This is the replacement promised in the historical banner at the top of this
file, and it covers one axis that promise predates. As of v0.7.0 there is one
embedded engine, so "which engine" is no longer a question. The questions that
replaced it are all about **replication**:

- What does clustering cost when nothing else changes?
- What does it cost a *tenant*, in the multi-tenant deployment shape that is
  the v0.7.0+ default?
- And in per-vhost clustered mode, where ownership of a site is decided by
  rendezvous hashing and any node will serve any tenant — what does it cost to
  be asked for a site you do **not** own?

That last one is the headline. In per-site clustered mode
(`[db.sqlite.replication] per_site = true`, ephpm#416, experimental) each vhost
gets its own database that replicates across the cluster, and a node that is
not a site's HRW owner forwards every `ephpm_db_*` statement to the owner over
`sql/<site>`. Reads and writes both work on every node. The forward hop is the
price, and until now nobody had measured it.

### Lanes

| Lane | Shape | Measured on | Answers |
| --- | --- | --- | --- |
| `S-turso-single` | single-site, single node | the node | Anchor. Turso with no cluster at all, and the tie-back to the historical `bridge` suite's B-turso lane. |
| `W-cluster-primary` | single-site, whole-DB clustered, 2 nodes | the **primary** | What CDC capture and shipping cost on the write path. `S → W` is "what does clustering cost". |
| `P1-persite-single` | multi-tenant, single node, 1 DB per vhost | the node | The v0.7.0+ multi-tenant default, and the reference point for the two clustered per-site lanes. |
| `P2-persite-owner` | multi-tenant **clustered**, 3 nodes | the site's **owner** | What per-site clustering costs a tenant on the node that owns it. `P1 → P2` is "what does clustering cost a tenant". |
| `P3-persite-remote` | the same cluster, the same site | a **non-owner** | The `sql/<site>` forward hop. `P2 → P3` is the number people ask about first. |

Cells per lane are `bridge-point` (ten sequential point `SELECT`s through
`ephpm_db_query()`) and `bridge-write` (one `INSERT` through
`ephpm_db_execute()`), at c=1 and c=16, warmup plus two timed reps — identical
to every other suite in this file. The three multi-tenant lanes add a
`wire-point` cell over stock `pdo_mysql`.

That `wire-point` cell is not decoration and not a duplicate. In per-site
clustered mode the bridge forwards to the owner but **stock `pdo_mysql` does
not** — it resolves the local database on whichever node served the request (a
documented gap in ephpm#416). So on a non-owner, `bridge-point` pays the hop
and `wire-point` does not. Measuring both is what makes "the difference is the
hop" falsifiable rather than asserted: if `P3`'s `wire-point` were *also*
slower than `P2`'s, whatever slowed it down would not be forwarding.

### What This Does Not Answer

- **Not production throughput.** Same local-tier caveat as everything else in
  this file: one host, `--cpus 1` per node, three ePHPm containers scheduled
  against each other across a podman bridge. It answers "what did this cost",
  not "what will this serve".
- **Not failover.** Every lane measures a settled cluster with stable
  membership. Ownership churn — a node joining or dying and re-homing a site
  mid-flight — is where per-site clustered mode's interesting failure modes
  live, and this suite deliberately does not go there. It is a throughput
  matrix, not a chaos test.
- **Not "is clustered mode ready".** Turso is Beta upstream and per-site
  clustered mode is marked experimental by ePHPm itself. A cost measurement is
  not a maturity claim.
- **S vs P1 is not a measurement of anything.** They are different deployment
  shapes. Read `S→W`, `P1→P2`, and `P2→P3`; reading across the two groups
  compares single-site to multi-tenant and answers a question nobody asked.

### Gates

The five general gates at the top of this file all apply. Three are specific to
this suite, and the first of them earned its place immediately:

1. **The mode gate, and why it is the most important gate in this file.** Four
   different database modes are selected by a *conjunction* of keys spread
   across `[server]`, `[db.sqlite]`, `[db.sqlite.replication]` and `[cluster]`,
   and `ephpm-config` does not reject unknown fields. An image that predates a
   knob parses it, ignores it, and starts happily in a **different mode** — one
   that then benchmarks perfectly well under the wrong label.

   This is not hypothetical. The first run of this suite pointed the per-site
   clustered lanes at the newest published image and got a healthy, fast,
   fully-2xx three-node cluster. It was running whole-database clustered mode,
   because `per_site` does not exist in that image. Every gate except this one
   passed. Only the startup log said otherwise, and every lane now asserts a
   specific startup line before a single request is measured.

2. **The negative control.** The fixture directory is mounted at both the
   default document root and the vhost's, so the *same PHP files* are reachable
   with and without the vhost `Host` header. Without it the request must fail
   with "no per-site database context". If that ever passed, the tenant would
   be selected by the mount rather than by the request and every per-site
   number here would be meaningless.

3. **Exactly one owner, agreed by two independent observations.** The suite
   measures **one** vhost, which is what makes ownership externally decidable:
   with a single site in the cluster, "this node has attached CDC subscribers"
   (`ephpm_cdc_subscribers` on `/metrics`) and "this node owns the site"
   (`elected as SQLite primary` in its log) must name the same node. Zero
   owners means no replica ever attached; two means membership had not settled.
   Either way P2 and P3 cannot be labelled, so they are refused rather than
   reported. Note that `/_ephpm/primary` cannot be used here — in per-site mode
   it deliberately answers 200 on *every* healthy node, because every node
   accepts writes for every site.

Replication convergence (general gate 4) has a wrinkle worth stating, because
getting it backwards makes the gate vacuous. The proof writes through the
**bridge** and counts over stock **`pdo_mysql`**. It has to be that way round: a
bridge-side count on a non-owner forwards to the owner, so it would read the
owner's database from every node and agree with itself even if replication were
completely dead. `pdo_mysql` is not forwarded, so it is the only one of the two
that can actually observe a replica.

### A Setup Step With Teeth

On a non-owner the bridge hands back a remote proxy and **never opens the
site's local database file**. The per-site registry's open-hook therefore never
fires, and that node never starts a replica driver for the site — it sits there
replicating nothing. A cluster in that state passes a naive smoke test and
holds the tenant's data on exactly one node.

What opens it locally is a stock `pdo_mysql` request. So the suite hits
`count.php` on every node before gating on convergence, and the ordering is
load-bearing: seed through the bridge, open locally on every node, *then* gate.
This is worth knowing outside the lab — a per-site clustered deployment whose
apps use only the `ephpm_db_*` drop-ins may never open a tenant's database on
the nodes that do not own it.

### The Divergence Probe

After the measurements — never before — each per-site clustered run writes one
row over stock `pdo_mysql` on the non-owner, then counts on both nodes and
prints the difference. The writer's local count comes out one higher than the
owner's: that row exists on exactly one node and is discarded when the replica
next re-bootstraps.

It runs last on purpose. A probe that mutates server state must not precede the
lane it decorates, and this lab has been burned by exactly that shape before —
the session-leak probe that poisoned each pooled proxy lane before measuring
it, producing 876 requests per second of pure HTTP 500 (see the Gates section
above). This one injects a row that only one node will ever see, which is
precisely the kind of state a measured lane should not start with.

### Running It

```bash
./scripts/run-db-bench.sh cluster           # all five lanes
bash db/bench-cluster.sh s                  # or one lane: s | w | p1 | p23
```

Lanes S, W and P1 run on the default published image. **Lanes P2 and P3 do
not**: per-site clustered replication first appears in the ePHPm v0.8.6 tag,
whose Docker images are not published at the time of writing. Point them at a
newer build with

```bash
EPHPM_PERSITE_CLUSTER_IMAGE=<a v0.8.6+ image> ./scripts/run-db-bench.sh cluster
```

Without it those two lanes fail their mode gate with a message saying exactly
this, which is the correct outcome — the alternative is a confidently
mislabelled result.

The suite uses its own podman network (`dbcluster-net`) with an **explicit**
subnet, rather than the `dbbench-net` the other suites share. The clustered
configs must name exact IPs — clustered replication fails closed on an
unspecified bind address, because it would have nothing dialable to advertise —
and the older configs assume whatever subnet podman happened to hand
`dbbench-net`. Declaring it makes that assumption a fact. The suite also removes
its own containers, volumes and network on exit, which the older suites do not
(see `db/cleanup.sh`).

### Reference Numbers

**None yet — the suite is authored and gate-validated, not recorded.** Every
lane has been run end to end against `ephpm/ephpm:v0.8.5-php8.5` on podman with
short durations, purely to prove the lanes produce clean, fully-2xx numbers and
that the gates fire correctly; those runs are not measurements and are not
reported here. Lanes P2 and P3 have never run in their intended mode at all,
for the image reason above. Reference numbers will be recorded once a v0.8.6+
image is published, and only then.

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
- **The `admission` suite needs v0.6.1 or later _and earlier than v0.7.0_** —
  satisfied by its pinned v0.6.3 default and by nothing newer. The knob it
  sweeps was removed in v0.7.0 along with sqld, so the window is closed at both
  ends; on a v0.7.0+ image the startup-log gate correctly refuses every lane.
  The `write_permits` knob it sweeps merged in
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
db/bench-cluster.sh          Turso single vs CDC-clustered, whole-DB and per-vhost
db/parse.sh                  Shared results parser with response accounting
db/cleanup.sh                Remove every podman resource the db suites create
db/probe-clean-vs-dirty.sh   Mechanism probe: pooled-connection poisoning
db/probe-reset.sh            Mechanism probe: COM_RESET_CONNECTION against a pooled backend
db/probe-pg.sh               Mechanism probe: does pdo_pgsql pin the session?
db/configs/*.toml            One file per lane; pairs differ in as few keys as possible
db/configs/persite-*.toml    cluster suite: per-site single-node and clustered
db/configs/whole-cluster-*.toml  cluster suite: whole-database CDC primary/replica
db/fixtures/{sqlite,mysql,postgres}/*.php
db/fixtures/bridge/*.php     ephpm_db_* twins of the sqlite fixtures + wide-select
db/fixtures/cluster/*.php    cluster suite: bridge + wire twins, local count probe
db/fixtures/wp/*.php         WordPress mu-plugin gates (X-Db-Driver)
db/results-*/                Raw oha output (gitignored) — keep it locally
```

Raw `oha` output is written per cell and never deleted by the harness. A
filtering bug in a summary script must not be able to silently discard a
measurement that was actually taken.
