#!/usr/bin/env bash
# Open-loop overload matrix for ePHPm: what does an OVERLOADED instance
# actually return when requests keep arriving whether or not earlier ones
# finished?
#
# For each (engine x max_connections x arrival-rate) point it stands up ONE
# fresh ephpm instance (same binary throughout — only EPHPM_PHP__FPM_ENGINE
# and the rendered [server.limits] block differ), floods it with the loadgen's
# open-loop mode (-rate, per-request client timeout), then after a cooldown
# runs a light closed-loop probe against the SAME still-running instance to
# measure recovery. Records status taxonomy, success-only latency percentiles,
# per-second completion series, RSS series/steady/peak, CPU, and whether the
# process survived.
#
# Workload is wp-real (real WordPress) at N sites — heavy enough per request
# (~10 req/s/core) that overload is reachable at modest arrival rates.
#
# Usage:
#   BIN=/root/ephpm-target/release/ephpm WP_DOCROOT=/root/wp-real-src \
#     bash scripts/run_overload.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

BIN="${BIN:?set BIN=/path/to/ephpm}"
WP_DOCROOT="${WP_DOCROOT:?set WP_DOCROOT=/path/to/wordpress (with ephpm-db drop-in)}"
RUN="${RUN:-$HOME/ephpm-overload-run}"
PORT="${PORT:-8117}"          # own port: sibling harnesses use 8110/8111/18100s
WIREPORT="${WIREPORT:-13317}"
N="${N:-10}"
CAP="${CAP:-4096}"
PAD="${PAD:-4}"
ENGINES="${ENGINES:-spawn_blocking pool}"
LIMITS="${LIMITS:-0 256}"     # [server.limits] max_connections; 0 = section omitted (default)
RATES="${RATES:-400 800}"     # open-loop arrival rates (req/s)
ARRIVAL="${ARRIVAL:-const}"
WARMUP="${WARMUP:-5}"
DUR="${DUR:-60}"
TIMEOUT="${TIMEOUT:-10}"      # per-request client timeout (s)
COOLDOWN="${COOLDOWN:-30}"    # idle seconds between flood end and recovery probe
PROBE_C="${PROBE_C:-4}"       # closed-loop recovery probe concurrency
PROBE_DUR="${PROBE_DUR:-10}"
RESULTS="${RESULTS:-$HERE/results/wp-real-openloop}"
CORES="$(nproc)"

# wp-real request mix (same as run_sweep.sh): /wp-json 301s, use rest_route.
FRONT="${FRONT:-/}"
PERM="${PERM:-/?p=1}"
REST="${REST:-/?rest_route=/wp/v2/posts&per_page=1}"

SITES="$RUN/sites"; DBS="$RUN/dbs"; LOG="$RUN/server.log"; CFG="$RUN/ephpm.gen.toml"
LOADGEN="$RUN/loadgen"
mkdir -p "$RUN" "$RESULTS"

# RUN must be WSL-native: the server inherits it as cwd (below), and the
# per-site Turso files + KV socket cannot live on DrvFs anyway.
case "$RUN" in
  /mnt/*) echo "RUN=$RUN is on DrvFs (/mnt/*) — use a WSL-native path" >&2; exit 1 ;;
esac

# Stage the shared docroot onto WSL-native disk (DrvFs would swamp the numbers).
STAGED="$RUN/docroot"
if [ ! -f "$STAGED/index.php" ]; then
  rm -rf "$STAGED"; mkdir -p "$STAGED"
  cp -a "$WP_DOCROOT"/. "$STAGED"/
  echo "staged docroot: $WP_DOCROOT -> $STAGED"
fi
DOCROOT="$STAGED"

ulimit -n "$(ulimit -Hn)" 2>/dev/null || true
ULIMIT_N="$(ulimit -n)"
echo "ulimit -n = $ULIMIT_N ; cores = $CORES"

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
  local cap="$1" maxconn="$2"
  sed -e "s#@PORT@#$PORT#g" -e "s#@SITES_DIR@#$SITES#g" \
      -e "s#@DB_DIR@#$DBS#g" -e "s#@MAX_OPEN_DBS@#$cap#g" \
      -e "s#@WIREPORT@#$WIREPORT#g" \
      "$HERE/config/ephpm.tmpl.toml" > "$CFG"
  if [ "$maxconn" != "0" ]; then
    printf '\n[server.limits]\nmax_connections = %s\n' "$maxconn" >> "$CFG"
  fi
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
  for _ in $(seq 1 150); do
    if curl -s -o /dev/null -m 2 -H "Host: $(printf 'site-%0*d' "$PAD" 1)" "http://127.0.0.1:$PORT/"; then
      return 0
    fi
    kill -0 "$SRV_PID" 2>/dev/null || { echo "server died on start:" >&2; tail -20 "$LOG" >&2; exit 1; }
    sleep 0.2
  done
  echo "server never became ready" >&2; tail -20 "$LOG" >&2; exit 1
}

make_template() {
  # Seed exactly one real-WP site via its HTTP installer, keep the closed
  # per-site Turso file(s) as the template for all N sites.
  [ -f "$RUN/template.db" ] && { echo "template exists: $RUN/template.db"; return 0; }
  rm -rf "$SITES" "$DBS"; mkdir -p "$SITES" "$DBS"
  bash "$HERE/scripts/provision.sh" "$SITES" "$DOCROOT" 1 "$PAD"
  render_config 256 0
  start_server
  bash "$HERE/scripts/seed_wp_real.sh" "http://127.0.0.1:$PORT" "$(printf 'site-%0*d' "$PAD" 1)"
  stop_server
  local key; key="$(printf 'site-%0*d' "$PAD" 1)"
  cp "$DBS/$key.db" "$RUN/template.db"
  if [ -f "$DBS/$key.db-wal" ]; then cp "$DBS/$key.db-wal" "$RUN/template.db-wal"; fi
  if [ -f "$DBS/$key.db-shm" ]; then cp "$DBS/$key.db-shm" "$RUN/template.db-shm"; fi
  echo "template built: $(ls -la "$RUN"/template.db* | awk '{print $9, $5}')"
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
}

rss_kb() { awk '/^VmRSS:/{print $2}' "/proc/$1/status" 2>/dev/null || echo 0; }

one_point() {
  local engine="$1" maxconn="$2" rate="$3"
  local tag="lim-$maxconn-rate-$rate"
  local outdir="$RESULTS/engine-$engine"
  mkdir -p "$outdir"
  echo "=== engine=$engine max_connections=$maxconn rate=$rate/s ==="
  bash "$HERE/scripts/provision.sh" "$SITES" "$DOCROOT" "$N" "$PAD"
  seed_copy "$N"
  render_config "$CAP" "$maxconn"
  start_server

  # Startup capture + HARD verification the engine env took effect.
  local startup="$outdir/$tag.startup.txt"
  grep -aiE "fpm execution pool started|HTTP listening|per-site database mode|limits|autotune" "$LOG" \
    | sed -r 's/\x1b\[[0-9;]*m//g' > "$startup" 2>/dev/null || true
  local pool_size=0
  if grep -q "fpm execution pool started" "$startup" 2>/dev/null; then
    pool_size="$(grep -oE 'thread_count=[0-9]+' "$startup" | head -1 | grep -oE '[0-9]+')"
    pool_size="${pool_size:-0}"
  fi
  if [ "$engine" = "pool" ] && [ "$pool_size" = "0" ]; then
    echo "FATAL: engine=pool but no 'fpm execution pool started' line — env override did not take" >&2
    exit 1
  fi
  if [ "$engine" = "spawn_blocking" ] && [ "$pool_size" != "0" ]; then
    echo "FATAL: engine=spawn_blocking but a pool started" >&2
    exit 1
  fi

  local base="http://127.0.0.1:$PORT"
  local lgjson="$RUN/lg.json" spjson="$RUN/sp.json" probejson="$RUN/probe.json"
  # Sampler covers warmup + flood + drain (client timeout tail).
  bash "$HERE/scripts/sample.sh" "$SRV_PID" "$((WARMUP + DUR + TIMEOUT))" "$spjson" &
  local sp=$!
  "$LOADGEN" -base "$base" -n "$N" -pad "$PAD" \
     -rate "$rate" -arrival "$ARRIVAL" -timeout "$TIMEOUT" \
     -front "$FRONT" -perm "$PERM" -rest "$REST" \
     -warmup "$WARMUP" -d "$DUR" \
     -label "wp-real open-loop engine=$engine lim=$maxconn rate=$rate" \
     > "$lgjson" 2>>"$RUN/loadgen.err"
  wait "$sp"

  # Survival + post-flood / post-cooldown RSS, then the recovery probe against
  # the SAME instance.
  local survived=true
  kill -0 "$SRV_PID" 2>/dev/null || survived=false
  local rss_flood; rss_flood="$(rss_kb "$SRV_PID")"
  local load1; load1="$(awk '{print $1}' /proc/loadavg)"
  if [ "$survived" = "true" ]; then
    sleep "$COOLDOWN"
    local rss_cool; rss_cool="$(rss_kb "$SRV_PID")"
    "$LOADGEN" -base "$base" -n "$N" -pad "$PAD" -c "$PROBE_C" \
       -front "$FRONT" -perm "$PERM" -rest "$REST" \
       -warmup 2 -d "$PROBE_DUR" \
       -label "recovery probe after $tag" > "$probejson" 2>>"$RUN/loadgen.err" || echo '{"error":"probe failed"}' > "$probejson"
  else
    local rss_cool=0
    echo '{"error":"server dead, no probe"}' > "$probejson"
    echo "!!! server DIED during flood — last log lines:" >&2
    tail -20 "$LOG" >&2
  fi
  kill -0 "$SRV_PID" 2>/dev/null || survived=false

  local out="$outdir/$tag.json"
  {
    printf '{"meta":{"workload":"wp-real","mode":"open-loop","engine":"%s","pool_size":%s,"max_connections":%s,"rate":%s,"arrival":"%s","timeout_s":%s,"cap":%s,"n":%s,"warmup":%s,"dur":%s,"cooldown":%s,"ulimit_n":%s,"cores":%s,"survived":%s,"rss_after_flood_kb":%s,"rss_after_cooldown_kb":%s,"loadavg1_after_flood":%s},' \
      "$engine" "$pool_size" "$maxconn" "$rate" "$ARRIVAL" "$TIMEOUT" "$CAP" "$N" "$WARMUP" "$DUR" "$COOLDOWN" "$ULIMIT_N" "$CORES" "$survived" "${rss_flood:-0}" "${rss_cool:-0}" "${load1:-0}"
    printf '"flood":'; cat "$lgjson"; printf ','
    printf '"resource":'; cat "$spjson"; printf ','
    printf '"recovery":'; cat "$probejson"; printf '}'
  } > "$out"
  echo "wrote $out"
  echo "    -> survived=$survived delivered=$(grep -o '"delivered_rps": [0-9.]*' "$lgjson" || true) rss_peak=$(grep -o '"rss_peak_kb": [0-9]*' "$spjson" || true)"
  stop_server
  sleep 3   # let sockets drain between points
}

echo "binary=$BIN engines=$ENGINES limits=$LIMITS rates=$RATES N=$N cap=$CAP dur=${DUR}s timeout=${TIMEOUT}s"
make_template
for engine in $ENGINES; do
  export EPHPM_PHP__FPM_ENGINE="$engine"
  echo "########## engine=$engine (EPHPM_PHP__FPM_ENGINE=$engine) ##########"
  for maxconn in $LIMITS; do
    for rate in $RATES; do
      one_point "$engine" "$maxconn" "$rate"
    done
  done
done
echo "overload matrix complete. results in $RESULTS/"
