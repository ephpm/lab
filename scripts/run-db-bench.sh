#!/usr/bin/env bash
# run-db-bench.sh
# Drive the ePHPm database benchmark suites on a single host with podman.
#
# Usage:
#   ./scripts/run-db-bench.sh <suite> [--image IMG] [--dur 15s] [--reps 2]
#
#   suite = engines     HISTORICAL, v0.6.3-pinned. 4-lane SQLite/Turso matrix
#           admission   HISTORICAL, v0.6.3-pinned. sqld write_permits sweep
#           proxy       DB-proxy cost/benefit matrix (hop vs pooling)
#           bridge      in-process ephpm_db_* vs MySQL wire (Turso)
#           wp-bridge   WordPress: db-wordpress drop-in vs mysqli wire
#           all         all five, in that order
#
# `engines` and `admission` exercise the rusqlite engine, the sqld sidecar
# and the write_permits knob -- all REMOVED in ePHPm v0.7.0. They ignore
# --image/EPHPM_IMAGE and stay hard-pinned to v0.6.3 so that bumping the
# default below cannot turn them into dead or mislabelled lanes. Their
# recorded numbers are the historical parity evidence behind the engine
# switch; replacing them for v0.7.0 means a new Turso-single vs
# Turso-CDC-clustered matrix, not edits to those lanes. See DB-BENCH.md.
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

IMAGE="${EPHPM_IMAGE:-docker.io/ephpm/ephpm:v0.7.0-php8.5}"
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

export EPHPM_IMAGE="$IMAGE" DUR REPS

run_suite() {  # name script resultsdir [image-label]
  echo ""
  echo "========================================================================"
  echo "  $1  ->  image=${4:-$IMAGE} dur=$DUR reps=$REPS"
  echo "========================================================================"
  bash "${DB}/$2" || { echo "!! suite $1 failed"; return 1; }
  echo ""
  echo "--- $1 results ---"
  bash "${DB}/parse.sh" "$3"
}

# The two historical suites keep their own v0.6.3 pin; label them as such
# rather than printing this run's $IMAGE over the top of it.
HIST="v0.6.3 (HARD-PINNED, historical -- ignores --image)"

case "$SUITE" in
  engines)   run_suite engines   bench-engines.sh   results-engines   "$HIST" ;;
  admission) run_suite admission bench-admission.sh results-admission "$HIST" ;;
  proxy)     run_suite proxy     bench-proxy.sh     results-proxy ;;
  bridge)    run_suite bridge    bench-bridge.sh    results-bridge ;;
  wp-bridge) run_suite wp-bridge bench-wordpress-bridge.sh results-wp-bridge ;;
  all)
    run_suite engines   bench-engines.sh   results-engines   "$HIST"
    run_suite admission bench-admission.sh results-admission "$HIST"
    run_suite proxy     bench-proxy.sh     results-proxy
    run_suite bridge    bench-bridge.sh    results-bridge
    run_suite wp-bridge bench-wordpress-bridge.sh results-wp-bridge
    ;;
  *) echo "unknown suite: $SUITE (engines|admission|proxy|bridge|wp-bridge|all)" >&2; exit 2 ;;
esac

echo ""
echo "==> Done. Raw oha output is under db/results-*/ -- keep it. A filtering"
echo "    bug in a summary script must never be able to silently discard a"
echo "    measurement that was actually taken."
