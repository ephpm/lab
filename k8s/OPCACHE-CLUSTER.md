# OPcache clustering demo (ePHPm >= v0.4.0; manifests pin v0.8.5)

Two Kubernetes tests that exercise ePHPm's cluster-wide OPcache
invalidation feature and compare it to the php-fpm equivalent
(rolling restart).

Both require an image containing ePHPm >= **v0.4.0** (the release that
ships cluster invalidation) — that is the feature floor, not the pin. The
manifests pin `ephpm/ephpm:v0.8.5-php8.4`, the newest published image.
For a local kind cluster with a locally-loaded RC image, override the image
used by the blip test with `EPHPM_IMAGE`:

```sh
EPHPM_IMAGE=ephpm-v040-rc:final bash k8s/opcache-blip-test.sh
```

For a normal remote cluster such as LKE, leave `EPHPM_IMAGE` unset so the
published image in the manifest is used.

## What ships in the box

| File | Role |
|------|------|
| `opcache-cluster.yaml` | 2-node ePHPm StatefulSet (gossip cluster), headless service for gossip seeds, load-balanced service `opcache-demo-lb`, seed fixture (correctness `.php` files + compile-weight `bench.php` that require_once's 30 include files) |
| `opcache-fpm-cluster.yaml` | 2-replica php-fpm Deployment (nginx + php:8.4-fpm-bookworm, `opcache.validate_timestamps=0`), same seed fixture |
| `k6-opcache-blip.yaml` | k6 ConfigMap (constant 50 iters/s x 120s) + two Jobs targeting each stack |
| `opcache-cluster-test.sh` | **Correctness** test - PRE/deploy/POST assertion that one `ephpm deploy` invalidates OPcache on every cluster node |
| `opcache-blip-test.sh` | **A/B blip** test - runs k6 against each stack while triggering the cache-bust mid-load; prints a comparison table |

## Test 1 - correctness (`opcache-cluster-test.sh`)

Warms `opcache_target.php` on both pods, runs `ephpm deploy` on pod-0
only, then asserts that pod-1 (which never saw the command) also drops
the cache entry on its next request. Recovery: next hit re-caches.

```sh
kubectl apply -f k8s/opcache-cluster.yaml
bash k8s/opcache-cluster-test.sh
# => PASS: one deploy on opcache-demo-0 invalidated OPcache on opcache-demo-0 opcache-demo-1
```

## Test 2 - A/B blip under live load (`opcache-blip-test.sh`)

Applies **both** stacks, warms each pod, then runs k6 against each in
turn (constant 50 iters/s x 120s = ~6000 requests) while triggering the
cache-bust ~60s in:

- **ePHPm side:** `ephpm deploy` on one pod - one KV write, gossip fans
  out, every node's per-request watcher drops the vhost's OPcache
  entries on the next request. No process restart. No dropped connections.
- **php-fpm side:** `kubectl rollout restart deployment/opcache-fpm` -
  the only real-world cache-bust when `opcache.validate_timestamps=0`.
  RollingUpdate default (maxUnavailable 25%) leaves one pod up while the
  other cycles; new pods serve their first requests from a cold OPcache.

At the end it prints a comparison table (requests / failed / fail rate /
avg / p95 / p99 / max) and a verdict line.

```sh
bash k8s/opcache-blip-test.sh
```

Sample output from a validated run in the ephpm-lab kind cluster:

```
Metric         | ePHPm (deploy)         | php-fpm (rolling)
---------------+------------------------+-----------------------
requests       | 6001                   | 6001
failed         | 0                      | 0
fail rate      | 0.00%                  | 0.00%
avg            | 1.02 ms                | 1.16 ms
p95            | 1.28 ms                | 1.41 ms
p99            | 1.59 ms                | 1.72 ms
max            | 2.65 ms                | 4.34 ms
```

At 50 rps against 2 replicas, K8s readiness gates and nginx upstream
keepalive keep the fpm rollout at 100% availability - the honest headline
isn't "fpm drops requests" (it doesn't, at this rate) but rather:

- The recompile blip is visible in the `max` column - fpm's cold-cache
  spike (4.34 ms) is larger than ephpm's post-invalidation blip
  (2.65 ms), because ephpm only recompiles the 31 dropped entries while
  fpm's new pods start with an empty cache and every include is a miss
  until they warm up.
- ePHPm is faster on avg/p95/p99 across the board (embedded runtime,
  no FastCGI hop).
- ePHPm did the cache-bust with **one KV write** - no process restart,
  no pod cycling, no readiness-probe gymnastics.

Push the request rate higher (200-500 rps) or shrink the fleet to 1
replica and fpm's failed-request column starts filling up while ephpm
stays at zero. The 50-rps run keeps things headline-honest at a load
level a small demo cluster can serve without CPU throttling.

## Runtime prerequisites

- ePHPm >= **v0.4.0** for the correctness test (`opcache:version:<vhost>`
  KV replication + per-request watcher) and the blip test.
- kind cluster with the image loaded (or reachable published images).
- `kubectl`, `bash`, `jq` on the client.
- podman-based kind: `export KIND_EXPERIMENTAL_PROVIDER=podman`.
