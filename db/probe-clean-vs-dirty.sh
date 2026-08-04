#!/usr/bin/env bash
# DECISIVE probe. Hypothesis from the code + every observation so far:
#
#   proxy_bidirectional_sniff() RELAYS the client's COM_QUIT to the pooled
#   backend (it excludes COM_QUIT only from the *dirty* classification,
#   not from forwarding), so the backend closes the connection when PHP's
#   PDO handle is destroyed at request end. What happens next depends
#   entirely on whether the session was dirty:
#
#     dirty  (any non-SELECT) -> return_with_reset() -> COM_RESET_CONNECTION
#                                fails "early eof" -> connection DISCARDED
#                                -> the pool self-heals.
#     clean  (SELECT only)    -> return_to_pool()   -> the DEAD socket is
#                                parked as a healthy idle slot. Pool::acquire()
#                                never pings, so the next request gets it and
#                                fails; that failure maps to Ok(..) in the
#                                sniffer's BrokenPipe arm, which RE-PARKS it.
#
#   Prediction: read-only requests poison the pool after roughly
#   min_connections successes; write requests never do.
#
# This probe issues 20 sequential reads, then 20 sequential writes, then
# 20 more reads, counting failures in each phase. It is the difference
# between the two phases that identifies the mechanism.
set -uo pipefail
G=/usr/bin/grep
NET=dbbench-net
CURL=docker.io/curlimages/curl:latest
IMG="${EPHPM_IMAGE:-docker.io/ephpm/ephpm:v0.6.0-php8.5}"
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/results-proxy"
get() { podman run --rm --network "$NET" "$CURL" -s --max-time 20 "$1" 2>/dev/null; }
cleanup() { podman rm -f pcd-lw pcd-px >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup

podman volume rm -f pcd-v >/dev/null 2>&1 || true; podman volume create pcd-v >/dev/null
podman run -d --name pcd-lw --network "$NET" --cpus 1 \
  -v "$HERE/fixtures/sqlite:/var/www/html:ro" -v "$HERE/configs/litewire-sidecar-sqlite.toml:/etc/ephpm/ephpm.toml:ro" \
  -v pcd-v:/data "$IMG" >/dev/null
for _ in $(seq 1 60); do podman logs pcd-lw 2>&1 | "$G" -q "MySQL frontend listening" && break; sleep 1; done
podman network disconnect "$NET" pcd-lw >/dev/null 2>&1
podman network connect --alias dbbench-lw "$NET" pcd-lw >/dev/null 2>&1

podman run -d --name pcd-px --network "$NET" --cpus 1 -e RUST_LOG=info,ephpm_db=debug \
  -v "$HERE/fixtures/sqlite:/var/www/html:ro" \
  -v "$HERE/configs/proxy-litewire-pool.toml:/etc/ephpm/ephpm.toml:ro" "$IMG" >/dev/null
for _ in $(seq 1 60); do [ -n "$(get http://pcd-px:8080/seed.php)" ] && break; sleep 1; done
echo "seed: $(get http://pcd-px:8080/seed.php)"
echo "(min_connections = 4 warm backends in the pool)"

phase() {  # label fixture expect
  local label="$1" fx="$2" expect="$3" ok=0 bad=0 first_bad=0 i=0 body
  for i in $(seq 1 20); do
    body="$(get "http://pcd-px:8080/$fx")"
    case "$body" in
      *"$expect"*) ok=$((ok+1)) ;;
      *) bad=$((bad+1)); [ $first_bad -eq 0 ] && first_bad=$i ;;
    esac
  done
  printf '%-28s ok=%-3s failed=%-3s first failure at request #%s\n' \
    "$label" "$ok" "$bad" "${first_bad:-none}"
}

phase "20 READS  (clean sessions)"  db.php    '"sum":55'
phase "20 WRITES (dirty sessions)"  write.php '"affected":1'
phase "20 READS  again"             db.php    '"sum":55'
podman logs pcd-px 2>&1 | sed 's/\x1b\[[0-9;]*m//g' > "$OUT/probe-clean-vs-dirty.log"
echo "pool reset failed lines: $("$G" -c 'pool reset failed' "$OUT/probe-clean-vs-dirty.log" || true)"
