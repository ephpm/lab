#!/usr/bin/env bash
# Full db benchmark matrix for v0.6.0.
#
#   A  sqlite  single    rusqlite in-process (production default)
#   B  turso   single    Turso engine in-process (experimental)
#   C  sqlite  cluster   sqld sidecar, WAL frames over gRPC (production)
#   D  turso   cluster   CDC-native over the cluster channel (experimental)
#
# Two fixtures: db.php (10 sequential SELECTs -- read path) and write.php
# (1 INSERT -- write path). The write fixture is the one that separates
# A from C and B from D; on a primary, a SELECT never touches replication.
#
# NOTE ON grep: this runs under Git Bash on Windows, where the default
# `grep` on PATH swallows -E/-i and prints the flag instead of filtering.
# Every filter here uses /usr/bin/grep explicitly. Raw oha output is kept
# in results/ regardless, so a filtering bug can never silently discard a
# measurement again.
set -uo pipefail

IMG="${EPHPM_IMAGE:-docker.io/ephpm/ephpm:v0.6.0-php8.5}"
OHA=ghcr.io/hatoo/oha:latest
CURL=docker.io/curlimages/curl:latest
NET=dbbench-net
CPUS=1
DUR="${DUR:-15s}"
REPS="${REPS:-2}"
G=/usr/bin/grep
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/results-engines"
mkdir -p "$OUT"

podman network exists "$NET" 2>/dev/null || podman network create "$NET" >/dev/null
podman image exists "$CURL" 2>/dev/null || podman pull -q "$CURL" >/dev/null

cleanup() {
  podman rm -f dbbench-c1 dbbench-c2 >/dev/null 2>&1 || true
}
trap cleanup EXIT

get() { podman run --rm --network "$NET" "$CURL" -s --max-time 25 "$1" 2>/dev/null; }

start_node() {  # name cfgfile volume [static-ip]
  local name="$1" cfg="$2" vol="$3" ip="${4:-}"
  podman volume rm -f "$vol" >/dev/null 2>&1 || true
  podman volume create "$vol" >/dev/null
  # Clustered CDC refuses to start on an unspecified bind IP (it would
  # have nothing dialable to advertise), so the cluster lanes pin
  # addresses with --ip and the configs name those exact IPs.
  local iparg=()
  [ -n "$ip" ] && iparg=(--ip "$ip")
  podman run -d --name "$name" --network "$NET" "${iparg[@]}" --cpus "$CPUS" \
    -v "$HERE/fixtures/sqlite:/var/www/html:ro" \
    -v "$HERE/configs/$cfg:/etc/ephpm/ephpm.toml:ro" \
    -v "$vol:/data" \
    "$IMG" >/dev/null
}

wait_ready() {  # host
  local host="$1"
  for _ in $(seq 1 90); do
    [ -n "$(get "http://$host:8080/seed.php")" ] && return 0
    sleep 1
  done
  return 1
}

measure() {  # lane fixture
  local lane="$1" fx="$2"
  for conc in 1 16; do
    podman run --rm --network "$NET" "$OHA" -z 8s -c "$conc" --no-tui \
      "http://dbbench-c1:8080/$fx" >/dev/null 2>&1
    for rep in $(seq 1 "$REPS"); do
      local f="$OUT/${lane}-${fx%.php}-c${conc}-r${rep}.txt"
      podman run --rm --network "$NET" "$OHA" -z "$DUR" -c "$conc" --no-tui \
        "http://dbbench-c1:8080/$fx" > "$f" 2>&1
      printf '%-22s %-6s c=%-3s r=%s  ' "$lane" "${fx%.php}" "$conc" "$rep"
      "$G" -E "Requests/sec" "$f" | head -1 | tr -s ' '
    done
  done
}

banner() { echo ""; echo "############ LANE $1 ############"; }

# ---------------------------------------------------------------- single
run_single() {  # lane cfg
  local lane="$1" cfg="$2"
  banner "$lane ($cfg, single-node, --cpus $CPUS)"
  cleanup
  start_node dbbench-c1 "$cfg" "dbv-$lane"
  if ! wait_ready dbbench-c1; then
    echo "!! $lane never became ready:"; podman logs dbbench-c1 2>&1 | tail -40; return 1
  fi
  echo "-- engine selection --"
  podman logs dbbench-c1 2>&1 | "$G" -iE "turso|engine|experimental" | head -5
  echo "-- fixture --"
  echo "   seed:   $(get http://dbbench-c1:8080/seed.php)"
  local body; body="$(get http://dbbench-c1:8080/db.php)"
  echo "   db.php: $body"
  case "$body" in *'"sum":55'*) ;; *) echo "!! FIXTURE WRONG -- lane invalid"; return 1;; esac
  measure "$lane" db.php
  measure "$lane" write.php
  cleanup
}

# --------------------------------------------------------------- cluster
run_cluster() {  # lane primarycfg replicacfg
  local lane="$1" pcfg="$2" rcfg="$3"
  banner "$lane (2 nodes, --cpus $CPUS each)"
  cleanup
  start_node dbbench-c1 "$pcfg" "dbv-$lane-1" 10.89.1.11
  sleep 3
  start_node dbbench-c2 "$rcfg" "dbv-$lane-2" 10.89.1.12

  if ! wait_ready dbbench-c1; then
    echo "!! $lane primary never became ready:"; podman logs dbbench-c1 2>&1 | tail -50; return 1
  fi
  echo "-- primary startup --"
  podman logs dbbench-c1 2>&1 | "$G" -iE "turso|sqld|cdc|primary|replica|cluster|error|warn" | head -12
  echo "-- replica startup --"
  podman logs dbbench-c2 2>&1 | "$G" -iE "turso|sqld|cdc|primary|replica|cluster|error|warn" | head -12

  echo "-- fixture --"
  echo "   seed:   $(get http://dbbench-c1:8080/seed.php)"
  local body; body="$(get http://dbbench-c1:8080/db.php)"
  echo "   db.php: $body"
  case "$body" in *'"sum":55'*) ;; *) echo "!! FIXTURE WRONG -- lane invalid"; return 1;; esac

  # PROVE replication before believing any clustered number. Write 5 rows
  # on the primary, then poll the replica until it agrees.
  echo "-- replication proof --"
  for _ in 1 2 3 4 5; do get http://dbbench-c1:8080/write.php >/dev/null; done
  local converged=no rc=""
  for _ in $(seq 1 30); do
    rc="$(get 'http://dbbench-c2:8080/count.php?t=wbench')"
    case "$rc" in *'"count":5'*) converged=yes; break;; esac
    sleep 1
  done
  echo "   primary wbench: $(get 'http://dbbench-c1:8080/count.php?t=wbench')"
  echo "   replica wbench: $rc"
  if [ "$converged" = yes ]; then
    echo "   REPLICATION VERIFIED"
  else
    echo "   !! REPLICATION DID NOT CONVERGE -- numbers below measure an"
    echo "   !! effectively single-node server and must NOT be compared."
  fi

  measure "$lane" db.php
  measure "$lane" write.php
  cleanup
}

run_single  A-sqlite-single single-sqlite.toml
run_single  B-turso-single  single-turso.toml
run_cluster C-sqlite-cluster cluster-sqlite-primary.toml cluster-sqlite-replica.toml
run_cluster D-turso-cluster  cluster-turso-primary.toml  cluster-turso-replica.toml

echo ""
echo "=== all lanes done; raw output in $OUT ==="
