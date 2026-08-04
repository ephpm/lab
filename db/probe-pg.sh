#!/usr/bin/env bash
# Why is the PostgreSQL proxy ~10x slower per statement than the MySQL one
# on the same fixture?
#
# Reading postgres.rs: needs_routing is
#     matches!(reset_strategy, Smart) || (rw_split && replicas)
# so with the SHIPPED default reset_strategy = "smart", PG always takes
# pg_proxy_routing_loop -- a pool acquire/return per protocol message --
# even with no replicas configured. MySQL's equivalent condition is
#     rw_split && !replica_pools.is_empty()
# so MySQL with the same default holds ONE backend for the whole client
# session. Same knob, opposite topology.
#
# The routing loop also pins the session to the primary the moment the
# client uses the extended query protocol (anything but a simple Query).
# pdo_pgsql prepares by default, so this probe checks whether the pin
# fires -- and therefore which of the two costs is actually being paid.
set -uo pipefail
G=/usr/bin/grep
NET=dbbench-net
CURL=docker.io/curlimages/curl:latest
IMG="${EPHPM_IMAGE:-docker.io/ephpm/ephpm:v0.6.0-php8.5}"
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/results-proxy"
get() { podman run --rm --network "$NET" "$CURL" -s --max-time 25 "$1" 2>/dev/null; }
cleanup() { podman rm -f probe-pg >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup

podman run -d --name probe-pg --network "$NET" --cpus 1 \
  -e RUST_LOG=info,ephpm_db=debug \
  -v "$HERE/fixtures/postgres:/var/www/html:ro" \
  -v "$HERE/configs/proxy-postgres-pool.toml:/etc/ephpm/ephpm.toml:ro" \
  "$IMG" >/dev/null
for _ in $(seq 1 60); do [ -n "$(get http://probe-pg:8080/seed.php)" ] && break; sleep 1; done
echo "seed: $(get http://probe-pg:8080/seed.php)"
for _ in $(seq 1 5); do get http://probe-pg:8080/db.php >/dev/null; done
sleep 1
podman logs probe-pg 2>&1 | sed 's/\x1b\[[0-9;]*m//g' > "$OUT/probe-pg.log"
echo "pinning-session lines : $("$G" -c 'pinning session to primary' "$OUT/probe-pg.log" || true)  (5 db.php requests issued)"
"$G" 'pinning session to primary' "$OUT/probe-pg.log" | head -2
echo "proxy session errors  : $("$G" -c 'proxy session error' "$OUT/probe-pg.log" || true)"
echo "log: $OUT/probe-pg.log"
