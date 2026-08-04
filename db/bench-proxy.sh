#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# ephpm DB-proxy cost/benefit matrix.
#
# The question: what does putting ephpm-db (the in-process MySQL/PG proxy)
# in front of a database COST (one extra hop) and BUY (connection pooling)?
#
#   A  PHP -> litewire sqlite                        (control, no proxy)
#   B  PHP -> proxy(pool ON)  -> litewire sqlite
#   C  PHP -> proxy(pool OFF) -> litewire sqlite
#   D  PHP -> proxy(pool ON)  -> mysql:8
#   E  PHP -> proxy(pool OFF) -> mysql:8
#   F  PHP -> proxy(pool ON)  -> postgres:16
#   G  PHP -> proxy(pool OFF) -> postgres:16
#   H  PHP -> mysql:8                                (hop-cost control)
#   I  PHP -> postgres:16                            (hop-cost control)
#   J  PHP -> proxy(pool ON)  -> litewire turso
#
# "pool OFF" is NOT a separate code path -- there is no such switch. It is
# max_lifetime = "1ms" + min_connections = 0, which makes pool.rs treat
# every idle slot as expired at acquire() time and open a fresh backend
# connection per PHP request. The hop is preserved; only REUSE is removed.
# That is what isolates the two effects. See proxy-*-nopool.toml.
#
# GATES. Every lane must prove its own config took effect before any of its
# numbers are believed:
#   1. startup log contains the listeners this lane requires (and, for the
#      direct lanes, contains NO proxy listener at all)
#   2. seed.php succeeds and db.php returns the canonical sum 55
#   3. for real-upstream lanes, the rows are verified INSIDE the upstream
#      container -- proving traffic reached mysql/postgres and did not get
#      quietly answered by something else
#   4. every measured cell is checked for 100% 2xx by parse-proxy.sh
# A lane that fails a gate prints !! and is excluded from the report.
#
# grep NOTE: under Git Bash the default grep on PATH swallows -E/-i, so
# every filter uses /usr/bin/grep explicitly.
# ---------------------------------------------------------------------------
set -uo pipefail

IMG="${EPHPM_IMAGE:-docker.io/ephpm/ephpm:v0.6.0-php8.5}"
OHA=ghcr.io/hatoo/oha:latest
CURL=docker.io/curlimages/curl:latest
NET=dbbench-net
CPUS=1          # ephpm container; upstreams get 4 so they are never the cap
DUR="${DUR:-15s}"
WARM=8s
REPS="${REPS:-2}"
G=/usr/bin/grep
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/results-proxy"
mkdir -p "$OUT"
LOGS="$OUT/startup-logs"
mkdir -p "$LOGS"

podman network exists "$NET" 2>/dev/null || podman network create "$NET" >/dev/null

cleanup() { podman rm -f dbbench-c1 >/dev/null 2>&1 || true; }
trap cleanup EXIT

get() { podman run --rm --network "$NET" "$CURL" -s --max-time 25 "$1" 2>/dev/null; }

banner() { echo ""; echo "############ LANE $1 ############"; }

start_node() {  # cfg fixturedir [env...]
  local cfg="$1" fixtures="$2"; shift 2
  local envargs=()
  for e in "$@"; do envargs+=(-e "$e"); done
  podman rm -f dbbench-c1 >/dev/null 2>&1 || true
  podman volume rm -f dbv-proxy >/dev/null 2>&1 || true
  podman volume create dbv-proxy >/dev/null
  podman run -d --name dbbench-c1 --network "$NET" --cpus "$CPUS" \
    "${envargs[@]}" \
    -v "$HERE/fixtures/$fixtures:/var/www/html:ro" \
    -v "$HERE/configs/$cfg:/etc/ephpm/ephpm.toml:ro" \
    -v "dbv-proxy:/data" \
    "$IMG" >/dev/null
}

wait_ready() {
  for _ in $(seq 1 90); do
    [ -n "$(get http://dbbench-c1:8080/seed.php)" ] && return 0
    sleep 1
  done
  return 1
}

# Gate 1: assert the startup log says what this lane requires.
# A pattern prefixed with '!' is a NEGATIVE assertion -- it must NOT appear.
# The direct lanes use those: their whole claim is that no proxy is in the
# path, and the only way to prove that is that no proxy ever announced a
# listener.
check_log() {  # lane pattern...
  local lane="$1"; shift
  podman logs dbbench-c1 2>&1 | sed "s/[[0-9;]*m//g" > "$LOGS/$lane.log"
  local ok=0
  for pat in "$@"; do
    case "$pat" in
      '!'*)
        local neg="${pat#!}"
        if "$G" -qE "$neg" "$LOGS/$lane.log"; then
          echo "   !! gate/log PRESENT but must be absent: $neg"; ok=1
        else
          echo "   gate/log absent  : $neg"
        fi
        ;;
      *)
        if "$G" -qE "$pat" "$LOGS/$lane.log"; then
          echo "   gate/log OK      : $pat"
        else
          echo "   !! gate/log MISSING: $pat"; ok=1
        fi
        ;;
    esac
  done
  return $ok
}

measure() {  # lane fixture [conclist]
  local lane="$1" fx="$2" concs="${3:-1 16}"
  for conc in $concs; do
    podman run --rm --network "$NET" "$OHA" -z "$WARM" -c "$conc" --no-tui \
      "http://dbbench-c1:8080/$fx" >/dev/null 2>&1
    for rep in $(seq 1 "$REPS"); do
      local f="$OUT/${lane}-${fx%.php}-c${conc}-r${rep}.txt"
      podman run --rm --network "$NET" "$OHA" -z "$DUR" -c "$conc" --no-tui \
        "http://dbbench-c1:8080/$fx" > "$f" 2>&1
      printf '%-24s %-6s c=%-3s r=%s  ' "$lane" "${fx%.php}" "$conc" "$rep"
      "$G" -E "Requests/sec" "$f" | head -1 | tr -s ' '
    done
  done
}

# Gate 3: prove the rows are in the real upstream, not somewhere else.
verify_mysql_upstream() {
  local c; c="$(podman exec dbbench-mysql mysql -uroot -N -B -e \
    'SELECT COUNT(*) FROM bench.bench' 2>/dev/null | tr -d '\r')"
  echo "   gate/upstream    : mysql:8 bench.bench rows = ${c:-?}"
  [ "$c" = "10" ]
}
verify_pg_upstream() {
  local c; c="$(podman exec -e PGPASSWORD=bench dbbench-pg psql -U postgres -d bench -tAc \
    'SELECT COUNT(*) FROM bench' 2>/dev/null | tr -d '\r')"
  echo "   gate/upstream    : postgres:16 bench rows = ${c:-?}"
  [ "$c" = "10" ]
}

# Session-state leakage probe (pooled MySQL-shaped lanes only). Dirties a
# user variable in one PHP request, then asks a LATER request whether it
# survived. A non-null answer means pooled session state crossed a request
# boundary.
leak_probe() {  # lane
  local lane="$1"
  local s g
  s="$(get 'http://dbbench-c1:8080/leak.php?set=1')"
  g="$(get 'http://dbbench-c1:8080/leak.php?get=1')"
  echo "   probe/leak set   : $s"
  echo "   probe/leak get   : $g"
  echo "$lane set=$s get=$g" >> "$OUT/leak-probe.txt"
}

fixture_gate() {  # expect-sum
  local seed body
  seed="$(get http://dbbench-c1:8080/seed.php)"
  echo "   gate/seed        : $seed"
  body="$(get http://dbbench-c1:8080/db.php)"
  echo "   gate/db.php      : $body"
  case "$body" in *'"sum":55'*) return 0;; *) echo "   !! FIXTURE WRONG -- lane invalid"; return 1;; esac
}

# ---------------------------------------------------------------- lanes
run_lane() {  # lane cfg fixturedir upstream_verifier leakprobe logpats... -- envs...
  local lane="$1" cfg="$2" fixtures="$3" verifier="$4" doleak="$5"; shift 5
  local pats=() envs=() seen=0
  for a in "$@"; do
    if [ "$a" = "--" ]; then seen=1; continue; fi
    if [ $seen -eq 0 ]; then pats+=("$a"); else envs+=("$a"); fi
  done

  banner "$lane"
  echo "   cfg=$cfg fixtures=$fixtures"
  start_node "$cfg" "$fixtures" "${envs[@]}"
  if ! wait_ready; then
    echo "   !! never became ready:"; podman logs dbbench-c1 2>&1 | tail -40
    podman logs dbbench-c1 2>&1 | sed "s/[[0-9;]*m//g" > "$LOGS/$lane.log"
    return 1
  fi
  check_log "$lane" "${pats[@]}" || { echo "   !! LANE INVALID (config did not take effect)"; return 1; }
  fixture_gate || return 1
  if [ -n "$verifier" ]; then $verifier || { echo "   !! LANE INVALID (upstream did not receive the rows)"; return 1; }; fi
  # The session-leak probe runs AFTER measuring, never before. Running it
  # first poisons the connection pool (see the pool-poisoning finding in
  # docs/ephpm-0.6.0-db-matrix.md) and every measured cell in the lane
  # then returns HTTP 500 -- at 876 requests per second, which reads as an
  # excellent result right up until you count response statuses.
  measure "$lane" db.php
  measure "$lane" write.php
  [ "$doleak" = leak ] && leak_probe "$lane"
  cleanup
}

MYP='MySQL proxy listening'
PGP='PostgreSQL proxy listening'
LW='SQLite MySQL wire protocol enabled'

# The litewire sidecar used by A2/B2/C2 (and its turso twin for J2). It is
# up and listening BEFORE the proxy node starts, which is the only way the
# proxy can ever reach litewire -- see FINDING-startup-order.md.
start_lw_node() {  # cfg
  podman rm -f dbbench-lw >/dev/null 2>&1 || true
  podman volume rm -f dbv-lw >/dev/null 2>&1 || true
  podman volume create dbv-lw >/dev/null
  podman run -d --name dbbench-lw --network "$NET" --cpus "$CPUS" \
    -v "$HERE/fixtures/sqlite:/var/www/html:ro" \
    -v "$HERE/configs/$1:/etc/ephpm/ephpm.toml:ro" \
    -v "dbv-lw:/data" "$IMG" >/dev/null
  for _ in $(seq 1 60); do
    podman logs dbbench-lw 2>&1 | "$G" -q "MySQL frontend listening" && { echo "   litewire sidecar ready ($1)"; return 0; }
    sleep 1
  done
  echo "   !! litewire sidecar never listened"; podman logs dbbench-lw 2>&1 | tail -20; return 1
}
stop_lw_node() { podman rm -f dbbench-lw >/dev/null 2>&1 || true; }

# ---------------------------------------------------------------- STEP 0
# Reproduce and archive the in-process chaining failure. This is a gate in
# its own right: it proves lanes B2/C2 had to change topology, rather than
# leaving that as an assertion in prose.
echo "############ STEP 0: in-process chain repro ############"
start_node proxy-litewire-inprocess-BROKEN.toml sqlite
echo "   waiting out the proxy's 10-attempt backoff (~45s)..."
for _ in $(seq 1 60); do
  podman logs dbbench-c1 2>&1 | "$G" -q "failed to start MySQL proxy" && break
  sleep 1
done
podman logs dbbench-c1 > "$OUT/FINDING-startup-order.log" 2>&1
"$G" -E "failed to start MySQL proxy|SQLite MySQL wire protocol enabled|backend connect failed" \
  "$OUT/FINDING-startup-order.log" | head -4
echo "   db.php on the chained config: $(get http://dbbench-c1:8080/db.php)"
cleanup

# ---------------------------------------------------------------- lanes
run_lane A-lite-inproc        single-sqlite.toml           sqlite       ""                    noleak "$LW" 'listen=127.0.0.1:3306'

start_lw_node litewire-sidecar-sqlite.toml || exit 1
run_lane A2-lite-remote       proxy-none-direct.toml             sqlite       ""                    noleak "!$MYP" "!$PGP" "!$LW" -- \
         DB_HOST=dbbench-lw DB_PORT=3306
run_lane B2-lite-proxy-pool   proxy-litewire-pool.toml   sqlite    ""                    leak   "$MYP" '!SQLite MySQL wire'
run_lane C2-lite-proxy-nopool proxy-litewire-nopool.toml sqlite    ""                    leak   "$MYP" '!SQLite MySQL wire'
stop_lw_node

run_lane D-mysql-proxy-pool   proxy-mysql-pool.toml   mysql verify_mysql_upstream leak   "$MYP"
run_lane E-mysql-proxy-nopool proxy-mysql-nopool.toml mysql verify_mysql_upstream leak   "$MYP"
run_lane F-pg-proxy-pool      proxy-postgres-pool.toml      postgres    verify_pg_upstream    noleak "$PGP"
run_lane G-pg-proxy-nopool    proxy-postgres-nopool.toml    postgres    verify_pg_upstream    noleak "$PGP"
run_lane H-mysql-direct       proxy-none-direct.toml             mysql verify_mysql_upstream noleak "!$MYP" "!$PGP" "!$LW" -- \
         DB_HOST=dbbench-mysql DB_PORT=3306 DB_NAME=bench DB_USER=root DB_PASSWORD=
run_lane I-pg-direct          proxy-none-direct.toml             postgres    verify_pg_upstream    noleak "!$MYP" "!$PGP" "!$LW" -- \
         DB_HOST=dbbench-pg DB_PORT=5432 DB_NAME=bench DB_USER=postgres DB_PASSWORD=bench

start_lw_node litewire-sidecar-turso.toml && {
  run_lane J2-turso-proxy-pool proxy-litewire-pool.toml sqlite     ""                    leak   "$MYP"
  stop_lw_node
}

# PG session-pinning cliff probe: pool ON at the SHIPPED default cap of 20
# backend connections, swept past it. A pinned-session proxy with a cap of
# 20 cannot serve 24 concurrent PHP requests without queueing on
# pool_timeout, so this is where the cliff would show if it exists.
banner "F24-pg-cliff (max_connections = 20, shipped default)"
start_node proxy-postgres-pool-default20.toml postgres
if wait_ready; then
  check_log F24-pg-cliff "$PGP"
  fixture_gate && {
    measure F24-pg-cliff db.php    "16 20 24 32"
    measure F24-pg-cliff write.php "16 24"
  }
fi
cleanup

echo ""
echo "=== all lanes done; raw output in $OUT ==="
