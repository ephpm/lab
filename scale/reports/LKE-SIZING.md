# Sizing ePHPm for multi-tenant WordPress

Two very different questions hide under "how do I size this," and they have
opposite answers. Pick the section that matches your load:

- **[PR-preview / low-traffic](#a-pr-preview--low-traffic-the-common-case)** —
  many sites, little concurrent traffic. **Disk-bound. One small node.**
- **[Production hosting](#b-production-multi-tenant-hosting-high-sustained-traffic)** —
  tenants under steady real traffic. **CPU-bound. Scale out.**

All figures come from the scaling benchmark (`scale/reports/REPORT.md`) plus a direct
disk measurement of 250 real seeded WordPress databases (below).

> **Re-verified 2026-08-15.** The original benchmark harness handicapped the
> server ~3.8× on light workloads (DrvFs working directory — see the erratum in
> `REPORT.md`). The re-based run (`BEFORE-AFTER.md`, fixed harness, current
> `main`) **confirms the sizing constant this sheet is built on**: real-WP
> front pages measure ~266–272 RPS at ~28 of 32 cores → **~9.5–9.7 req/s per
> core (~105 ms CPU/request)** — inside the ~9–10 band used below, so none of
> the worked plans change. What *did* change: the light-workload
> single-instance ceiling is ~15–19k RPS (not ~4.7k), so the "registry mutex
> caps every instance" caveat is gone; on real-WP CPU remains the wall.

---

## A. PR-preview / low-traffic (the common case)

**If you're serving a handful of requests per second across many mostly-idle
sites, one small node runs the whole thing. Sizing is about disk, not compute.**

### Why compute is a non-issue

Real WordPress costs **~105 ms CPU per front-page render** (measured; re-verified
on the corrected harness 2026-08-15). So:

| Peak traffic (whole service) | CPU load | Node |
|---|---|---|
| **5 req/s** | ~0.54 vCPU | any 1-vCPU node, ~half-idle |
| 10 req/s | ~1.1 vCPU | 1–2 vCPU |
| 25 req/s | ~2.7 vCPU | a 4-vCPU node |

The "~9–10 req/s per core" ceiling from the benchmark is **WordPress being
heavy**, not ePHPm overhead — the multi-tenancy machinery is negligible next to
WP's own PHP cost. At 5 req/s you're at ~5% of a single core's WP capacity.

### Why RAM is a non-issue

The benchmark's "0.67 GB baseline" was **not a floor** — ePHPm's autotune
(`derive_tuning` in `crates/ephpm-config/src/lib.rs`) sizes to the box:

- `opcache.memory_consumption` = **18% of RAM, clamped [64, 512] MB** → the
  bench box (62 GB) hit the 512 MB ceiling; a 1 GB Nanode gets ~180 MB (and only
  ~50–100 MB is *resident*, since a shared WP docroot fills opcache once).
- workers = `clamp(vCPUs, 2, 32)` → 2 on a Nanode, not 8.
- per-request `memory_limit` = `(RAM − 64 MB − opcache) / workers`.

So on a **1 GB Nanode** the runtime baseline is **~250–350 MB**, leaving room for
the open-DB LRU (~2.2 MB × `max_open_dbs`). A small cap (`max_open_dbs = 32–64`)
covers the few sites hot at any instant.

### Disk is the only thing that scales with site count — and it's tiny

**Measured** (250 real `wp core install` WordPress DBs, this bench):

| Per fresh WP site | Size |
|---|---|
| **Checkpointed** (WAL folded, `integrity_check` = ok) | **~124 KB** |
| With an uncheckpointed install WAL (`.db` + `-wal`) | ~660 KB |

So a fresh WordPress database is **~0.12–0.7 MB**, not the multi-MB I'd first
guessed. That puts real numbers on hosting:

| Sites | Disk (checkpointed) | Disk (worst-case, all carrying WALs) |
|--:|--:|--:|
| 1,000 | ~120 MB | ~0.7 GB |
| **5,000** | **~0.6 GB** | **~3.3 GB** |
| 10,000 | ~1.2 GB | ~6.5 GB |

### Verdict for previews

**5,000 preview sites at ~5 req/s → one Linode Nanode (1 vCPU / 1 GB / 25 GB).**

- CPU: ~0.5 core used. Enormous headroom.
- RAM: ~300–450 MB (autotuned baseline + a small LRU). Fits 1 GB.
- Disk: ~0.6–3.3 GB for 5,000 DBs. Fits 25 GB with room; attach Block Storage
  if you scale past ~15k sites.
- fds: `2 × max_open_dbs + ~140` → ~270 at cap 64. Trivial.

Bump to a **2 GB shared / 2 vCPU** node only if you want comfort headroom or
plan to grow well past 5,000 sites — not because 5,000 needs it.

### The one real risk: a single preview getting hammered

Compute is fine *in aggregate*, but one 1-vCPU node renders only ~10 full WP
pages/sec. A single preview that goes viral or gets crawled can eat the whole
box. Fix it with a **per-site request cap**, not a bigger node — cap each
preview to a few req/s so no one tenant starves the others. (Preview-mode rate
levers are the follow-up feature; today the global `per_ip_rate` /
`max_connections` knobs are the closest existing controls.)

### Preview caveats (honest)

- The ~124 KB figure is a **fresh** install (default 1 post / 1 page / 1
  comment). A preview carrying a real theme, plugins, and content grows to a few
  MB — still tiny, but size disk with headroom if previews aren't near-fresh.
- opcache SHM (~180 MB on a Nanode) fills once for a **shared** WP docroot. If
  every preview ships *different* code, opcache can thrash — give it more RAM or
  accept recompiles.

---

## B. Production multi-tenant hosting (high sustained traffic)

**This is the section my original sheet was really about — skip it unless you're
running tenants under steady real load.** Here real WordPress is **CPU-bound**
and you scale out.

### The numbers that drive it

| Quantity | Measured value | Source |
|---|---|---|
| CPU per real-WP front page | **~9–10 req/s per core** (~105 ms CPU/req) | wp-real N=10–250: flat ~243–253 RPS @ ~27 cores; re-confirmed on the fixed harness at ~266–272 RPS @ ~28 cores (BEFORE-AFTER.md) |
| RAM per open site | 2.2 MB/open-site over the autotuned baseline (LRU-bounded) | wp-lite cap=4096 fit |
| Disk per site | ~0.12–0.7 MB (measured, above) | 250 real WP DBs |
| fds per open site | ~2 (db + `-wal`) + ~140 base | wp-lite fit |

Single-instance throughput ceiling on a 32-core box: **~250–300 real-WP RPS**
per pod — PHP saturates the cores; throughput scales with cores at ~9.5–9.7
req/s/core. (An earlier caveat here blamed a registry-mutex cap "regardless of
core count" — that was a harness artifact, withdrawn; see `REPORT.md` erratum.)
**To grow past one pod's cores, scale out with more pods.**

### Sizing recipe

```
cores_needed  = ceil(peak_realWP_RPS / 9.5)
RAM_per_pod   = autotuned_baseline (≈0.3–0.7 GB, scales with node RAM)
              + 2.2 MB * min(sites_per_pod, max_open_dbs)
              + working_headroom (in-flight PHP; budget a couple GB)
disk_per_pod  = ~0.7 MB * sites_per_pod   (with WAL headroom)
fd_per_pod    = 2 * max_open_dbs + 200    -> set RLIMIT_NOFILE above this
max_open_dbs >= simultaneously-active sites on that pod   # else ~3.6x RPS penalty (LRU churn)
```

### Worked LKE plans (Dedicated CPU — confirm current specs/price with Linode)

Use **Dedicated CPU** plans (a CPU-bound PHP workload gets throttled on shared
vCPU). 3 nodes, N+1 (2 nodes carry peak). `req/s` = real-WP front-page.

| Scenario | Sites | Peak RPS | Per-node plan | vCPU/RAM | 2-node usable RPS |
|---|--:|--:|---|---|--:|
| Small | ≤ 500 | ~150 | Dedicated 16 GB | 8 vCPU / 16 GB | ~150 |
| Medium | ≤ 2,000 | ~300 | Dedicated 32 GB | 16 vCPU / 32 GB | ~300 |
| Large | ≤ 5,000 | ~450 | Dedicated 64 GB | 32 vCPU / 64 GB | ~500–600 (per-pod ceiling) |

RAM is never the binding constraint here — even the Large row's site footprint
is a few GB of 64. You buy the plan for **cores**. To exceed ~500 RPS, go
**wider** (more pods), not bigger — the ~250–300 RPS ceiling is per-instance.

### Topology constraint (applies whenever you run more than one pod)

Turso opens each `<site>.db` from **exactly one process** — no multiprocess, no
cross-process VACUUM. So:

1. **A site lives on exactly one pod.** Requests must be **affinity-routed** to
   the pod that owns it (ingress `Host`-hash, or the `ephpm-cluster` ownership
   hash).
2. **Shard, don't replicate**, to scale sites — each pod owns a disjoint slice.
3. **HA**, pick one:
   - **(a) Block-storage PVC + reschedule** (simple, single-writer safe): site
     `.db` on a Linode Block Storage RWO volume; a dead pod's sites are down
     until K8s reschedules and re-opens (~30–90 s). StatefulSet so the owning
     pod moves with its volume.
   - **(b) Clustered Turso CDC** (`[cluster]`, **experimental / not
     Windows-validated**): a replica tails the primary's CDC stream and can be
     promoted. Faster failover, more moving parts. Only if sub-reschedule
     failover matters.

---

## Caveats (both sections)

- All throughput/RAM figures are WSL2 dev-box measurements; the **shape** and the
  **per-core / per-site coefficients** transfer, absolute RPS will differ on LKE
  metal — re-measure one pod on the target plan to calibrate. Disk per-site
  (~0.12–0.7 MB) is a direct file measurement and travels as-is.
- Cross-pod ownership routing (the one-file-one-process shard map) is **not yet
  turnkey** — today it's ingress `Host`-affinity or an extension of
  `ephpm-cluster`'s ownership hash. This is the gap between "sized" and
  "shipped" for multi-pod. Single-node (the preview case) needs none of it.
