# kv-micro — per-op cost of ePHPm's KV store

Why this exists: ePHPm's `guides/kv-from-php.md` publishes hard numbers —
"~100 ns per op, zero serialization" for the `ephpm_kv_*` SAPI path and
"~10–100 µs per op" for the RESP listener — and until this suite no harness
anywhere had measured either. This is the harness.

Two lanes, same process, same store:

| Lane | Path | Unit | How it's timed |
| --- | --- | --- | --- |
| `sapi` | `ephpm_kv_set/get/incr` in-process | ns/op | `hrtime()` around a tight loop inside one request (`fixtures/kv_sapi.php`) — a **bare-loop** number by construction, same caveat as RUNTIMES-BENCH's musl/ZTS loops |
| `resp` | RESP2 `SET`/`GET` over TCP to the embedded listener | µs/op | strict ping-pong round-trips from a raw PHP socket (`fixtures/kv_resp.php`); client-library (Predis/phpredis) numbers sit **above** this floor |

Value sizes 64 B / 4 KB / 64 KB, three interleaved reps, medians reported.
Both fixtures gate on full readback (value equality, incr count) so a fused or
short-circuited loop cannot masquerade as a fast one.

This is a **source-tier** suite (see [`scale/README.md`](../scale/README.md)):
it drives a from-source binary as a bare process, because the SAPI effect is
nanoseconds wide and a container adds only noise. Publish nothing from it
without the binary rev + sha256 the script prints.

```bash
BIN=/path/to/ephpm bash kv/bench-kv.sh
# knobs: RUN= (native fs, never /mnt/*), SIZES, SAPI_OPS, RESP_OPS, REPS
```

Recorded results: [`../docs/kv-micro-v070.md`](../docs/kv-micro-v070.md).
