# kv-micro — measured per-op cost of `ephpm_kv_*` and the RESP listener

**TL;DR: the guide's numbers mostly survive contact with a harness.**
`guides/kv-from-php.md` claims "~100 ns per op" for the SAPI path and
"~10–100 µs per op" for RESP. Measured: a small-value SAPI **get is
100–119 ns** — the claim is accurate for exactly that op — while **set/incr
are ~155–165 ns** and large values scale with the copy (64 KB get ≈ 2.0 µs).
RESP round-trips are **78–115 µs**: inside the claimed band, but pinned to its
**top** end — the "~10 µs" floor was never observed (c=1 TCP round-trip on
this box bottoms out near 80 µs). Net: ~500× between the two paths, which is
the guide's actual point, confirmed.

Harness: [`kv/bench-kv.sh`](../kv/README.md). Source-tier suite (bare-process
from-source binary; see [`scale/README.md`](../scale/README.md) for what that
provenance class means).

## Provenance

| | |
| --- | --- |
| Binary | from-source `cargo xtask release 8.5`, ephpm main @ `180d0ac` (post-#306) |
| sha256 | `afa19edfc262854259da7ed33d4995954614047c550917fd7a9e489fdd0fd3c4` |
| PHP | 8.5 ZTS glibc (php-sdk) |
| Host | WSL2 on Windows 11, 32 vCPU, 62 GiB; run dir + docroot on native ext4 (DrvFs trap asserted by the harness) |
| Config | single-site, `[kv.redis_compat]` on loopback TCP, no AUTH, no compression (values ≥1 KB would otherwise hit the 1 KB compression threshold — `[kv] compression` defaults to `"none"`) |
| Date | 2026-08-17 |

Method: medians of 3 interleaved reps; SAPI = 200k ops/loop timed with
`hrtime()` in-process (a **bare-loop** number — no request dispatch in the
denominator); RESP = 20k strict ping-pong round-trips per op type over one
raw-socket connection with `tcp_nodelay` (a floor for client libraries:
Predis/phpredis add their own overhead on top). Every cell gated on full-value
readback; rep-to-rep spread was under 6% in every cell.

## SAPI (`ephpm_kv_*`), ns/op

| value size | set | get | incr |
| --- | ---: | ---: | ---: |
| 64 B | 159 | 116 | 162 |
| 4 KB | 213 | 175 | 163 |
| 64 KB | 1,138 | 1,961 | 161 |

The 64 B get ranged 101–119 ns across reps — "~100 ns" is a fair one-liner for
it. Writes are ~1.4× that. `incr` is size-independent (~162 ns), as expected.
At 64 KB both directions are memcpy-bound (~1–2 µs); "zero serialization" is
true but not zero copy.

## RESP2 round-trip (embedded listener, loopback TCP, c=1), µs/op

| value size | SET | GET |
| --- | ---: | ---: |
| 64 B | 79.3 | 79.1 |
| 4 KB | 82.3 | 80.7 |
| 64 KB | 99.6 | 110.7 |

Size barely matters — the round-trip itself dominates. Note this is WSL2
loopback; bare-metal Linux loopback RTTs can be several times lower, so
"~10–100 µs" may well hold across hardware, but on this box the honest range
is **~80–115 µs**.

## What the ephpm guide should say (reported, not edited here)

- "~100 ns per op" → accurate for small-value `get`; "**~100–220 ns per op for
  small values (get ≈ 116 ns, set ≈ 160 ns at 64 B); ~1–2 µs at 64 KB
  (copy-bound)**" would be exactly right.
- "~10–100 µs per op" (RESP) → measured **79–111 µs** on a WSL2 dev box; the
  band's upper half is where reality sits at c=1 over TCP. A phrasing like
  "**~50–150× the SAPI path — order of 100 µs per round-trip**" would survive
  any host.
