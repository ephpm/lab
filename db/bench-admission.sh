#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# REQUIRES A v0.6.1 BUILD.
#
# The write_permits knob this suite sweeps merged in ephpm#222 and is not in
# v0.6.0 or earlier. On an older image only the `baseline` setting is
# meaningful -- and on its own it demonstrates the clustered-write collapse
# that motivated the knob.
#
# The suite has a hard gate for exactly this reason -- ephpm-config does not
# deny unknown fields, so an image WITHOUT the knob silently ignores
# write_permits and would benchmark as a baseline lane wearing a patched
# lane's label. run_setting refuses to measure if the startup log does not
# agree with what the lane claims.
# ---------------------------------------------------------------------------
# Lane C only: does write admission control flatten the clustered-sqld
# write collapse?
#
#   baseline  ephpm:v060-rc2        (no knob at all)
#   p2/p4/p8  ephpm:sqld-admission  ([db.sqlite.sqld] write_permits = N)
#
# Each setting gets a FRESH 2-node cluster (config change => restart), a
# replication-verified gate before any measurement, and a read pass before
# the write sweep so a collapsed write cell cannot poison the read number.
#
# Concurrencies run ASCENDING so the cell most likely to wedge the server
# is last.
#
# NOTE ON grep: Git Bash's default `grep` swallows -E. Everything here uses
# /usr/bin/grep explicitly. Raw oha output is kept per cell regardless.
set -uo pipefail

BASE_IMG="${EPHPM_IMAGE:-docker.io/ephpm/ephpm:v0.6.0-php8.5}"
ADM_IMG="${EPHPM_ADMISSION_IMAGE:-localhost/ephpm:sqld-admission}"
OHA=ghcr.io/hatoo/oha:latest
CURL=docker.io/curlimages/curl:latest
NET=dbbench-net
CPUS=1
DUR="${DUR:-15s}"
WARM=5s
REPS="${REPS:-2}"
G=/usr/bin/grep
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${BENCH_OUT:-$HERE/results-admission}"
mkdir -p "$OUT"

podman network exists "$NET" 2>/dev/null || podman network create "$NET" >/dev/null

cleanup() { podman rm -f dbbench-c1 dbbench-c2 >/dev/null 2>&1 || true; }
trap cleanup EXIT

get() { podman run --rm --network "$NET" "$CURL" -s --max-time 25 "$1" 2>/dev/null; }

start_node() {  # name img cfg volume ip
  local name="$1" img="$2" cfg="$3" vol="$4" ip="$5"
  podman volume rm -f "$vol" >/dev/null 2>&1 || true
  podman volume create "$vol" >/dev/null
  podman run -d --name "$name" --network "$NET" --ip "$ip" --cpus "$CPUS" \
    -v "$HERE/fixtures/sqlite:/var/www/html:ro" \
    -v "$HERE/configs/$cfg:/etc/ephpm/ephpm.toml:ro" \
    -v "$vol:/data" \
    "$img" >/dev/null
}

wait_ready() {
  for _ in $(seq 1 90); do
    [ -n "$(get "http://$1:8080/seed.php")" ] && return 0
    sleep 1
  done
  return 1
}

measure() {  # tag fixture conc
  local tag="$1" fx="$2" conc="$3"
  podman run --rm --network "$NET" "$OHA" -z "$WARM" -c "$conc" --no-tui \
    "http://dbbench-c1:8080/$fx" >/dev/null 2>&1
  for rep in $(seq 1 "$REPS"); do
    local f="$OUT/${tag}-${fx%.php}-c${conc}-r${rep}.txt"
    podman run --rm --network "$NET" "$OHA" -z "$DUR" -c "$conc" --no-tui \
      "http://dbbench-c1:8080/$fx" > "$f" 2>&1
    local rps ok bad err
    rps=$("$G" -E "Requests/sec" "$f" | head -1 | tr -s ' ' | cut -f2)
    ok=$("$G" -E "^  \[200\]" "$f" | tr -s ' ' | cut -d' ' -f3)
    bad=$("$G" -E "^  \[5[0-9][0-9]\]" "$f" | tr -s ' ' | cut -d' ' -f3 | paste -sd+ | bc 2>/dev/null)
    err=$("$G" -A5 "Error distribution" "$f" | "$G" -E "^  \[[0-9]+\]" | tr -s ' ' | sed 's/^ *//' | paste -sd';')
    printf '%-14s %-6s c=%-3s r=%s  rps=%-10s 200=%-8s 5xx=%-6s err=%s\n' \
      "$tag" "${fx%.php}" "$conc" "$rep" "${rps:-0}" "${ok:-0}" "${bad:-0}" "${err:-none}"
  done
}

run_setting() {  # tag img primarycfg replicacfg expect_knob
  local tag="$1" img="$2" pcfg="$3" rcfg="$4" expect="$5"
  echo ""
  echo "############ $tag ($img) ############"
  cleanup
  start_node dbbench-c1 "$img" "$pcfg" "dbv-adm-1" 10.89.1.11
  sleep 3
  start_node dbbench-c2 "$img" "$rcfg" "dbv-adm-2" 10.89.1.12

  if ! wait_ready dbbench-c1; then
    echo "!! $tag primary never became ready:"; podman logs dbbench-c1 2>&1 | tail -40; return 1
  fi

  # PROOF the knob took effect. ephpm-config has no deny_unknown_fields, so
  # an image without the knob silently ignores it -- without this gate a
  # "patched" lane could quietly be a baseline lane.
  local knobline
  knobline="$(podman logs dbbench-c1 2>&1 | "$G" -i "write admission" | head -1)"
  echo "-- knob: ${knobline:-<absent>}"
  if [ "$expect" = yes ] && [ -z "$knobline" ]; then
    echo "!! EXPECTED write admission to be enabled and it is not -- lane invalid"; return 1
  fi
  if [ "$expect" = no ] && [ -n "$knobline" ]; then
    echo "!! baseline unexpectedly has admission enabled -- lane invalid"; return 1
  fi

  local body; body="$(get http://dbbench-c1:8080/db.php)"
  echo "-- fixture: $body"
  case "$body" in *'"sum":55'*) ;; *) echo "!! FIXTURE WRONG -- lane invalid"; return 1;; esac

  # Replication gate: write 5 rows on the primary, poll the replica.
  for _ in 1 2 3 4 5; do get http://dbbench-c1:8080/write.php >/dev/null; done
  local converged=no rc=""
  for _ in $(seq 1 30); do
    rc="$(get 'http://dbbench-c2:8080/count.php?t=wbench')"
    case "$rc" in *'"count":5'*) converged=yes; break;; esac
    sleep 1
  done
  echo "-- replica wbench: $rc"
  if [ "$converged" = yes ]; then
    echo "-- REPLICATION VERIFIED"
  else
    echo "!! REPLICATION DID NOT CONVERGE -- numbers below are not a cluster"
  fi

  # Reads first: a wedged write cell must not colour the read result.
  measure "$tag" db.php 16
  for conc in 1 4 8 16; do
    measure "$tag" write.php "$conc"
  done
  cleanup
}

WANT="${*:-baseline permits2 permits4 permits8}"
want() { case " $WANT " in *" $1 "*) return 0;; *) return 1;; esac; }

want baseline && run_setting baseline "$BASE_IMG" \
  cluster-sqlite-primary.toml cluster-sqlite-replica.toml no
want stockdefault && run_setting stockdefault "$ADM_IMG" \
  cluster-sqlite-primary.toml cluster-sqlite-replica.toml no
want permits1 && run_setting permits1 "$ADM_IMG" \
  admission-primary-permits1.toml admission-replica-permits1.toml yes
want permits2 && run_setting permits2 "$ADM_IMG" \
  admission-primary-permits2.toml admission-replica-permits2.toml yes
want permits4 && run_setting permits4 "$ADM_IMG" \
  admission-primary-permits4.toml admission-replica-permits4.toml yes
want permits8 && run_setting permits8 "$ADM_IMG" \
  admission-primary-permits8.toml admission-replica-permits8.toml yes

echo ""
echo "=== done; raw oha output in $OUT ==="
