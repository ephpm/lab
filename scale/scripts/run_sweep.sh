#!/usr/bin/env bash
# Multi-tenant scaling sweep for ePHPm.
#
# For each (max_open_dbs cap) x (N sites) it stands up ONE fresh ePHPm instance
# serving EXACTLY N vhosts off a shared docroot with per-site Turso databases,
# drives concurrent round-robin traffic across all N vhosts (front + permalink +
# REST), and records ephpm RSS / CPU / fds alongside aggregate RPS + latency.
#
# Seeding uses a template model: one site is seeded once via HTTP (the server
# creates the DB), the closed Turso file is copied to all N sites. Fast and
# uniform for both wp-lite and wp-real.
#
# Re-runnable. All state lives under RUN (a WSL-native path — NOT /mnt/c: the
# per-site Turso files and the KV socket cannot live on DrvFs).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

BIN="${BIN:?set BIN=/path/to/ephpm}"
RUN="${RUN:-$HOME/ephpm-scalebench-run}"
WORKLOAD="${WORKLOAD:-wp-lite}"          # wp-lite | wp-real
DOCROOT="${DOCROOT:-}"                    # defaults per workload below
PORT="${PORT:-8110}"
WIREPORT="${WIREPORT:-13306}"
NS="${NS:-10 25 50 100 250 500 1000}"
CAPS="${CAPS:-256 4096}"
# FPM execution engine axis (PR #296). Each engine is a FRESH ephpm instance
# whose ONLY difference is the exported EPHPM_PHP__FPM_ENGINE env var — same
# binary throughout. "spawn_blocking" (default, unbounded on tokio's blocking
# pool) vs "pool" (a fixed pool of dedicated OS threads == autotuned worker
# count; bounded concurrency). Results are namespaced per engine so a
# head-to-head never clobbers the other's point.
ENGINES="${ENGINES:-spawn_blocking}"
CORES="$(nproc)"
C="${C:-$((CORES * 4))}"
WARMUP="${WARMUP:-8}"
DUR="${DUR:-25}"
PAD="${PAD:-4}"
RESULTS="${RESULTS:-$HERE/results/$WORKLOAD}"
# Request paths for the load mix. wp-real's REST index 301-redirects /wp-json,
# so it overrides REST to a rest_route form that returns 200 directly.
FRONT="${FRONT:-/}"
PERM="${PERM:-/?p=1}"
if [ "$WORKLOAD" = "wp-real" ]; then
  REST="${REST:-/?rest_route=/wp/v2/posts&per_page=1}"
else
  REST="${REST:-/wp-json/wp/v2/posts?per_page=1}"
fi

if [ -z "$DOCROOT" ]; then
  case "$WORKLOAD" in
    wp-lite) DOCROOT="$HERE/workloads/wp-lite" ;;
    wp-real) DOCROOT="${WP_DOCROOT:?set WP_DOCROOT for wp-real}" ;;
    *) echo "unknown WORKLOAD $WORKLOAD" >&2; exit 1 ;;
  esac
fi

SITES="$RUN/sites"; DBS="$RUN/dbs"; LOG="$RUN/server.log"; CFG="$RUN/ephpm.gen.toml"
LOADGEN="$RUN/loadgen"
mkdir -p "$RUN" "$RESULTS"

# RUN must be WSL-native: the server inherits it as cwd (below), and the
# per-site Turso files + KV socket cannot live on DrvFs anyway.
case "$RUN" in
  /mnt/*) echo "RUN=$RUN is on DrvFs (/mnt/*) — use a WSL-native path" >&2; exit 1 ;;
esac

# Stage the shared docroot onto WSL-native disk. Serving PHP off /mnt/c (DrvFs)
# adds a large per-request stat/read penalty that would swamp the measurement;
# the per-site DBs already live under RUN (native) for the same reason.
STAGED="$RUN/docroot"
rm -rf "$STAGED"; mkdir -p "$STAGED"
cp -a "$DOCROOT"/. "$STAGED"/
echo "staged docroot: $DOCROOT -> $STAGED"
DOCROOT="$STAGED"

# Raise fd limit as high as allowed and record it (the 1000-site x WAL-fd story).
ulimit -n "$(ulimit -Hn)" 2>/dev/null || true
ULIMIT_N="$(ulimit -n)"
echo "ulimit -n = $ULIMIT_N ; cores = $CORES ; concurrency = $C"

# Build the load generator once.
( cd "$HERE/loadgen" && go build -o "$LOADGEN" . )

SRV_PID=""
stop_server() {
  [ -n "$SRV_PID" ] || return 0
  kill "$SRV_PID" 2>/dev/null || true
  for _ in $(seq 1 50); do kill -0 "$SRV_PID" 2>/dev/null || break; sleep 0.1; done
  kill -9 "$SRV_PID" 2>/dev/null || true
  SRV_PID=""
}
trap 'stop_server' EXIT

render_config() {
  local cap="$1"
  sed -e "s#@PORT@#$PORT#g" -e "s#@SITES_DIR@#$SITES#g" \
      -e "s#@DB_DIR@#$DBS#g" -e "s#@MAX_OPEN_DBS@#$cap#g" \
      -e "s#@WIREPORT@#$WIREPORT#g" \
      "$HERE/config/ephpm.tmpl.toml" > "$CFG"
}

start_server() {
  : > "$LOG"
  # The server MUST start with a WSL-native cwd. This harness lives on /mnt/c
  # (DrvFs); launching ephpm with a DrvFs working directory adds a large 9p
  # syscall penalty on the hot request path — measured ~4x on wp-lite (same
  # binary/config: /mnt/c cwd = 4.2k RPS, native ext4 cwd = 15.9k RPS; found
  # during PR #303 validation). cd to the native run dir before exec.
  ( cd "$RUN" && exec "$BIN" serve --config "$CFG" ) >>"$LOG" 2>&1 &
  SRV_PID=$!
  for _ in $(seq 1 100); do
    if curl -s -o /dev/null -m 2 -H "Host: $(printf 'site-%0*d' "$PAD" 1)" "http://127.0.0.1:$PORT/"; then
      return 0
    fi
    kill -0 "$SRV_PID" 2>/dev/null || { echo "server died on start:" >&2; tail -20 "$LOG" >&2; exit 1; }
    sleep 0.2
  done
  echo "server never became ready" >&2; tail -20 "$LOG" >&2; exit 1
}

make_template() {
  # Seed exactly one site via HTTP so the server creates the DB, then stop and
  # keep the closed file(s) as a template.
  rm -rf "$SITES" "$DBS"; mkdir -p "$SITES" "$DBS"
  bash "$HERE/scripts/provision.sh" "$SITES" "$DOCROOT" 1 "$PAD"
  render_config 256
  start_server
  if [ "$WORKLOAD" = "wp-real" ]; then
    bash "$HERE/scripts/seed_wp_real.sh" "http://127.0.0.1:$PORT" "$(printf 'site-%0*d' "$PAD" 1)"
  else
    curl -s -H "Host: $(printf 'site-%0*d' "$PAD" 1)" "http://127.0.0.1:$PORT/seed.php" >/dev/null
  fi
  stop_server
  local key; key="$(printf 'site-%0*d' "$PAD" 1)"
  rm -f "$RUN"/template.db*
  cp "$DBS/$key.db" "$RUN/template.db"
  if [ -f "$DBS/$key.db-wal" ]; then cp "$DBS/$key.db-wal" "$RUN/template.db-wal"; fi
  if [ -f "$DBS/$key.db-shm" ]; then cp "$DBS/$key.db-shm" "$RUN/template.db-shm"; fi
  echo "template built: $(ls -la "$RUN"/template.db* | awk '{print $9, $5}')"
  return 0
}

seed_copy() {
  local n="$1"
  rm -rf "$DBS"; mkdir -p "$DBS"
  for i in $(seq 1 "$n"); do
    local key; key="$(printf 'site-%0*d' "$PAD" "$i")"
    cp "$RUN/template.db" "$DBS/$key.db"
    if [ -f "$RUN/template.db-wal" ]; then cp "$RUN/template.db-wal" "$DBS/$key.db-wal"; fi
    if [ -f "$RUN/template.db-shm" ]; then cp "$RUN/template.db-shm" "$DBS/$key.db-shm"; fi
  done
  return 0
}

one_point() {
  local cap="$1" n="$2" engine="${3:-spawn_blocking}"
  echo "=== engine=$engine cap=$cap N=$n ==="
  bash "$HERE/scripts/provision.sh" "$SITES" "$DOCROOT" "$n" "$PAD"
  seed_copy "$n"
  render_config "$cap"
  start_server

  # Record the engine's own autotune line from startup so the pool-size cap is
  # explicit in the result. spawn_blocking emits no pool line (pool_size=0).
  local startup="$CUR_RESULTS/cap-$cap-n-$n.startup.txt"
  grep -aiE "fpm execution pool started|HTTP listening|per-site database mode|autotune" "$LOG" \
    | sed -r 's/\x1b\[[0-9;]*m//g' > "$startup" 2>/dev/null || true
  local pool_size=0
  if grep -q "fpm execution pool started" "$startup" 2>/dev/null; then
    pool_size="$(grep -oE 'thread_count=[0-9]+' "$startup" | head -1 | grep -oE '[0-9]+')"
    pool_size="${pool_size:-0}"
  fi

  local base="http://127.0.0.1:$PORT"
  local lgjson="$RUN/lg.json" spjson="$RUN/sp.json"
  # sampler covers warmup + measurement
  bash "$HERE/scripts/sample.sh" "$SRV_PID" "$((WARMUP + DUR))" "$spjson" &
  local sp=$!
  "$LOADGEN" -base "$base" -n "$n" -pad "$PAD" -c "$C" \
     -front "$FRONT" -perm "$PERM" -rest "$REST" \
     -warmup "$WARMUP" -d "$DUR" -label "$WORKLOAD cap=$cap N=$n" > "$lgjson" 2>>"$RUN/loadgen.err"
  wait "$sp"

  local out="$CUR_RESULTS/cap-$cap-n-$n.json"
  # merge: {load: <lg>, resource: <sp>, meta:{...}}
  {
    printf '{"meta":{"workload":"%s","engine":"%s","pool_size":%s,"cap":%s,"n":%s,"concurrency":%s,"warmup":%s,"dur":%s,"ulimit_n":%s,"cores":%s},' \
      "$WORKLOAD" "$engine" "$pool_size" "$cap" "$n" "$C" "$WARMUP" "$DUR" "$ULIMIT_N" "$CORES"
    printf '"load":'; cat "$lgjson"; printf ','
    printf '"resource":'; cat "$spjson"; printf '}'
  } > "$out"
  echo "wrote $out"
  local rps; rps=$(grep -o '"rps": [0-9.]*' "$lgjson" | head -1)
  local rss; rss=$(grep -o '"rss_steady_kb": [0-9]*' "$spjson")
  echo "    -> engine=$engine pool_size=$pool_size ; $rps ; $rss ; fd_max $(grep -o '"fd_max": [0-9]*' "$spjson")"
  stop_server
}

echo "workload=$WORKLOAD docroot=$DOCROOT engines=$ENGINES"
make_template
for engine in $ENGINES; do
  # Fresh instance per engine: the ONLY thing that changes across engines is
  # this env var, inherited by every ephpm start_server spawns below.
  export EPHPM_PHP__FPM_ENGINE="$engine"
  CUR_RESULTS="$RESULTS/engine-$engine"
  mkdir -p "$CUR_RESULTS"
  echo "########## engine=$engine (EPHPM_PHP__FPM_ENGINE=$engine) ##########"
  for cap in $CAPS; do
    for n in $NS; do
      one_point "$cap" "$n" "$engine"
    done
  done
done
echo "sweep complete. results in $RESULTS/engine-{$(echo $ENGINES | tr ' ' ',')}"
