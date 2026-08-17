# Reproducing The Lab

The benchmarks use Kubernetes jobs, plain manifests, and k6. Run each comparison sequentially; concurrent benchmark jobs turn a small cluster into part of the experiment.

## Prerequisites

- A Kubernetes cluster with enough room for the test pods.
- `kubectl` configured for that cluster.
- Docker or another compatible container builder when testing a locally built image.
- Bash, Git, and standard Unix tools.

The original lab used WSL and Linode LKE, but neither is required.

## OPcache Cluster Test

```bash
kubectl apply -f k8s/opcache-cluster.yaml
kubectl apply -f k8s/opcache-fpm-cluster.yaml
bash k8s/opcache-cluster-test.sh
bash k8s/opcache-blip-test.sh
```

For a local kind cluster with a locally loaded ePHPm image:

```bash
EPHPM_IMAGE=ephpm-v040-rc:final bash k8s/opcache-blip-test.sh
```

For a remote cluster, leave `EPHPM_IMAGE` unset to use the published image declared by the manifest.

## Laravel v4

Deploy the three Laravel paths:

```bash
kubectl apply -f k8s/laravel-v4.yaml
kubectl rollout status deployment/laravel-v4-php-fpm -n laravel-v4 --timeout=600s
kubectl rollout status deployment/laravel-v4-ephpm-worker -n laravel-v4 --timeout=600s
kubectl scale deployment/laravel-v4-ephpm -n laravel-v4 --replicas=1
kubectl rollout status deployment/laravel-v4-ephpm -n laravel-v4 --timeout=600s
```

Run the baseline jobs one at a time:

```bash
kubectl delete job k6-v4-php-fpm k6-v4-ephpm k6-v4-ephpm-worker -n laravel-v4 --ignore-not-found
kubectl apply -f k8s/k6-v4-php-fpm.yaml
kubectl wait --for=condition=complete job/k6-v4-php-fpm -n laravel-v4 --timeout=300s
kubectl logs job/k6-v4-php-fpm -n laravel-v4

kubectl apply -f k8s/k6-v4-ephpm.yaml
kubectl wait --for=condition=complete job/k6-v4-ephpm -n laravel-v4 --timeout=300s
kubectl logs job/k6-v4-ephpm -n laravel-v4

kubectl apply -f k8s/k6-v4-ephpm-worker.yaml
kubectl wait --for=condition=complete job/k6-v4-ephpm-worker -n laravel-v4 --timeout=300s
kubectl logs job/k6-v4-ephpm-worker -n laravel-v4
```

For the `160 iterations/s` pressure run, first apply the shared script and then run the target jobs sequentially:

```bash
kubectl apply -f k8s/k6-v4-rate8.yaml
kubectl delete job k6-v4-rate8-ephpm-worker -n laravel-v4 --ignore-not-found
kubectl apply -f k8s/k6-v4-rate8-ephpm-worker.yaml
kubectl wait --for=condition=complete job/k6-v4-rate8-ephpm-worker -n laravel-v4 --timeout=300s
kubectl logs job/k6-v4-rate8-ephpm-worker -n laravel-v4

kubectl delete job k6-v4-rate8-php-fpm -n laravel-v4 --ignore-not-found
kubectl apply -f k8s/k6-v4-rate8-php-fpm.yaml
kubectl wait --for=condition=complete job/k6-v4-rate8-php-fpm -n laravel-v4 --timeout=300s
kubectl logs job/k6-v4-rate8-php-fpm -n laravel-v4
```

## Krayin v3b Three-Way Test

Deploy Krayin, keep MySQL running, and run only one application deployment at a time on small clusters:

```bash
kubectl apply -f k8s/krayin-v3.yaml
kubectl rollout status deployment/krayin-mysql -n krayin-bench --timeout=300s
```

If MySQL was recreated, rerun the installer before testing:

```bash
kubectl delete job krayin-install -n krayin-bench --ignore-not-found
kubectl apply -f k8s/krayin-v3.yaml
kubectl wait --for=condition=complete job/krayin-install -n krayin-bench --timeout=900s
```

Run PHP-FPM, ePHPm request mode, then ePHPm worker mode. Scale down each target before bringing up the next one:

```bash
kubectl scale deployment/krayin-ephpm deployment/krayin-ephpm-worker -n krayin-bench --replicas=0
kubectl scale deployment/krayin-php-fpm -n krayin-bench --replicas=1
kubectl rollout status deployment/krayin-php-fpm -n krayin-bench --timeout=900s
kubectl delete job k6-v3-php-fpm -n krayin-bench --ignore-not-found
kubectl apply -f k8s/k6-v3-php-fpm.yaml
kubectl wait --for=condition=complete job/k6-v3-php-fpm -n krayin-bench --timeout=300s
kubectl logs job/k6-v3-php-fpm -n krayin-bench
```

```bash
kubectl scale deployment/krayin-php-fpm -n krayin-bench --replicas=0
kubectl scale deployment/krayin-ephpm -n krayin-bench --replicas=1
kubectl rollout status deployment/krayin-ephpm -n krayin-bench --timeout=900s
kubectl delete job k6-v3-ephpm -n krayin-bench --ignore-not-found
kubectl apply -f k8s/k6-v3-ephpm.yaml
kubectl wait --for=condition=complete job/k6-v3-ephpm -n krayin-bench --timeout=300s
kubectl logs job/k6-v3-ephpm -n krayin-bench
```

```bash
kubectl scale deployment/krayin-ephpm -n krayin-bench --replicas=0
kubectl scale deployment/krayin-ephpm-worker -n krayin-bench --replicas=1
kubectl rollout status deployment/krayin-ephpm-worker -n krayin-bench --timeout=900s
kubectl delete job k6-v3b-ephpm-worker -n krayin-bench --ignore-not-found
kubectl apply -f k8s/k6-v3b-ephpm-worker.yaml
kubectl wait --for=condition=complete job/k6-v3b-ephpm-worker -n krayin-bench --timeout=300s
kubectl logs job/k6-v3b-ephpm-worker -n krayin-bench
```

## WordPress v5 WooCommerce Test

The v5 fixture is deliberately application-shaped: a WordPress 7.0 store (pinned by `wp core download --version=7.0` in `wordpress-v5/scripts/prepare-wordpress.sh`) with WooCommerce, Elementor, OceanWP, Ocean Extra, Yoast, ACF, Contact Form 7, and Redis Object Cache. It seeds 1,200 products, 800 variations, 2,000 reviews, 300 posts, and 200 completed orders. The PHP-FPM lane uses nginx, `phpredis`, and Redis; the ePHPm lanes use its native WordPress cache drop-in and native KV.

Render the script and k6 ConfigMaps, then deploy the backing services:

```bash
bash scripts/apply-wordpress-v5.sh
kubectl rollout status deployment/wordpress-v5-mysql -n wordpress-v5 --timeout=300s
kubectl rollout status deployment/wordpress-v5-redis -n wordpress-v5 --timeout=300s
```

Run only one application lane at a time. The helper runs the PHP-FPM, ePHPm request, and ePHPm worker lanes in that order. Each lane must first pass a two-user WooCommerce cart-isolation gate; a failure stops the sequence before the browse benchmark.

```bash
bash scripts/run-wordpress-v5.sh
```

The browse profile is a constant-arrival-rate run at 8 iterations/s for 120 seconds. It cycles through a product page, a catalog page, and a search route. The cart gate and resulting observations are described in [the v5 report](wordpress-v5.md).

## Cleanup

```bash
kubectl delete namespace opcache-demo --ignore-not-found
kubectl delete namespace php-bench --ignore-not-found
kubectl delete namespace laravel-v4 --ignore-not-found
kubectl delete namespace krayin-bench --ignore-not-found
kubectl delete namespace wordpress-v5 --ignore-not-found
```
