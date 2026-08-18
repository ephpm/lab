# Five-Way PHP Runtime Comparison

This benchmark compares five PHP runtimes (six entries - ePHPm is measured
in both its drop-in fpm mode and its persistent worker mode) under identical
resource constraints
(0.25 CPU / 320 Mi memory per pod) on a kind cluster with fixtures served from
ConfigMaps. It addresses the "Octane/Swoole/RoadRunner/ePHPm comparison" item
from the ePHPm-lab report's next-tests list.

## Runtimes

| Runtime | Image | PHP |
|---------|-------|-----|
| ePHPm v0.7.0 | `ephpm/ephpm:v0.7.0-php8.4` | 8.4 ZTS, glibc |
| nginx + php-fpm | `nginx:1.27-alpine` + `php:8.4-fpm` (Debian) | 8.4 NTS, glibc |
| FrankenPHP | `dunglas/frankenphp:latest` | 8.5 ZTS, glibc (image default; see caveat) |
| Swoole | `phpswoole/swoole:php8.4` | 8.4 NTS, glibc |
| RoadRunner | `php:8.4-cli-alpine` + `ghcr.io/roadrunner-server/roadrunner:2024` | 8.4 NTS, musl (see caveat) |
| ePHPm v0.7.0 worker mode | `ephpm/ephpm:v0.7.0-php8.4` (`[php] mode = "worker"`) | 8.4 ZTS, glibc |

The manifests pin **v0.7.0**, which carries the whole v0.4.x line
(v0.4.1: 101x db.php latency fix + SHA-NI; v0.4.2: HTTP `TCP_NODELAY`
-13% p99, worker dispatch fastpath, mimalloc/LTO), v0.5.0's
**resource-aware autotuning**, the v0.6.x database-path work
(pool fixes, the `ephpm_db_*` bridge — see `DB-BENCH.md`), and v0.7.0's
**engine swap**: the embedded database is now Turso only, the rusqlite
engine and the sqld sidecar are gone.

> **The v0.7.0 pin bump crosses an engine change.** Nothing in *this*
> file's Class A / Class B fixtures (`hello`, `cpu`) touches the
> database, so those lanes are a like-for-like v0.6.3-vs-v0.7.0
> comparison. The `db.php` lane is **not**: on v0.6.3 it ran the
> genuine-SQLite C engine and on v0.7.0 it runs Turso, so a delta there
> is an engine delta, not a runtime delta. Label it that way or do not
> report it.
For the v0.4.0-vs-v0.4.1 before/after,
see [docs/ephpm-0.4.1-retest.md](docs/ephpm-0.4.1-retest.md). The
`db.php` lane (10 PDO queries on ePHPm's in-process SQLite) remains
the reproduction path for the database-latency number.

> **Autotuning changes the baseline (v0.5.0+).** In serve mode ePHPm
> now reads the pod's cgroup CPU/memory limits at boot and derives an
> opcache / memory_limit / realpath / assertions profile, including
> `opcache.validate_timestamps=0` — exactly the class of hand-tuning
> the php-fpm lane gets via its ini overlay, applied automatically.
> Every ePHPm lane in this suite therefore runs a *different effective
> PHP config* on v0.5.0 than the same manifest produced on v0.4.x, so
> numbers recorded before/after the bump are **not directly
> comparable**. When re-recording, capture each lane's
> `autotune (serve): ...` startup log line as evidence of the profile
> that actually ran. Include-heavy workloads (Krayin, WordPress) are
> expected to benefit most; tiny-script lanes (`hello`) should be
> unchanged. Operator config still overrides any derived value.

## Retired: Turso engine db lane (`replicas: 0` on the v0.7.0 pin)

`k8s/runtimes-bench.yaml` still carries the `bench-ephpm-turso`
Deployment + Service, now scaled to **`replicas: 0`**. It existed to A/B
the `[db.sqlite] engine = "turso"` knob against the genuine-SQLite C
engine that was the v0.6.x default, and the v0.6.3 pin is the last one on
which that A/B means anything. v0.7.0 removed the C engine — `"turso"` is
the only value the knob accepts and also the default — so this Deployment
and `bench-ephpm` would now select the **same engine**, leaving the
comparison with no control arm. It is kept scaled to zero rather than
deleted so the manifest records what the lane was; do not scale it back
up and report it as an engine comparison, because it would be
`bench-ephpm` wearing a second label.

The question it was built to answer (Phase 1 microbenchmarks at the
litewire seam measured 28x point-SELECT and 4x concurrent-writer
throughput vs the C engine — how much survives the full mysqlnd →
MySQL-wire → engine path?) is now answered only in the historical
v0.6.3-pinned `engines` suite in [DB-BENCH.md](DB-BENCH.md). See the
"Relationship to ePHPm v0.7.0" section in the README.

## Class A vs Class B

These runtimes fall into two categories that must NOT be compared in the same table.

**Class A — Drop-in runtimes.** Serve `.php` files from a docroot on each
request, just like Apache or nginx. No application changes needed.

- ePHPm
- nginx + php-fpm (opcache + JIT enabled)
- FrankenPHP (classic mode, not worker mode)

Benchmark paths: `/hello.php`, `/cpu.php`

**Class B — Worker/persistent-process runtimes.** Require custom server or
worker bootstrap code. The application runs in a long-lived process and handles
requests via an event loop or message-passing protocol. Not drop-in replacements.

- Swoole (`Swoole\Http\Server`, ~20 lines of bootstrap)
- RoadRunner (PSR-7 worker loop via spiral/roadrunner-http, ~35 lines)
- ePHPm worker mode (raw `\Ephpm\Worker\take_request()` loop, ~50 lines, no
  Composer dependencies - the same binary as the Class A entry, different
  `[php] mode`)

Benchmark paths: `/hello`, `/cpu`

## Fixtures

- **hello**: tiny JSON echo (`{"ok":true,"t":<microtime>}`)
- **cpu**: 5000-round sha256 chain (`{"h":"<hex16>"}`)

## Local Reference Numbers

Measured on one developer machine with podman, 0.25 CPU / 320 Mi **total per
stack** (the nginx + php-fpm pair shares a single pod-level cgroup), `hey`
keep-alive, best of 2 x 30 s runs, and every reported cell verified to be
100% HTTP 200. These numbers exist so you can sanity-check your cluster
results; they are not claims about production throughput.

### Class A

| Runtime | hello c=1 avg | hello c=16 avg | hello c=16 RPS | cpu c=16 RPS |
|---------|:---:|:---:|:---:|:---:|
| ePHPm v0.4.0 php8.4 (ZTS glibc) | 2.0 ms | 24.7 ms | 648 | 79 |
| nginx + php-fpm 8.4 Debian (opcache+JIT, shared cgroup) | 2.2 ms | 28.0 ms | 572 | 151 |
| FrankenPHP classic (php 8.5 ZTS) | 6.1 ms | 59.4 ms | 269 | 125 |

### Class B

| Runtime | hello c=1 avg | hello c=16 avg | hello c=16 RPS | cpu c=16 RPS |
|---------|:---:|:---:|:---:|:---:|
| Swoole php8.4 (1 worker) | 0.4 ms | 2.4 ms | 6539 | 206 |
| RoadRunner php8.4 musl (1 worker) | 2.1 ms | 29.1 ms | 549 | 68 |
| ePHPm worker mode (1 worker, tuned) | 0.9 ms | 7.7 ms | 2078 | 90 |

## Caveats

- **libc matters as much as the runtime.** Measured bare-loop cost of the cpu
  fixture (50 in-process iterations, CLI): glibc NTS 1.10 ms, glibc ZTS 1.65 ms,
  musl NTS 3.69 ms. Alpine (musl) PHP images run this allocation-heavy loop
  ~3.4x slower than Debian (glibc) ones. The php-fpm baseline therefore uses
  the Debian image; the RoadRunner image is still Alpine-based (see below), so
  its cpu numbers carry a musl handicap.

- **If you benchmark the ePHPm image with its baked-in default config, you
  will measure the rate limiter, not PHP.** The image's default
  `/etc/ephpm/ephpm.toml` ships `per_ip_rate = 500`, and a single-IP load
  generator gets clamped to 500 req/s of 200s with the rest served as 429s.
  The manifest here mounts a clean config (no `[server.limits]`, which means
  unlimited), so cluster runs are unaffected — but always check the status-code
  distribution of any load-tool output before trusting a throughput number.

- **Budget partitioning vs shared budget.** In Kubernetes, resource limits are
  per-container, so the nginx + php-fpm pod partitions its budget
  (50m nginx / 200m fpm) — a real constraint of multi-process stacks on k8s,
  but one that can bottleneck whichever container is undersized for a given
  workload. The local reference numbers instead used a shared 0.25-CPU cgroup
  for the pair (podman pod), which is the most charitable configuration for
  fpm. Single-process runtimes (ePHPm, FrankenPHP, Swoole) need no such choice.

- **FrankenPHP ships PHP 8.5**, not 8.4. The `dunglas/frankenphp:latest` image
  bundles PHP 8.5 (ZTS). All other runtimes use PHP 8.4. Measured bare-loop
  speed of 8.5 vs 8.4 on this fixture is identical (1.08 vs 1.10 ms), so the
  skew is minor here.

- **Worker count must match the CPU quota, not the node.** The ePHPm worker
  entry pins `worker_count = 1` because a measured knob matrix at 250m CPU
  showed 1 worker beating the derived default of 2 by ~20% (2100 vs 1690
  req/s on hello c=16) and 4 workers doing no better than 2 - under a tight
  cgroup quota, thread contention costs more than parallelism buys. It also
  sets `worker_max_requests = 1000000`: the shipped default of 500 forces a
  worker recycle every ~0.25 s at 2000 req/s. The `/hello` response includes
  `boot`/`request` counters so you can verify worker mode is actually active
  (climbing `request`, constant `boot`) instead of silently measuring
  per-request dispatch.

- **RoadRunner with 1 worker at 0.25 CPU is its worst case.** Its cpu deficit
  is mostly the musl base image (see above); the remainder is Go<->PHP IPC at
  a single worker. Production RoadRunner typically runs `num_workers = nproc`.
  The reference numbers reflect that handicap, not RR's ceiling.

- **Swoole and RoadRunner are not drop-in.** They require a custom server
  bootstrap (Swoole, ~20 LoC) or PSR-7 worker loop (RoadRunner, ~35 LoC).
  They are Class B runtimes and should only be compared with each other.

- **Load generator ran in a sibling container** on the same node. Network path
  is loopback-equivalent inside the kind node. Absolute numbers will differ
  on real hardware.

- **Reference numbers are from our hardware.** The manifests exist so you can
  reproduce on your own cluster and get numbers relevant to your environment.

## Reproducing

```bash
# 1. Build the RoadRunner image (requires Docker/podman, kind CLI, internet access):
./rr/build-rr.sh --cluster-name ephpm-lab   # adjust cluster name if needed

# 2. Apply the full stack and run all k6 jobs sequentially:
./scripts/run-runtimes-bench.sh

# Or step through manually:
kubectl apply -f k8s/runtimes-bench.yaml
# Delete the auto-fired k6 Jobs (the manifest creates them on apply):
kubectl delete job k6-bench-ephpm k6-bench-nginx-fpm k6-bench-frankenphp \
  k6-bench-swoole k6-bench-rr k6-bench-ephpm-worker \
  -n runtimes-bench --ignore-not-found
# Wait for all deployments (bench-ephpm-turso is retired at replicas: 0, so
# its rollout status returns immediately):
for d in bench-ephpm bench-ephpm-turso bench-nginx-fpm bench-frankenphp \
         bench-swoole bench-rr bench-ephpm-worker; do
  kubectl rollout status deployment/$d -n runtimes-bench --timeout=300s
done
# Then reapply to recreate jobs, or use the driver script.
kubectl wait --for=condition=complete job/k6-bench-ephpm -n runtimes-bench --timeout=300s
kubectl logs job/k6-bench-ephpm -n runtimes-bench

# Tear down:
kubectl delete namespace runtimes-bench
```

### RoadRunner image

The `bench-rr:local` image must be built locally because kind cluster nodes
have no access to `apk` package mirrors at pod start. The `rr/` directory
contains everything needed:

```
rr/Dockerfile      Multi-stage build: composer vendor + rr binary + php:8.4-cli-alpine
rr/composer.json   spiral/roadrunner ^2024 + spiral/roadrunner-http ^3.5 + nyholm/psr7
rr/worker.php      PSR-7 worker loop (~35 LoC)
rr/.rr.yaml        RoadRunner config (1 worker, port 8080)
rr/build-rr.sh     Build + kind load helper script
```

The Deployment uses `imagePullPolicy: Never` so kind reads the locally-loaded
image without contacting a registry.

## Manifest Layout

```
k8s/runtimes-bench.yaml    Single self-contained manifest:
                             - Namespace
                             - ConfigMaps (fixtures, configs, k6 script)
                             - 7 Deployments + 7 Services (five Class A/B
                               runtimes, the ePHPm worker-mode lane, and
                               the retired bench-ephpm-turso lane at
                               replicas: 0)
                             - 6 k6 Jobs (one per runtime lane plus the
                               worker lane; bench-ephpm-turso has none)
scripts/run-runtimes-bench.sh  Driver: apply, wait, run jobs, print summaries
```
