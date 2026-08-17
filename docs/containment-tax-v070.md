# containment-tax — what does `[php] crash_containment` cost?

**TL;DR: the happy path is free; the leak is real, bounded, and now has a
number.** `crash_containment = true` vs `false` differs by **−0.4% to +0.8%**
across every cell (hello/db × c=1/c=32, medians of 3 interleaved reps) —
inside rep-to-rep noise, so "performance-free on the happy path" is verified
at this measurement's resolution. Under a 500-crash storm: **500/500 crashes
contained** (each answered HTTP 500, `ephpm_fpm_pool_contained_crashes_total`
delta exactly 500, log shows exactly 500 poison + 500 retire + 500 respawn
events), the process survived, concurrent traffic saw **0 errors and p99
0.86 ms**, and RSS grew **~857 KB per contained crash** — the bounded leak,
quantified: a small node budgeting for containment should assume ~0.9 MB per
crash of unreclaimed RSS (upstream's own code comment reports the growth
flattening after ~1000 crashes; not re-tested beyond 500 here).

## Why

ePHPm #302 shipped stack-overflow crash containment for the pool engine: a PHP
C-stack overflow gets a 500 and retires the poisoned pool thread instead of
killing the whole (multi-tenant) process. The docs describe the cost
qualitatively — a bounded per-crash leak (the poisoned thread's abandoned PHP
context), and "no happy-path cost" — but nothing had quantified either. This
suite pins both:

- **happy** — A/B of `crash_containment = false` vs `true` on
  `fpm_engine = "pool"`, fixtures {hello.php, bridge db.php} × {c=1, c=32},
  fresh server per run, interleaved A/B run order, medians of 3 — the
  "containment is performance-free on the happy path" claim.
- **storm** — 500 sequential contained crashes (the ephpm
  `tests/docroot/stack_overflow.php` fixture: a deep object-destructor cascade
  that SIGSEGVs the executing thread) with concurrent hello traffic —
  per-crash wall cost, `ephpm_fpm_pool_contained_crashes_total` accounting,
  RSS growth per crash (the bounded leak, quantified), thread retirement, and
  whether concurrent traffic's tail survives.

Harness: [`containment/bench-containment.sh`](../containment/bench-containment.sh).
Source-tier suite (see [`scale/README.md`](../scale/README.md)).

### Provenance

| | |
| --- | --- |
| Binary | from-source `cargo xtask release 8.5`, ephpm main @ `180d0ac` (post-#306) |
| sha256 | `afa19edfc262854259da7ed33d4995954614047c550917fd7a9e489fdd0fd3c4` |
| PHP | 8.5 ZTS glibc (php-sdk) |
| Host | WSL2 on Windows 11, 32 vCPU, 62 GiB; run dir on native ext4 (DrvFs trap asserted) |
| Date | 2026-08-17 |

## Happy-path A/B

Medians of 3 reps per lane, fresh server per run, interleaved run order
(A B B A A B), every cell 100% HTTP 200 (closed-loop, zero errors).

| fixture | conc | off (RPS) | on (RPS) | Δ RPS | off p99 ms | on p99 ms |
| --- | --: | --: | --: | --: | --: | --: |
| hello.php | 1 | 2,980 | 2,972 | −0.30% | 0.418 | 0.420 |
| hello.php | 32 | 27,797 | 28,028 | +0.83% | 5.15 | 5.11 |
| db.php (bridge, 10 selects) | 1 | 2,601 | 2,591 | −0.38% | 0.484 | 0.491 |
| db.php (bridge, 10 selects) | 32 | 27,613 | 27,754 | +0.51% | 4.87 | 4.85 |

The sign of the delta flips with concurrency and the magnitudes sit well
inside the ~4% rep-to-rep spread: **no resolved difference**. This is
consistent with the mechanism — the guard is an arm/disarm around PHP
execution, not per-opcode instrumentation.

## Crash storm

500 sequential requests to `stack_overflow.php?depth=200000` (the fixture
copied from ephpm `tests/docroot/` — a destructor-cascade C-stack overflow
that SIGSEGVs the executing pool thread), with concurrent hello traffic at
c=8 throughout.

| | |
| --- | --- |
| Contained | **500 / 500** — every crash request answered HTTP 500 (status histogram: 500 × `500`, 0 transport errors) |
| Counter | `ephpm_fpm_pool_contained_crashes_total`: 0 → **500** (exact) |
| Log accounting | exactly 500 × "thread poisoned", 500 × "thread retired", 500 × respawn-backoff — one retire+respawn per crash, no over- or under-count |
| Survived | yes (and clean shutdown afterwards) |
| Wall cost | 12.4 s / 500 = **~25 ms per crash** end-to-end at c=1 (includes the fixture's 200k-node graph build; the containment machinery itself — signal, unwind, retire, respawn — is a fraction of that) |
| RSS | 105.9 MB → 534.2 MB = **856.6 KB per contained crash** (VmHWM 535.3 MB — no hidden spike) |
| Concurrent traffic | 3.52 M hello requests during/around the storm window: **0 errors**, p50 0.38 ms, **p99 0.86 ms**, max 22.5 ms |
| Recovery | post-storm hello c=8: 19,359 RPS, p99 0.89 ms — indistinguishable from pre-storm |

Two readings of the leak number: it is genuinely bounded per crash (nothing
grows without a crash happening), and it is genuinely a leak — 500 crashes
cost ~0.43 GB that only a restart reclaims. On the LKE-SIZING node shapes
(1–2 GB), a crash-storm of a few hundred contained faults is survivable but
should page someone; the counter exists precisely so it can.

## Caveats

Bare-loop, dev-box numbers; single host. The A/B differences of interest are
percent-level, so anything under the rep-to-rep spread is reported as "no
resolved difference", per the lab's convention.
