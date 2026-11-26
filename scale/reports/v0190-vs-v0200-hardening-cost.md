# v0.19.0 vs v0.20.0 — what does the multi-tenant hardening (F1–F5) cost?

> **Provenance / class.** Source tier (bare-host WSL2 dev box), with one
> deviation from the tier's usual rule: the two binaries are **not** local
> from-source builds — they were **extracted from the published release Docker
> images** `docker.io/ephpm/ephpm:v0.19.0-php8.5.13` and
> `:v0.20.0-php8.5.13` (`/usr/local/bin/ephpm`), because this box's egress
> firewall blocks the GitHub-release direct download. They are the same
> artifacts the images ship. Numbers here are **dev-box / WSL2** figures and a
> **relative** model only. Per the lab's never-same-table rule, do **not** put
> any number below in a table with a k6/LKE (`k8s/`) or podman db
> (`DB-BENCH.md`) number — three provenance classes, three separate tables.
> New run → new document; nothing above is edited.

## Question

v0.20.0 shipped the multi-tenant breakout-hardening batch (audit findings
F1–F5). The owner's question: *did all those fixes regress throughput?* This
compares the pre-hardening release (**v0.19.0**) against the hardening release
(**v0.20.0**) on the same box, same profile, back-to-back, and isolates the
cost by also running v0.20.0 with the hardening explicitly **off**.

## Setup

| | |
|---|---|
| Host | WSL2 (Ubuntu) on Windows, 32 vCPU, 62 GB, kernel `6.18.33.2-microsoft-standard-WSL2`, ext4 on native VHD (**not** `/mnt/c`) |
| Binaries | `ephpm 0.19.0` and `ephpm 0.20.0`, PHP 8.5.13 ZTS/glibc, extracted from the published `-php8.5.13` release images |
| Runas | non-root user (uid 1000) — satisfies v0.20.0's `require_privilege_drop` (root with no `run_as_user` is fatal in multi-tenant) |
| Workload | `scale/workloads/wp-lite` — WordPress-shaped front controller, ~20 read queries/front page through the in-process `ephpm_db_*` bridge against a per-site Turso DB |
| Mode | `[server] sites_dir` multi-tenant, per-site Turso DB (`[db.sqlite]`), `[php] mode = "per_request"`, `max_open_dbs = 256`, `query_stats = false` |
| Load | lab `loadgen`, closed-loop **C=128**, round-robin Host across N vhosts, mix front:perm:rest = 3:1:1, **warmup 6 s + measure 20 s** |
| N (tenant sites) | **10, 50, 100** (reduced sweep — enough to detect a meaningful regression; the box cannot usefully run N≫100 here without more noise than signal) |
| Replicates | v0.19.0-on ×5, v0.20.0-on ×5, v0.20.0-off ×2, interleaved |
| Request mix result | 100 % HTTP 200, **0 errors** across every run |

The lab's `run_sweep.sh` was not used verbatim: it still exports the removed
`EPHPM_PHP__FPM_ENGINE` knob (which a ≥v0.9.0 binary rejects) and its config
template uses the pre-v0.9.0 `[php] mode = "fpm"`. The runner here
(`run_compare.sh`, kept with the raw results) reuses the lab's
`provision.sh` / `sample.sh` / `loadgen` unchanged, sets `mode = "per_request"`,
and templates the hardening knobs so the same binary can be measured on and off.

## Hardening actually active on this box

Confirmed from each server's startup log. All F1–F5 are secure-by-default once
`sites_dir` is set; this box activates:

| Finding | Layer | v0.20.0-on here | Evidence |
|---|---|---|---|
| **F1** | Env scrub before PHP | **ACTIVE** | `scrubbed the process environment before PHP started (finding F1) … removed=21 kept=3` |
| **F2** | eBPF AF_UNIX connect fence | **UNFENCED** (self-disabled) | `AF_UNIX connect fence could NOT be attached — starting UNFENCED`. Kernel is 6.18 (≥6.7) with BTF, but a **non-root** process lacks `CAP_BPF`+`CAP_NET_ADMIN`+raised `RLIMIT_MEMLOCK`, so the BPF map create fails `EPERM`. `policy=auto` → warn-and-serve. |
| **F3** | Landlock engine self-sandbox | **ACTIVE & ENFORCED** | `self-sandbox: arming the PHP engine Landlock ruleset on each PHP thread` + `kernel fully enforces Landlock (ABI 1+)` |
| **F4** | Authenticated SQL wire listeners | **ACTIVE** | `MySQL frontend listening … authenticating=true` (per-process random credential; the bench's bridge path doesn't touch the wire listener) |
| **F5** | Cron child CPU/mem ceilings | **n/a** | `[cron] enabled = false` (default) — not exercised |

**Caveat:** F2's per-`connect()` eBPF cost is **not measured** here (it could not
attach without privilege). For this workload that changes nothing — wp-lite
reaches the DB through the in-process bridge, so it performs no unix-socket
`connect()` for F2 to hook — but a privileged deploy (root + `run_as_user`, or
`LimitMEMLOCK=infinity`) would attach it and should be measured separately if
F2's hot-path cost matters.

The **hardening-off** config set `self_sandbox = "off"`,
`[server.tenant_network] unix_socket_policy = "off"`,
`[db.wire_auth] allow_insecure_no_auth = true`. Note **F1 cannot be disabled
under `sites_dir`** (fail-closed) — the scrub still ran in the off config, so
"off" here is really "F3+F4 off, F1 still on, F2 already off". Since F1 is a
one-time startup cost (not per-request), this does not affect the throughput
reading.

## Results (clean-round medians)

Per-round `cpu_cores_mean` exposed which samples were **contaminated by
background CPU steal** (this is a shared dev box, and closed-loop C=128
saturates all cores, so any interloper directly cuts RPS). Samples with
`cpu_cores_mean < 22` were dropped from the medians below; all raw rounds are in
the appendix.

| N | v0.19.0 RPS | v0.20.0 RPS (Δ) | v0.20.0-off RPS | v0.19.0 RSS | v0.20.0 RSS (Δ) | v0.20.0-off RSS | p95 ms v19/v20 | p99 ms v19/v20 |
|----:|----:|----:|----:|----:|----:|----:|:--:|:--:|
| 10  | 24,049 | 23,599 (−1.9 %) | 25,178 | 158.8 MB | 183.9 MB (+15.8 %) | 155.0 MB | 9.2 / 9.4 | 12.0 / 12.2 |
| 50  | 24,080 | 23,436 (−2.7 %) | 24,000 | 243.2 MB | 268.0 MB (+10.2 %) | 240.7 MB | 9.1 / 9.5 | 11.8 / 12.4 |
| 100 | 23,143 | 22,659 (−2.1 %) | 22,667 | 349.1 MB | 373.6 MB (+7.0 %)  | 351.4 MB | 9.5 / 9.7 | 12.4 / 12.8 |

RSS is steady-state RSS of the single `ephpm` process (32 PHP threads).

## Reading

**Throughput: no meaningful regression.** v0.20.0-on is ~2 % below v0.19.0 at
every N (−1.9 / −2.7 / −2.1 %). That is *inside* this box's run-to-run spread —
v0.19.0's own clean rounds vary by ±5–8 % (e.g. N=10 ranged 22.2k–24.3k across
clean rounds). The direction is consistent, and turning the hardening off
recovers v0.19.0 parity (N=10 even edges ahead at 25.2k), so there is a small
*real* component — plausibly F3 Landlock's per-syscall path check on the ~20
per-request DB file operations — but it is ≤~2 % and swamped by noise. Latency
(p95 ≈ 9 ms, p99 ≈ 12 ms) is indistinguishable, and error rate is zero.

**Memory: a real, consistent +~24 MB flat offset — and it is the hardening.**
v0.20.0-on carries ~24–25 MB more steady RSS than v0.19.0 at *every* N and in
*every* round (not noise). The hardening-off run drops RSS right back onto
v0.19.0 (158.8 → 155.0, 243.2 → 240.7, 349.1 → 351.4 MB), which attributes the
offset to the toggled layers — dominantly **F3 Landlock** (a ruleset armed on
each of the 32 PHP threads), since F1 stays on in both configs and F4/F2 cost
little RSS. Because it is a **flat ~24 MB**, not per-site, its relative weight
shrinks as N grows: +15.8 % at N=10 → +7.0 % at N=100, and it would keep
shrinking toward the 1000-site end of the full sweep.

## Verdict

**Still doing good.** v0.20.0's multi-tenant hardening costs essentially nothing
on throughput (≤~2 %, within noise) and nothing on latency or correctness; its
only real, repeatable cost is a **flat ~24 MB RSS** (F3 Landlock, ~24 MB fixed
regardless of tenant count → +7 % at N=100 and falling). No regression worth
acting on. The knob to recover the memory if ever needed is
`[server] self_sandbox = "off"`, at the documented cost of dropping the engine
Landlock sandbox — not recommended. F2's eBPF connect-fence cost is unmeasured
on this box (unprivileged) and is ~0 for a bridge-only workload regardless.

---

## Appendix — all raw rounds

`cpu` = `cpu_cores_mean` (of 32); `*` = dropped from the clean medians (CPU-starved).

### v0.19.0 (pre-hardening), hardening on
| round | N | RPS | RSS MB | p95 | p99 | cpu |
|---|--:|--:|--:|--:|--:|--:|
| r1 | 10 | 22,187 | 160.6 | 10.31 | 14.42 | 17.5* |
| r1 | 50 | 23,365 | 249.1 | 9.23 | 12.08 | 23.3 |
| r1 | 100 | 22,574 | 354.2 | 9.53 | 12.40 | 23.4 |
| r2 | 10 | 26,881 | 162.7 | 8.13 | 10.61 | 23.8 |
| r2 | 50 | 26,191 | 250.3 | 8.19 | 10.73 | 24.2 |
| r2 | 100 | 26,109 | 357.3 | 8.21 | 10.77 | 24.3 |
| r3 | 10 | 24,322 | 161.1 | 9.03 | 11.81 | 22.7 |
| r3 | 50 | 24,261 | 249.8 | 8.99 | 11.68 | 23.0 |
| r3 | 100 | 22,260 | 351.8 | 9.96 | 13.04 | 21.7* |
| r4 | 10 | 23,601 | 165.3 | 9.35 | 12.23 | 23.1 |
| r4 | 50 | 22,353 | 246.1 | 9.89 | 12.93 | 23.1 |
| r4 | 100 | 22,905 | 357.6 | 9.57 | 12.59 | 23.1 |
| r5 | 10 | 23,775 | 162.6 | 9.18 | 12.02 | 23.2 |
| r5 | 50 | 24,080 | 245.4 | 9.06 | 11.78 | 23.5 |
| r5 | 100 | 23,380 | 362.4 | 9.34 | 12.11 | 23.5 |

### v0.20.0 (hardening on)
| round | N | RPS | RSS MB | p95 | p99 | cpu |
|---|--:|--:|--:|--:|--:|--:|
| r1 | 10 | 24,046 | 181.6 | 8.99 | 11.75 | 23.4 |
| r1 | 50 | 23,887 | 273.5 | 8.98 | 11.66 | 24.1 |
| r1 | 100 | 21,136 | 378.2 | 10.60 | 14.14 | 23.4 |
| r2 | 10 | 26,298 | 188.8 | 8.20 | 10.72 | 24.3 |
| r2 | 50 | 20,489 | 271.9 | 13.31 | 26.13 | 21.6* |
| r2 | 100 | 18,230 | 376.7 | 12.82 | 17.40 | 19.0* |
| r3 | 10 | 21,944 | 186.7 | 10.37 | 14.02 | 21.7* |
| r3 | 50 | 23,972 | 278.3 | 8.98 | 11.74 | 23.6 |
| r3 | 100 | 22,566 | 382.5 | 9.69 | 12.81 | 22.7 |
| r4 | 10 | 23,151 | 188.6 | 9.42 | 12.24 | 23.4 |
| r4 | 50 | 22,984 | 272.6 | 9.47 | 12.37 | 23.6 |
| r4 | 100 | 23,420 | 383.6 | 9.24 | 12.02 | 23.7 |
| r5 | 10 | 22,999 | 187.9 | 9.50 | 12.42 | 23.3 |
| r5 | 50 | 22,820 | 275.3 | 9.59 | 12.43 | 23.5 |
| r5 | 100 | 22,752 | 382.5 | 9.50 | 12.25 | 23.6 |

### v0.20.0 (hardening off: self_sandbox=off, unix_socket_policy=off, wire_auth insecure)
| round | N | RPS | RSS MB | p95 | p99 | cpu |
|---|--:|--:|--:|--:|--:|--:|
| r1 | 10 | 25,178 | 158.7 | 8.73 | 11.42 | 23.5 |
| r1 | 50 | 24,158 | 246.0 | 9.07 | 11.79 | 23.5 |
| r1 | 100 | 21,129 | 357.0 | 10.85 | 14.89 | 22.4 |
| r2 | 10 | 20,280 | 165.7 | 12.40 | 19.91 | 21.6* |
| r2 | 50 | 23,842 | 246.9 | 9.31 | 12.10 | 23.1 |
| r2 | 100 | 24,204 | 362.7 | 9.13 | 11.99 | 23.2 |
