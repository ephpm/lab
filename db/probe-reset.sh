#!/usr/bin/env bash
# Mechanism probe for two pooled-proxy behaviours the matrix surfaced:
#
#  (1) Does the pool actually RECYCLE a connection after a WRITE, or does
#      the smart-reset path discard it every time? With
#      reset_strategy = "smart" (the default) a session that issued
#      anything but SELECT is "dirty", and on client disconnect the proxy
#      sends COM_RESET_CONNECTION before parking. If the backend does not
#      answer OK, pool.rs::recycle_with_reset logs
#          "pool reset failed, discarding connection"
#      at DEBUG -- invisible at the default log level -- and throws the
#      connection away. If that fires on every write, pooling delivers
#      nothing on the write path.
#
#  (2) The next-request poisoning. After one request whose session errors
#      or ends oddly, the FOLLOWING PHP request gets
#      "SQLSTATE[HY000] [2006] MySQL server has gone away". Observed
#      against BOTH litewire and real mysql:8, so it is not a litewire
#      quirk. pool.rs pings idle connections only on the
#      health_check_interval timer -- never at acquire() -- so a backend
#      that died while parked is handed to the next request as-is.
#
# Usage: ./probe-reset.sh lite|mysql
set -uo pipefail
G=/usr/bin/grep
NET=dbbench-net
CURL=docker.io/curlimages/curl:latest
IMG="${EPHPM_IMAGE:-docker.io/ephpm/ephpm:v0.6.0-php8.5}"
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/results-proxy"
TARGET="${1:-lite}"
mkdir -p "$OUT"

case "$TARGET" in
  lite)  CFG=configs/proxy-litewire-pool.toml; DOC=fixtures/sqlite ;;
  mysql) CFG=configs/proxy-mysql-pool.toml;    DOC=fixtures/mysql ;;
  *) echo "usage: $0 lite|mysql" >&2; exit 2 ;;
esac

get() { podman run --rm --network "$NET" "$CURL" -s --max-time 25 "$1" 2>/dev/null; }
cleanup() { podman rm -f probe-lw probe-px >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup

if [ "$TARGET" = lite ]; then
  podman volume rm -f probe-lw-v >/dev/null 2>&1 || true
  podman volume create probe-lw-v >/dev/null
  podman run -d --name probe-lw --network "$NET" --cpus 1 \
    -v "$HERE/fixtures/sqlite:/var/www/html:ro" \
    -v "$HERE/configs/litewire-sidecar-sqlite.toml:/etc/ephpm/ephpm.toml:ro" \
    -v probe-lw-v:/data "$IMG" >/dev/null
  for _ in $(seq 1 60); do
    podman logs probe-lw 2>&1 | "$G" -q "MySQL frontend listening" && break; sleep 1
  done
  # The proxy config names dbbench-lw; alias this probe's sidecar to it.
  podman network disconnect "$NET" probe-lw >/dev/null 2>&1
  podman network connect --alias dbbench-lw "$NET" probe-lw >/dev/null 2>&1
fi

podman run -d --name probe-px --network "$NET" --cpus 1 \
  -e RUST_LOG=info,ephpm_db=debug \
  -v "$HERE/$DOC:/var/www/html:ro" \
  -v "$HERE/$CFG:/etc/ephpm/ephpm.toml:ro" \
  "$IMG" >/dev/null
for _ in $(seq 1 60); do [ -n "$(get http://probe-px:8080/seed.php)" ] && break; sleep 1; done

snap() { podman logs probe-px 2>&1 | sed 's/\x1b\[[0-9;]*m//g' > "$1"; }

echo "== target=$TARGET  cfg=$CFG"
echo "== seed: $(get http://probe-px:8080/seed.php)"

echo ""
echo "== 10 READ requests (db.php -- pure SELECT, session stays clean) =="
for _ in $(seq 1 10); do get http://probe-px:8080/db.php >/dev/null; done
sleep 1; snap "$OUT/probe-$TARGET-after-reads.log"
echo "   pool reset failed : $("$G" -c 'pool reset failed'  "$OUT/probe-$TARGET-after-reads.log" || true)"
echo "   proxy session err : $("$G" -c 'proxy session error' "$OUT/probe-$TARGET-after-reads.log" || true)"

echo ""
echo "== 10 WRITE requests (write.php -- INSERT marks the session dirty) =="
for _ in $(seq 1 10); do get http://probe-px:8080/write.php >/dev/null; done
sleep 1; snap "$OUT/probe-$TARGET-after-writes.log"
rf=$("$G" -c 'pool reset failed' "$OUT/probe-$TARGET-after-writes.log" || true)
echo "   pool reset failed : $rf   (10 writes were just issued)"
"$G" 'pool reset failed' "$OUT/probe-$TARGET-after-writes.log" | tail -2

echo ""
echo "== poisoning sequence: one odd session, then three normal requests =="
echo "   set  : $(get 'http://probe-px:8080/leak.php?set=1')"
for i in 1 2 3; do echo "   db#$i : $(get 'http://probe-px:8080/db.php')"; done
sleep 1; snap "$OUT/probe-$TARGET-final.log"
echo "   proxy session err (cumulative): $("$G" -c 'proxy session error' "$OUT/probe-$TARGET-final.log" || true)"
"$G" 'proxy session error' "$OUT/probe-$TARGET-final.log" | tail -3

echo ""
echo "=== full debug log: $OUT/probe-$TARGET-final.log ==="
