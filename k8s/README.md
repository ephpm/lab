# Kubernetes Manifest Map

These manifests are organized by benchmark phase. They are intentionally plain YAML so the test can be inspected without a custom framework.

| File | Purpose |
| --- | --- |
| `php-benchmark.yaml` | v1 tiny PHP script harness. |
| `k6-*-hello.yaml`, `k6-*-cpu.yaml`, `inspect-*.yaml` | v1 k6 and inspection jobs. |
| `php-benchmark-v2.yaml` | v2 synthetic app-shaped PHP workload. |
| `k6-v2-*.yaml` | v2 k6 jobs. |
| `krayin-v3.yaml` | v3 Krayin CRM workload. |
| `k6-v3-*.yaml` | v3 k6 jobs. |
| `laravel-v4.yaml` | v4 Laravel/cache workload. Render with `scripts/render-laravel-v4.sh` before applying. |
| `k6-v4-php-fpm.yaml` | v4 PHP-FPM baseline k6 job and shared v4 script ConfigMap. |
| `k6-v4-ephpm.yaml` | v4 ePHPm normal-mode k6 job. |
| `k6-v4-ephpm-worker.yaml` | v4 ePHPm worker-mode k6 job. |
| `k6-v4-rate8.yaml` | v4 rate-8 shared k6 script ConfigMap only. |
| `k6-v4-rate8-ephpm-worker.yaml` | v4 rate-8 ePHPm worker job. |
| `k6-v4-rate8-php-fpm.yaml` | v4 rate-8 PHP-FPM job. |
| `wordpress-v5.yaml` | v5 WordPress/WooCommerce fixture: shared MySQL, Redis, PHP-FPM/nginx, ePHPm request mode, and ePHPm worker mode. Render and apply with `scripts/apply-wordpress-v5.sh`. |
| `runtimes-bench.yaml` | Five-way runtime comparison (`RUNTIMES-BENCH.md`): 7 Deployments/Services (incl. the undriven `bench-ephpm-turso` lane and ePHPm worker mode) and 6 k6 Jobs, self-contained. |
| `opcache-cluster.yaml` | Two-node ePHPm gossip cluster for the deploy-time OPcache invalidation demo (driver: `opcache-cluster-test.sh`). |
| `opcache-fpm-cluster.yaml` | nginx + php-fpm control for the OPcache A/B — cache bust via rolling restart. |
| `k6-opcache-blip.yaml` | k6 constant-arrival-rate load for the OPcache invalidation A/B (driver: `opcache-blip-test.sh`). |
| `k6-v3b-ephpm-worker.yaml` | v3b Krayin ePHPm worker-mode k6 job. |
| `k6-inspect.yaml` | v1 diagnostic k6 job recording per-request `app_elapsed_ms` server-side timing. |
| `verify-client.yaml` | Long-sleeping busybox pod in `php-bench` for in-cluster curl verification. |

The manifests no longer pin pods to the original LKE node names. Kubernetes will schedule them normally on your cluster.
