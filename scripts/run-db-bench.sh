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
#           all         all three, in that order
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

IMAGE="${EPHPM_IMAGE:-docker.io/ephpm/ephpm:v0.6.0-php8.5}"
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

run_suite() {  # name script resultsdir
  echo ""
  echo "========================================================================"
  echo "  $1  ->  image=$IMAGE dur=$DUR reps=$REPS"
  echo "========================================================================"
  bash "${DB}/$2" || { echo "!! suite $1 failed"; return 1; }
  echo ""
  echo "--- $1 results ---"
  bash "${DB}/parse.sh" "$3"
}

case "$SUITE" in
  engines)   run_suite engines   bench-engines.sh   results-engines ;;
  admission) run_suite admission bench-admission.sh results-admission ;;
  proxy)     run_suite proxy     bench-proxy.sh     results-proxy ;;
  all)
    run_suite engines   bench-engines.sh   results-engines
    run_suite admission bench-admission.sh results-admission
    run_suite proxy     bench-proxy.sh     results-proxy
    ;;
  *) echo "unknown suite: $SUITE (engines|admission|proxy|all)" >&2; exit 2 ;;
esac

echo ""
echo "==> Done. Raw oha output is under db/results-*/ -- keep it. A filtering"
echo "    bug in a summary script must never be able to silently discard a"
echo "    measurement that was actually taken."
