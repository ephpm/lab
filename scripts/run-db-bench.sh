#!/usr/bin/env bash
# run-db-bench.sh
# Drive the ePHPm database benchmark suites on a single host with podman.
#
# Usage:
#   ./scripts/run-db-bench.sh <suite> [--image IMG] [--dur 15s] [--reps 2]
#
#   suite = engines     4-lane SQLite/Turso matrix (single-node vs clustered)
#           admission   sqld write-admission sweep (write_permits 1/2/4/8)
#           proxy       DB-proxy cost/benefit matrix (hop vs pooling)
#           bridge      in-process ephpm_db_* vs MySQL wire, per engine
#           wp-bridge   WordPress: db-wordpress drop-in vs mysqli wire
#           cluster     Turso single vs CDC-clustered, whole-DB and per-vhost
#           all         all six, in that order
#
# THE DEFAULT IMAGE IS PER SUITE, not global. The first five suites
# benchmark machinery that was REMOVED in ePHPm v0.7.0 -- the rusqlite
# engine, the sqld sidecar, the write_permits knob -- so they stay pinned
# to the last image that has it (v0.6.3) and are the historical record.
# `cluster` is the v0.8.x replacement and tracks the newest published
# image. Bumping the historical suites would not modernise them, it would
# just make them fail at startup: `engine = "sqlite"` is a hard error on
# v0.7.0+. An explicit --image (or EPHPM_IMAGE) still overrides whichever
# default applies.
#
# Unlike the k6/Kubernetes suites in k8s/, these run on ONE host under
# podman. That is deliberate: the effects being measured (a wire-protocol
# hop, a connection-pool checkout, a write-admission semaphore) are tens
# to hundreds of microseconds, and cluster network jitter is larger than
# the signal. This is the "local single-node" tier described in
# DB-BENCH.md -- it answers "did this change cost anything", not "what
# throughput will production see".
#
# Prerequisites:
#   - podman with a running machine
#   - an ePHPm image available locally or pullable (see --image)
#   - internet access on first run to pull oha, curl, mysql:8, postgres:16
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DB="${ROOT}/db"

SUITE="${1:-}"
[ -n "$SUITE" ] || { sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 2; }
shift

# Pinned to the last image that still has the pre-v0.7.0 machinery.
HISTORICAL_IMAGE="docker.io/ephpm/ephpm:v0.6.3-php8.5"
# Newest PUBLISHED image. All five `cluster` lanes run in their intended
# mode on any v0.8.6+ image -- per-site clustered replication (ephpm#416)
# first appears in v0.8.6, and the v0.8.6/v0.8.7 images were published
# 2026-09-01. The cluster suite's reference numbers in DB-BENCH.md were
# recorded on v0.8.7-php8.5; a fresh run uses the newest published tag below.
CURRENT_IMAGE="docker.io/ephpm/ephpm:v0.10.8-php8.5"

case "$SUITE" in
  cluster) DEFAULT_IMAGE="$CURRENT_IMAGE" ;;
  all)     DEFAULT_IMAGE="" ;;   # each suite picks its own below
  *)       DEFAULT_IMAGE="$HISTORICAL_IMAGE" ;;
esac

IMAGE="${EPHPM_IMAGE:-$DEFAULT_IMAGE}"
DUR="${DUR:-15s}"
REPS="${REPS:-2}"
while [ $# -gt 0 ]; do
  case "$1" in
    --image) IMAGE="$2"; shift 2 ;;
    --dur)   DUR="$2";   shift 2 ;;
    --reps)  REPS="$2";  shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

export DUR REPS

run_suite() {  # name script resultsdir default-image
  # An explicit --image / EPHPM_IMAGE wins; otherwise each suite gets the
  # image line it was written against.
  local img="${IMAGE:-$4}"
  echo ""
  echo "========================================================================"
  echo "  $1  ->  image=$img dur=$DUR reps=$REPS"
  echo "========================================================================"
  EPHPM_IMAGE="$img" bash "${DB}/$2" || { echo "!! suite $1 failed"; return 1; }
  echo ""
  echo "--- $1 results ---"
  bash "${DB}/parse.sh" "$3"
}

case "$SUITE" in
  engines)   run_suite engines   bench-engines.sh   results-engines   "$HISTORICAL_IMAGE" ;;
  admission) run_suite admission bench-admission.sh results-admission "$HISTORICAL_IMAGE" ;;
  proxy)     run_suite proxy     bench-proxy.sh     results-proxy     "$HISTORICAL_IMAGE" ;;
  bridge)    run_suite bridge    bench-bridge.sh    results-bridge    "$HISTORICAL_IMAGE" ;;
  wp-bridge) run_suite wp-bridge bench-wordpress-bridge.sh results-wp-bridge "$HISTORICAL_IMAGE" ;;
  cluster)   run_suite cluster   bench-cluster.sh   results-cluster   "$CURRENT_IMAGE" ;;
  all)
    run_suite engines   bench-engines.sh   results-engines   "$HISTORICAL_IMAGE"
    run_suite admission bench-admission.sh results-admission "$HISTORICAL_IMAGE"
    run_suite proxy     bench-proxy.sh     results-proxy     "$HISTORICAL_IMAGE"
    run_suite bridge    bench-bridge.sh    results-bridge    "$HISTORICAL_IMAGE"
    run_suite wp-bridge bench-wordpress-bridge.sh results-wp-bridge "$HISTORICAL_IMAGE"
    run_suite cluster   bench-cluster.sh   results-cluster   "$CURRENT_IMAGE"
    ;;
  *) echo "unknown suite: $SUITE (engines|admission|proxy|bridge|wp-bridge|cluster|all)" >&2; exit 2 ;;
esac

echo ""
echo "==> Done. Raw oha output is under db/results-*/ -- keep it. A filtering"
echo "    bug in a summary script must never be able to silently discard a"
echo "    measurement that was actually taken."
