# cluster — what Turso CDC replication costs, whole-database and per-vhost

**TL;DR: the `sql/<site>` forward hop is the expensive one, and it is now
measured.** On a node that does not own a tenant, every `ephpm_db_*` statement
crosses the cluster channel to the owner at a cost of **~0.25–0.28 ms per
statement**, which is **−69%** throughput on the ten-query read fixture and
**−54%** on the single-INSERT write fixture at c=1. Per-site clustering itself
(owner-local, no hop) costs a tenant **−17% at c=1 / −28% at c=16** on the
write path. Whole-database clustering costs **~12–13%** at c=1 — small enough
that this harness calls it unresolved, and nothing like the write collapse the
historical sqld lane recorded. The `wire-point` control behaved exactly as
designed: on the non-owner the *non-forwarded* path is **not** slower
(+6% at c=1, +1% at c=16), which is what makes "the difference is the hop" a
falsifiable claim rather than an assertion.

These are the first recorded numbers for this suite. Lanes P2 and P3 had never
run in their intended mode before — per-site clustered replication needs
[ephpm#416](https://github.com/ephpm/ephpm/pull/416), and no published image
had it until v0.8.6/v0.8.7.

Harness: [`db/bench-cluster.sh`](../DB-BENCH.md#the-cluster-suite-turso-single-vs-turso-cdc-clustered).
Local podman tier — one host, `--cpus 1` per node. It answers "what did this
cost", not "what will this serve".

## Provenance

| | |
| --- | --- |
| Image | `docker.io/ephpm/ephpm:v0.8.7-php8.5` (published 2026-09-01 09:17 UTC) |
| Image ID | `85c3444cedcd` |
| ePHPm | v0.8.7 — contains [#416](https://github.com/ephpm/ephpm/pull/416) (per-site clustered) and [#429](https://github.com/ephpm/ephpm/pull/429) `c5b269a` (replicate per-site DBs on bridge-only nodes; reject unknown `[db.sqlite]` keys). Does **not** contain #434. |
| PHP | 8.5.7, ZTS, glibc |
| Engine | Turso (pure-Rust, in-process) via litewire |
| Host | Windows 11, podman 5.8.3 machine (32 vCPU / 64 GiB); every ePHPm node `--cpus 1` |
| Network | `dbcluster-net`, explicit subnet `10.89.7.0/24`, static IPs |
| Load | `ghcr.io/hatoo/oha`, `DUR=15s`, `REPS=2`, `WARMUP=8s`, c ∈ {1, 16} |
| Date | 2026-09-01 |
| Gates | All passed. 52/52 cells 100% HTTP 200 — no `!!` rows. Suite exit 0. |

## Results

Both reps are printed rather than averaged, per this repo's convention. RPS is
`Requests/sec`; p50/p95/p99 are from `db/parse.sh`.

### c=1

| Lane | Cell | RPS (r1 / r2) | spread | p50 | p95 | p99 |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| `S-turso-single` | bridge-point | 1009 / 1054 | 4.4% | 0.91 ms | 1.39 / 1.11 ms | 2.00 / 1.63 ms |
| `S-turso-single` | bridge-write | 907 / 966 | 6.3% | 0.96 / 0.94 ms | 1.83 / 1.54 ms | 2.58 / 2.22 ms |
| `W-cluster-primary` | bridge-point | 877 / 943 | 7.2% | 0.96 ms | 1.98 / 1.51 ms | 3.64 / 2.36 ms |
| `W-cluster-primary` | bridge-write | 840 / 789 | 6.3% | 1.02 / 1.07 ms | 1.96 / 2.21 ms | 3.40 / 3.73 ms |
| `P1-persite-single` | bridge-point | 494 / 553 | 11.3% | 1.22 / 1.52 ms | 5.43 / 3.27 ms | 8.87 / 6.31 ms |
| `P1-persite-single` | bridge-write | 826 / 827 | 0.2% | 1.18 ms | 1.36 / 1.34 ms | 1.49 / 1.45 ms |
| `P1-persite-single` | wire-point | 354 / 333 | 5.9% | 2.73 / 2.89 ms | 3.26 / 3.77 ms | 4.15 / 4.38 ms |
| `P2-persite-owner` | bridge-point | 829 / 826 | 0.3% | 1.18 ms | 1.35 ms | 1.46 ms |
| `P2-persite-owner` | bridge-write | 689 / 688 | 0.3% | 1.30 / 1.31 ms | 2.34 / 2.39 ms | 2.98 / 3.00 ms |
| `P2-persite-owner` | wire-point | 310 / 338 | 8.7% | 3.20 / 2.91 ms | 3.50 / 3.26 ms | 3.73 / 3.44 ms |
| `P3-persite-remote` | bridge-point | 253 / 253 | 0.3% | 3.93 / 3.91 ms | 4.22 / 4.23 ms | 4.41 / 4.43 ms |
| `P3-persite-remote` | bridge-write | 325 / 313 | 3.8% | 1.55 ms | 15.35 / 15.75 ms | 24.97 / 26.21 ms |
| `P3-persite-remote` | wire-point | 343 / 344 | 0.3% | 2.87 ms | 3.17 / 3.15 ms | 3.38 / 3.32 ms |

### c=16

| Lane | Cell | RPS (r1 / r2) | spread | p50 |
| --- | --- | ---: | ---: | ---: |
| `S-turso-single` | bridge-point | 1225 / 1536 | 22.5% | 10.70 / 10.78 ms |
| `S-turso-single` | bridge-write | 1052 / 1379 | 26.9% | 10.37 / 10.43 ms |
| `W-cluster-primary` | bridge-point | 1596 / 1612 | 1.0% | 10.48 / 10.44 ms |
| `W-cluster-primary` | bridge-write | 1082 / 1336 | 21.0% | 12.00 / 11.64 ms |
| `P1-persite-single` | bridge-point | 1101 / 1126 | 2.2% | 13.93 / 13.65 ms |
| `P1-persite-single` | bridge-write | 1334 / 1304 | 2.2% | 12.74 / 13.03 ms |
| `P1-persite-single` | wire-point | 592 / 585 | 1.1% | 26.65 / 26.92 ms |
| `P2-persite-owner` | bridge-point | 1342 / 1342 | 0.0% | 12.41 / 12.40 ms |
| `P2-persite-owner` | bridge-write | 988 / 910 | 8.3% | 14.35 / 16.94 ms |
| `P2-persite-owner` | wire-point | 551 / 556 | 0.8% | 28.53 / 28.37 ms |
| `P3-persite-remote` | bridge-point | 525 / 521 | 0.9% | 30.49 / 30.74 ms |
| `P3-persite-remote` | bridge-write | 429 / 417 | 2.9% | 36.07 / 36.79 ms |
| `P3-persite-remote` | wire-point | 562 / 558 | 0.7% | 28.09 / 28.22 ms |

## The three deltas

This file's caveat says to treat a difference under about 20% on this hardware
as unresolved. That threshold exists because rep-to-rep spread is often
10–25%. It is a heuristic about noise, not a constant: where a cell's two reps
land within 0.3% of each other, a 17% gap is fifty times the observed spread
and is not noise. Each verdict below states which case it is.

### S → W — what does clustering cost? **Unresolved, and small.**

| Cell | S | W | Δ |
| --- | ---: | ---: | ---: |
| bridge-point c=1 | 1031 | 910 | **−11.8%** |
| bridge-write c=1 | 937 | 815 | **−13.0%** |
| bridge-point c=16 | 1381 | 1604 | +16.2% |
| bridge-write c=16 | 1216 | 1209 | −0.6% |

At c=1 both fixtures agree on a ~12–13% cost for CDC capture and shipping, but
S's spread is 4–6% and W's is 6–7%, so by this harness's own rule the effect is
**not resolved** — it is bounded above at roughly 13%, and that is the honest
statement. At c=16 it is worse than unresolved: S's two reps differ by 22–27%,
and the point cell comes out with the *clustered* lane ahead. Nothing can be
read from the c=16 row of this pair.

What *is* worth stating: whole-database CDC clustering does not collapse the
write path. The historical `engines` lane for clustered **sqld** recorded
**0 / 0 RPS** on the write fixture — the defect that motivated the
`write_permits` knob. The CDC path measured here writes at 97–99% of the
single-node lane's c=16 throughput. Different image generation, different
fixture, so this is not a table comparison — but the qualitative difference
between "0" and "parity" does not need one.

### P1 → P2 — what does clustering cost a *tenant*? **−17% (c=1) to −28% (c=16) on writes. Reads not measurable from this run.**

| Cell | P1 | P2 | Δ |
| --- | ---: | ---: | ---: |
| bridge-write c=1 | 826 | 689 | **−16.7%** |
| bridge-write c=16 | 1319 | 949 | **−28.1%** |
| wire-point c=1 (control) | 343 | 324 | −5.6% |
| wire-point c=16 (control) | 588 | 553 | −6.0% |
| bridge-point c=1 | 524 | 828 | *+58% — see anomaly* |

The write path is the trustworthy comparison and it is clean: both c=1 cells
have 0.2–0.3% rep spread, so a 16.7% gap is decisively resolved despite being
under the 20% heuristic. At c=16 the gap widens to 28.1%, above the threshold
on its own terms. That is the cost of per-site CDC capture on the owner.

The `wire-point` control is flat (−6%, inside its own 6–9% spread), confirming
the write-path cost is replication work and not a general slowdown of the
clustered build.

**Anomaly — `P1-persite-single` `bridge-point` is not trustworthy.** It reports
494/553 RPS with 11.3% spread, p95 5.43/3.27 ms and p99 8.87/6.31 ms. In every
other lane the ten-query read fixture is *at least as fast* as the one-INSERT
write fixture (S: 1031 vs 937; W: 910 vs 815; P2: 828 vs 689). In P1 alone the
read is **36% slower than the write on the same node**, with a tail an order of
magnitude worse than P2's tightly-clustered 1.35 ms p95. A single-node,
no-cluster lane should not have a worse read tail than a three-node clustered
one. Taking the delta at face value would say per-site clustering makes reads
58% *faster*, which is not a credible mechanism. The read-path P1→P2 delta is
therefore reported as **not measurable from this run**; P1 should be
re-recorded on its own before anyone quotes a read number for it.

### P2 → P3 — the `sql/<site>` forward hop. **−69% on reads, −54% on writes. Resolved.**

| Cell | P2 (owner) | P3 (non-owner) | Δ |
| --- | ---: | ---: | ---: |
| bridge-point c=1 | 828 | 253 | **−69.4%** (3.27×) |
| bridge-write c=1 | 689 | 319 | **−53.7%** (2.16×) |
| bridge-point c=16 | 1342 | 523 | **−61.0%** |
| bridge-write c=16 | 949 | 423 | **−55.4%** |
| **wire-point c=1 (control)** | 324 | 344 | **+6.1%** |
| **wire-point c=16 (control)** | 553 | 560 | **+1.2%** |

This is the number people ask about first, and it is the best-resolved result
in the suite: the four bridge cells have 0.0–3.8% rep spread against effects of
54–69%.

The two fixtures agree on a **per-statement** cost, derived independently:

- **read**, 10 forwarded statements: p50 1.181 → 3.929 ms = +2.748 ms
  ⇒ **275 µs per statement**
- **write**, 1 forwarded statement: p50 1.299 → 1.554 ms = +0.255 ms
  ⇒ **255 µs per statement**

Two fixtures with a 10× difference in statement count landing within 8% of each
other on per-statement cost is a strong sign the model is right: the hop is
paid **per statement**, not per request. A request issuing ten queries on a
non-owner pays it ten times. This is the single most actionable number here —
it means chatty request patterns are penalised super-linearly by *not* owning
the tenant, and it is an argument for statement batching on the forward path.

**The control did its job.** `wire-point` on the non-owner is *not* forwarded —
it reads that node's local replica — and it came out **level with, or slightly
faster than, the owner's** (+6.1% at c=1, +1.2% at c=16, both with sub-1% rep
spread). Had P3's `wire-point` also been slower, whatever slowed it would not
have been forwarding, and the whole P2→P3 story would have collapsed into "node
1 is just slower than node 2". It didn't. The bridge delta is the hop.

One tail observation worth passing upstream: **P3 `bridge-write` at c=1 has a
p50 of 1.55 ms but a p95 of 15.4 ms and a p99 of 25–26 ms** — roughly 10× and
16× its median, while the owner's equivalent cell sits at 2.34 ms p95 / 2.98 ms
p99. The forwarded write path is not merely slower on average, it is
occasionally *much* slower, at a concurrency of one. The forwarded read path
shows no such tail (p99 4.4 ms against a 3.9 ms p50), so this looks specific to
the write/CDC interaction on the owner rather than to the channel itself.

## The divergence probe

Run last, after all measurements, exactly as designed:

```
owner  n2  before: {"count":91463}
owner  n2  after : {"count":91463}
writer n1  after : {"count":91464}
```

A stock `pdo_mysql` INSERT issued on the **non-owner** landed only on the
non-owner. The owner never saw it, and it will be discarded when that replica
next re-bootstraps. This is the documented gap in ephpm#416: the `ephpm_db_*`
bridge forwards, stock `pdo_mysql` does not. Apps on the `ephpm/db-*` drop-ins
are unaffected; an app talking to `127.0.0.1:3306` directly is not.

**Status: fix pending in [ephpm#432](https://github.com/ephpm/ephpm/issues/432),
which is *not* in v0.8.7.** These numbers therefore document the asymmetry as
it currently ships. The `wire-point` cells above are the throughput half of the
same story — the reason the non-owner's wire path is fast is precisely the
reason its writes are wrong.

## Observations for ePHPm

1. **The forward hop costs ~0.25–0.28 ms per statement**, paid per statement
   rather than per request. Batching statements on `sql/<site>` would pay for
   itself on any multi-query request.
2. **P3 forwarded writes have a 10× p50→p95 tail at c=1.** Worth a look
   independently of the mean.
3. **Non-owners begin with an empty local database.** The harness's "open the
   site locally on every node" step returned `no such table: bench` on both
   non-owners (n1, n3) before convergence, then converged. Expected given that
   the stock-wire request is what opens the file and starts the replica driver,
   but it confirms the ordering matters in practice, not just in theory — and
   that a deployment whose apps use only `ephpm_db_*` may never trigger it.
4. **Ownership was decisive and stable.** `cdc_subscribers` = 2 on n2 and 0 on
   n1/n3, agreeing with `elected as SQLite primary` on n2 alone. Exactly one
   owner, on the first check, by two independent observations.

## What this does not answer

Unchanged from the suite's design notes: not production throughput, not
failover (every lane measures a settled cluster with stable membership), and
not a maturity claim. Turso is Beta upstream and per-site clustered mode is
marked **experimental** by ePHPm itself. A cost measurement is not a readiness
verdict.

`S` vs `P1` is still not a measurement of anything — they are different
deployment shapes.
