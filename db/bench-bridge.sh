#!/usr/bin/env bash
# In-process bridge vs MySQL wire, same engine, same process.
#
#   A  sqlite  rusqlite in-process -- REMOVED in ePHPm v0.7.0. Opt-in via
#              BRIDGE_LEGACY_SQLITE=1, and then only on the pinned v0.6.3
#              image; it is a historical row, not a lane of this run.
#   B  turso   Turso engine in-process -- the only engine from v0.7.0 on,
#              and the default lane of this suite.
#
# Each lane runs ONE container and measures six cells against it:
#
#   wire-point    db.php            10 sequential point SELECTs, pdo_mysql
#   bridge-point  bridge/point.php  the same 10 SELECTs via ephpm_db_query()
#   wire-write    write.php         1 INSERT, pdo_mysql
#   bridge-write  bridge/write.php  the same INSERT via ephpm_db_execute()
#   wire-wide     wide.php          100 rows x 8 cols, pdo_mysql
#   bridge-wide   bridge/wide.php   the same SELECT via ephpm_db_query()
#
# Both paths execute inside the SAME server process against the SAME
# litewire backend instance (the bridge shares the object the MySQL
# frontend serves), so the only difference between a wire cell and its
# bridge twin is the path: TCP connect + MySQL protocol round-trips vs
# direct C calls into a per-thread Session. That per-request connect is
# part of the wire number ON PURPOSE — it is what a real PHP request
# pays without persistent connections, and deleting it is the bridge's
# whole pitch.
#
# Needs ephpm >= v0.6.3: the ephpm_db_* functions first shipped in a
# tagged release there (ephpm#257/#258). The seed gate below fails
# loudly on anything older.
#
# NOTE ON grep: this runs under Git Bash on Windows, where the default
# `grep` on PATH swallows -E/-i and prints the flag instead of filtering.
# Every filter here uses /usr/bin/grep explicitly. Raw oha output is kept
# in results/ regardless, so a filtering bug can never silently discard a
# measurement again.
set -uo pipefail

# The Turso lane runs on the current pin. The rusqlite lane CANNOT: v0.7.0
# removed that engine and `engine = "sqlite"` is a hard startup error, so
# lane A is opt-in (BRIDGE_LEGACY_SQLITE=1) and hard-pinned to the last
# image that has the engine. Two lanes on two different ePHPm versions are
# NOT an engine A/B -- they differ by a whole release. If you enable lane A,
# report it as a separate historical row, never in one table with lane B.
IMG="${EPHPM_IMAGE:-docker.io/ephpm/ephpm:v0.7.0-php8.5}"
LEGACY_IMG="${EPHPM_LEGACY_IMAGE:-docker.io/ephpm/ephpm:v0.6.3-php8.5}"
OHA=ghcr.io/hatoo/oha:latest
CURL=docker.io/curlimages/curl:latest
NET=dbbench-net
CPUS=1
DUR="${DUR:-15s}"
REPS="${REPS:-2}"
G=/usr/bin/grep
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/results-bridge"
mkdir -p "$OUT"

podman network exists "$NET" 2>/dev/null || podman network create "$NET" >/dev/null
podman image exists "$CURL" 2>/dev/null || podman pull -q "$CURL" >/dev/null

cleanup() {
  podman rm -f dbbench-c1 >/dev/null 2>&1 || true
}
trap cleanup EXIT

get() { podman run --rm --network "$NET" "$CURL" -s --max-time 25 "$1" 2>/dev/null; }

wait_ready() {
  for _ in $(seq 1 90); do
    [ -n "$(get "http://dbbench-c1:8080/seed.php")" ] && return 0
    sleep 1
  done
  return 1
}

measure() {  # cellname urlpath
  local cell="$1" path="$2"
  for conc in 1 16; do
    # warmup: fixed 8s, never recorded
    podman run --rm --network "$NET" "$OHA" -z 8s -c "$conc" --no-tui \
      "http://dbbench-c1:8080/$path" >/dev/null 2>&1
    for rep in $(seq 1 "$REPS"); do
      local f="$OUT/${LANE}-${cell}-c${conc}-r${rep}.txt"
      podman run --rm --network "$NET" "$OHA" -z "$DUR" -c "$conc" --no-tui \
        "http://dbbench-c1:8080/$path" > "$f" 2>&1
      printf '%-16s %-13s c=%-3s r=%s  ' "$LANE" "$cell" "$conc" "$rep"
      "$G" -E "Requests/sec" "$f" | head -1 | tr -s ' '
    done
  done
}

gate() {  # description urlpath expected-substring
  local desc="$1" path="$2" want="$3" body
  body="$(get "http://dbbench-c1:8080/$path")"
  echo "   $desc: $body"
  case "$body" in
    *"$want"*) return 0 ;;
    *) echo "!! GATE FAILED ($desc wanted $want) -- lane invalid"; return 1 ;;
  esac
}

run_lane() {  # lane cfg img
  LANE="$1"; local cfg="$2" img="$3"
  echo ""; echo "############ LANE $LANE ($cfg, single-node, --cpus $CPUS) ############"
  echo "   image: $img"
  # Purge THIS lane's files before measuring. $OUT persists across runs, and a
  # lane that is not run this time (lane A is opt-in) leaves its previous
  # session's files sitting next to this session's -- parse.sh then prints one
  # table mixing two runs on two images with nothing to distinguish them. That
  # happened on 2026-08-19: an archived "v0.7.0" directory still carried
  # v0.6.3 rusqlite rows. Stale results that look current are exactly the
  # failure this suite's gates exist to prevent.
  rm -f "$OUT/${LANE}-"*.txt
  {
    echo "lane=$LANE image=$img config=$cfg"
    echo "recorded=$(date -u +%Y-%m-%dT%H:%M:%SZ) host=$(hostname) dur=$DUR reps=$REPS cpus=$CPUS"
  } > "$OUT/RUN-INFO-${LANE}.txt"
  cleanup
  podman volume rm -f "dbv-$LANE" >/dev/null 2>&1 || true
  podman volume create "dbv-$LANE" >/dev/null
  podman run -d --name dbbench-c1 --network "$NET" --cpus "$CPUS" \
    -v "$HERE/fixtures/sqlite:/var/www/html:ro" \
    -v "$HERE/fixtures/bridge:/var/www/html/bridge:ro" \
    -v "$HERE/configs/$cfg:/etc/ephpm/ephpm.toml:ro" \
    -v "dbv-$LANE:/data" \
    "$img" >/dev/null
  if ! wait_ready; then
    echo "!! $LANE never became ready:"; podman logs dbbench-c1 2>&1 | tail -40; return 1
  fi
  echo "-- engine selection --"
  podman logs dbbench-c1 2>&1 | "$G" -iE "turso|engine|experimental" | head -5

  # Gates, in dependency order. bridge/seed.php doubles as the
  # function-registration gate (it errors if ephpm_db_* is missing) and
  # writes the wide table THROUGH the bridge; wide.php then reads it
  # back over the wire, proving both paths hit the same backend.
  echo "-- gates --"
  gate "wire seed  "  "seed.php"          '"status":"ok"' || return 1
  gate "bridge seed"  "bridge/seed.php"   '"sum":106050' || return 1
  gate "wire point "  "db.php"            '"sum":55'     || return 1
  gate "bridge point" "bridge/point.php"  '"sum":55'     || return 1
  gate "wire wide  "  "wide.php"          '"sum":106050' || return 1
  gate "bridge wide"  "bridge/wide.php"   '"sum":106050' || return 1

  measure wire-point   db.php
  measure bridge-point bridge/point.php
  measure wire-write   write.php
  measure bridge-write bridge/write.php
  measure wire-wide    wide.php
  measure bridge-wide  bridge/wide.php
  cleanup
}

FAILED=0
# Lane A is the removed rusqlite engine: opt-in, and on its own pinned image.
if [ "${BRIDGE_LEGACY_SQLITE:-0}" = 1 ]; then
  if [ "$LEGACY_IMG" != "$IMG" ]; then
    echo "!! lane A-sqlite runs on $LEGACY_IMG, lane B-turso on $IMG."
    echo "!! Those differ by a whole ePHPm release, not just an engine: report"
    echo "!! A as a separate historical row, never in one table with B."
  fi
  run_lane A-sqlite single-sqlite.toml "$LEGACY_IMG" || FAILED=1
fi
run_lane B-turso  single-turso.toml  "$IMG" || FAILED=1

echo ""
if [ "$FAILED" = 1 ]; then
  echo "=== one or more lanes FAILED their gates; raw output in $OUT ==="
  exit 1
fi
echo "=== all lanes done; raw output in $OUT ==="
