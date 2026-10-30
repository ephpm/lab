#!/usr/bin/env bash
# stress-persite-restart.sh -- per-site CLUSTERED crash/rolling-restart
# write-loss stress (ePHPm #654, RC finding R1).
#
# This is the in-repo home for the release gate that #659 left open. The
# unit tests in ephpm (site_version, turso_cdc, sql_forward,
# per_site_graceful_leave) prove the ranking/adoption PRIMITIVES and the
# graceful-leave path, but nothing in the ephpm repo exercises the
# end-to-end crash-restart TIMING on a live multi-node cluster. That is
# what this does, and because it is committed here it no longer depends
# on throwaway infra that gets torn down between releases.
#
# ---------------------------------------------------------------------------
# THE BUG THIS REPRODUCES (#654, failure mode 1)
#
# In per-site clustered mode a site's owner is chosen by rendezvous
# hashing (HRW) over the ALIVE nodes. When the owner A of site $SITE dies,
# an interim owner B is elected, accepts and ACKNOWLEDGES writes, and
# captures them into its per-site CDC log. When A comes back it is the
# highest-HRW node for $SITE again and reclaims ownership.
#
# Before #659, A had no durable record that B's stint out-ranked its own:
# the per-stint change_id head resets each stint and cannot order across
# stints, and the only cross-stint signal -- B's gossip SiteVersion
# advertisement -- is short-lived (SITE_VERSION_TTL ~10s) and has lapsed
# by the time A returns (~24-40s after the kill). So A trusted its own
# STALE copy, re-served it as owner, and every write B had acknowledged
# in between was silently discarded -- permanently, once a third node
# re-bootstrapped from A. Every health check stayed green throughout.
#
# #659 carries the ownership epoch DURABLY on both replication channels
# (Frame::Hello and SnapshotHeader) and adopts it max(local,received) on
# CDC-tail and snapshot-install, so a returning owner descends from the
# stint its data actually came from and never out-ranks the interim
# owner's acknowledged writes with a stale copy.
#
# ---------------------------------------------------------------------------
# WHAT THIS ASSERTS -- permanent, cluster-wide, zero acknowledged-write loss.
#
# The source of truth is the number of writes the CLUSTER ACKNOWLEDGED:
# every write.php that returns {"status":"ok"} inserted exactly one row
# into the append-only `wbench` table and told the client so. A correct
# system never loses an acknowledged write. So after the kill/return
# cycle has fully converged, the LOCAL `wbench` count on EVERY node
# (read over stock pdo_mysql, which is NOT forwarded -- see count.php)
# must equal the total number of acknowledged writes. A node that is
# short lost acknowledged data; if the whole cluster is short, the data
# is gone for good. Either is a release blocker.
#
# This assertion is deliberately TIMING-TOLERANT: it detects PERMANENT
# loss, which is the actual harm, rather than trying to catch the
# millisecond-wide advert-lapse race. RETURN_DELAY still holds A down
# long enough for B's advert to lapse (making the pre-#659 loss the
# likely outcome, not a coin-flip), but the pass/fail does not hinge on
# hitting that window -- a build that loses the writes loses them for
# good and the final counts show it.
#
# ---------------------------------------------------------------------------
# HOW TO READ THE RESULT
#
#   PASS  -- every node's final wbench count == total acknowledged writes.
#            The returning owner adopted the interim owner's epoch and
#            data; nothing acknowledged was lost.
#   FAIL  -- at least one node is short after the convergence deadline.
#            Capture the per-node counts printed above the verdict; the
#            short node(s) tell you where the data went.
#   SKIP-WITH-REASON (also exit 1) -- the scenario could not be set up or
#            the handover never happened (no interim owner emerged, or the
#            interim owner never acknowledged a write). This is NOT a pass:
#            the gate did not run, and the reason is printed. Do not tag a
#            release on a run that did not reach the verdict.
#
# ---------------------------------------------------------------------------
# IMAGES
#
#   EPHPM_IMAGE   the image under test. There is no default on purpose:
#                 a crash-restart gate run against the wrong build is
#                 worse than no run. Point it explicitly, e.g.
#                   EPHPM_IMAGE=ephpm:v0.13.3-rc        ./db/stress-persite-restart.sh
#                   EPHPM_IMAGE=docker.io/ephpm/ephpm:v0.13.2-php8.5 \
#                                                        ./db/stress-persite-restart.sh
#                 v0.13.2 is the last PRE-#659 published image and should
#                 FAIL this stress -- run it first to confirm the harness
#                 has teeth, then run the fix image and expect PASS.
#
# NOTE ON grep: like bench-cluster.sh this runs under Git Bash on Windows,
# where the default `grep` on PATH swallows flags. Every filter uses
# /usr/bin/grep ($G) explicitly; counts are parsed with pure bash so a
# grep bug can never silently fabricate a number.
set -uo pipefail

IMG="${EPHPM_IMAGE:-}"
if [ -z "$IMG" ]; then
  echo "!! EPHPM_IMAGE is required (no default). Example:" >&2
  echo "!!   EPHPM_IMAGE=ephpm:v0.13.3-rc $0" >&2
  exit 2
fi

OHA_UNUSED=                     # (this suite drives writes with curl, not oha)
CURL=docker.io/curlimages/curl:latest
NET=dbcluster-net               # same network+subnet the configs bake in
SUBNET=10.89.7.0/24
IP_PREFIX=10.89.7.1             # nodes are ${IP_PREFIX}1 .. ${IP_PREFIX}3
SITE=t1                         # the one vhost under test
# On a multi-site node /metrics is REFUSED without a credential (every
# tenant's PHP can reach loopback, so an IP ACL cannot keep tenants out).
# The persite-restart-n*.toml configs set this token; ownership detection
# sends it as `Authorization: Bearer`. Bench-only, not a secret.
METRICS_TOKEN="${METRICS_TOKEN:-metrics-stress-token-0000}"
CPUS="${CPUS:-1}"
G=/usr/bin/grep
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/results-restart"
mkdir -p "$OUT"
LOG="$OUT/run-$(date +%Y%m%d-%H%M%S).log"

# ---- tunables -------------------------------------------------------------
BASE_WRITES="${BASE_WRITES:-40}"       # acknowledged writes before the kill
INTERIM_WRITES="${INTERIM_WRITES:-40}" # acknowledged writes B must take while A is dead
RETURN_DELAY="${RETURN_DELAY:-25}"     # seconds A stays down (> SITE_VERSION_TTL=10s)
HANDOVER_TIMEOUT="${HANDOVER_TIMEOUT:-120}"  # max wait for an interim owner + its acks
CONVERGE_TIMEOUT="${CONVERGE_TIMEOUT:-120}"  # max wait for all nodes to reach the target
ITERATIONS="${ITERATIONS:-1}"          # kill/return cycles (each kills the CURRENT owner)

# Containers/volumes are prefixed dbrr- so a leftover from this suite
# never collides with bench-cluster.sh's dbcl- nodes on the shared net.
NODES="1 2 3"
log() { echo "$@" | tee -a "$LOG"; }

cleanup_nodes() { for n in $NODES; do podman rm -f "dbrr-n$n" >/dev/null 2>&1 || true; done; }
cleanup_all() {
  # NO_CLEANUP=1 leaves the containers and volumes up for post-mortem
  # inspection (node logs, live DB state) after a failed or aborted run.
  if [ -n "${NO_CLEANUP:-}" ]; then
    echo "   NO_CLEANUP set: leaving dbrr-n* containers and dbrrv-n* volumes up for inspection" | tee -a "$LOG" 2>/dev/null || true
    return
  fi
  cleanup_nodes
  for n in $NODES; do podman volume rm -f "dbrrv-n$n" >/dev/null 2>&1 || true; done
  # leave the network; bench-cluster.sh and re-runs reuse it.
}
trap cleanup_all EXIT

# ---- helpers (adapted from bench-cluster.sh) ------------------------------

if ! podman network exists "$NET" 2>/dev/null; then
  podman network create --subnet "$SUBNET" "$NET" >/dev/null || {
    log "!! could not create network $NET with subnet $SUBNET (is it in use?)"; exit 2; }
fi
podman image exists "$CURL" 2>/dev/null || podman pull -q "$CURL" >/dev/null

# get <node> <path> [host]
get() {
  local n="$1" path="$2" host="${3:-}"
  if [ -n "$host" ]; then
    podman run --rm --network "$NET" "$CURL" -s --max-time 25 \
      -H "Host: $host" "http://${IP_PREFIX}${n}:8080/$path" 2>/dev/null
  else
    podman run --rm --network "$NET" "$CURL" -s --max-time 25 \
      "http://${IP_PREFIX}${n}:8080/$path" 2>/dev/null
  fi
}

# start_node <n> -- always multi-tenant here (per-site clustered).
start_node() {
  local n="$1"
  podman volume rm -f "dbrrv-n$n" >/dev/null 2>&1 || true
  podman volume create "dbrrv-n$n" >/dev/null
  podman run -d --name "dbrr-n$n" --network "$NET" --ip "${IP_PREFIX}${n}" --cpus "$CPUS" \
    -v "$HERE/fixtures/cluster:/var/www/html:ro" \
    -v "$HERE/fixtures/cluster:/var/www/sites/$SITE:ro" \
    -v "$HERE/configs/persite-restart-n$n.toml:/etc/ephpm/ephpm.toml:ro" \
    -v "dbrrv-n$n:/data" \
    "$IMG" >/dev/null
}

# restart_node <n> -- bring a KILLED node back on the SAME volume (its
# stale data survives), re-attached to its static IP. This is "the owner
# returns", the moment #654 is about.
restart_node() {
  local n="$1"
  podman start "dbrr-n$n" >/dev/null 2>&1 \
    || podman run -d --name "dbrr-n$n" --network "$NET" --ip "${IP_PREFIX}${n}" --cpus "$CPUS" \
         -v "$HERE/fixtures/cluster:/var/www/html:ro" \
         -v "$HERE/fixtures/cluster:/var/www/sites/$SITE:ro" \
         -v "$HERE/configs/persite-restart-n$n.toml:/etc/ephpm/ephpm.toml:ro" \
         -v "dbrrv-n$n:/data" \
         "$IMG" >/dev/null
}

wait_ready() {
  local n="$1"
  for _ in $(seq 1 90); do
    case "$(get "$n" "_ephpm/health")" in ?*) return 0 ;; esac
    sleep 1
  done
  return 1
}

mode_gate() {
  local n="$1"
  if podman logs "dbrr-n$n" 2>&1 | $G -qF "per-site CLUSTERED database isolation enabled"; then
    return 0
  fi
  log "!! MODE GATE FAILED on n$n: image is not running per-site clustered mode."
  log "!! (needs ephpm#416, first in v0.8.6). Startup lines mentioning the mode:"
  podman logs "dbrr-n$n" 2>&1 | $G -iE "per-site|clustered|replication|engine" | head -6 | tee -a "$LOG"
  return 1
}

# metrics_raw <node> -- GET /metrics with the bearer token (multi-site nodes
# refuse it otherwise).
metrics_raw() {
  podman run --rm --network "$NET" "$CURL" -s --max-time 25 \
    -H "Authorization: Bearer $METRICS_TOKEN" "http://${IP_PREFIX}${1}:8080/metrics" 2>/dev/null
}

cdc_subscribers() {
  local n="$1" v
  # v0.13.x labels this per-site: `ephpm_cdc_subscribers{site="t1"} N`. Older
  # images emit the unlabelled `ephpm_cdc_subscribers N`. Match both; the
  # value is always the last whitespace-separated field.
  v="$(metrics_raw "$n" | $G -E '^ephpm_cdc_subscribers[ {]' | head -1 | awk '{print $NF}')"
  case "$v" in ''|*[!0-9.]*) echo 0 ;; *) echo "${v%%.*}" ;; esac
}
elected_primary() { podman logs "dbrr-n$1" 2>&1 | $G -qF "elected as SQLite primary"; }

# count_local <node> -- LOCAL wbench row count via stock pdo_mysql (not
# forwarded), as an integer, or -1 if the node did not answer a number.
count_local() {
  local b; b="$(get "$1" "count.php?t=wbench" "$SITE")"
  case "$b" in
    *'"count":'*) b="${b##*\"count\":}"; b="${b%%[!0-9]*}"; echo "${b:-0}" ;;
    *) echo -1 ;;
  esac
}

# ack_write <node> -- issue one bridge write; echo 1 if acknowledged.
ack_write() {
  case "$(get "$1" write.php "$SITE")" in *'"status":"ok"'*) echo 1 ;; *) echo 0 ;; esac
}

# owner_of -- which live node currently owns $SITE (cdc subscribers + an
# election claim). Echoes the node number, or "" if not exactly one. $1 is
# a space-separated list of candidate node numbers (the live ones).
owner_of() {
  local cands="$1" owner="" n
  for n in $cands; do
    if [ "$(cdc_subscribers "$n")" -gt 0 ] && elected_primary "$n"; then owner="${owner}${n}"; fi
  done
  [ "${#owner}" = 1 ] && echo "$owner" || echo ""
}

# wait_owner <candidates> -- poll up to 60s for exactly one owner.
wait_owner() {
  local cands="$1" o=""
  for _ in $(seq 1 30); do o="$(owner_of "$cands")"; [ -n "$o" ] && { echo "$o"; return 0; }; sleep 2; done
  echo ""; return 1
}

FAIL=0
fail()  { log "!! $*"; FAIL=1; }
abort() { log ""; log "=== STRESS ABORTED (did NOT reach a verdict): $* ==="; log "=== full log: $LOG ==="; exit 1; }

# ===========================================================================
log "############ per-site clustered crash-restart stress ############"
log "image=$IMG site=$SITE base=$BASE_WRITES interim=$INTERIM_WRITES return_delay=${RETURN_DELAY}s iterations=$ITERATIONS"
log "log: $LOG"

cleanup_nodes
log "-- starting 3-node per-site clustered cluster --"
start_node 1; sleep 4; start_node 2; start_node 3
for n in $NODES; do wait_ready "$n" || { podman logs "dbrr-n$n" 2>&1 | tail -30 | tee -a "$LOG"; abort "n$n never became ready"; }; done
for n in $NODES; do mode_gate "$n" || abort "mode gate failed on n$n (wrong image or mode)"; done

# Seed FIRST (this is what opens the site and starts the replica drivers that
# owner detection below keys on). seed.php forwards through the bridge to the
# site's HRW owner, and that forwarding is not ready the instant the HTTP
# health check passes, so RETRY until it takes rather than aborting on the
# first miss (the cause of the intermittent "seed did not return sum:55"
# aborts). seed.php is DROP-first, so each retry resets to an identical table.
log "-- seeding through the bridge --"
seed_resp=""; for _ in $(seq 1 20); do
  seed_resp="$(get 1 seed.php "$SITE")"
  case "$seed_resp" in *'"sum":55'*) break;; esac
  sleep 2
done
case "$seed_resp" in *'"sum":55'*) log "   seed ok (sum:55)";; *) abort "seed did not return sum:55 (got: $seed_resp)";; esac

log "-- opening the site locally on every node (starts replica drivers) --"
for n in $NODES; do log "   n$n: $(get "$n" "count.php?t=bench" "$SITE")"; done

log "-- waiting for exactly one owner --"
owner="$(wait_owner "$NODES")" || { for n in $NODES; do log "   n$n: subs=$(cdc_subscribers "$n") elected=$(elected_primary "$n" && echo yes || echo no)"; done; abort "no single owner settled"; }
log "   initial OWNER = n$owner"

log "-- replication proof (owner -> a non-owner) --"
nonowner=""; for n in $NODES; do [ "$n" != "$owner" ] && nonowner="$n" && break; done
for _ in $(seq 1 45); do
  w="$(count_local "$nonowner")"; a="$(count_local "$owner")"
  [ "$w" -ge 0 ] && [ "$a" -ge 0 ] && [ "$w" = "$a" ] && { log "   REPLICATION VERIFIED n$owner -> n$nonowner (wbench=$w on both)"; break; }
  # drive a couple writes so there is something to converge on
  ack_write "$owner" >/dev/null; sleep 1
done

total_acked=0

# ---- one kill/return cycle ------------------------------------------------
cycle() {
  local iter="$1" live_before victim interim survivors
  live_before="$NODES"
  victim="$owner"
  survivors=""; for n in $NODES; do [ "$n" != "$victim" ] && survivors="$survivors $n"; done

  log ""
  log "######## cycle $iter: kill owner n$victim ########"

  # Baseline acknowledged writes (routed through a survivor so the client
  # survives the kill; the bridge forwards to the owner regardless).
  local drv; drv="$(echo $survivors | awk '{print $1}')"
  local i
  for i in $(seq 1 "$BASE_WRITES"); do total_acked=$(( total_acked + $(ack_write "$drv") )); done
  log "   baseline acknowledged writes: total_acked=$total_acked"

  # SIGKILL the owner -- no graceful drain, the crash case.
  podman kill -s KILL "dbrr-n$victim" >/dev/null 2>&1 || podman kill "dbrr-n$victim" >/dev/null 2>&1 || true
  log "   SIGKILLed n$victim at $(date +%T)"

  # The handover: a NEW owner must emerge among survivors and ACKNOWLEDGE
  # writes. If neither happens the scenario never exercised #654.
  interim="$(wait_owner "$survivors")" || abort "no interim owner emerged among survivors ($survivors) within handover window"
  log "   interim OWNER = n$interim"

  local got=0 deadline=$(( SECONDS + HANDOVER_TIMEOUT ))
  while [ "$got" -lt "$INTERIM_WRITES" ] && [ "$SECONDS" -lt "$deadline" ]; do
    local a; a="$(ack_write "$drv")"
    if [ "$a" = 1 ]; then got=$(( got + 1 )); total_acked=$(( total_acked + 1 )); else sleep 1; fi
  done
  [ "$got" -ge "$INTERIM_WRITES" ] || abort "interim owner n$interim only acknowledged $got/$INTERIM_WRITES writes before timeout"
  log "   interim owner acknowledged $got writes; total_acked=$total_acked"

  # Hold the victim down past SITE_VERSION_TTL (~10s) so a pre-#659 build
  # finds the interim advert lapsed when it returns -- the dangerous case.
  log "   holding n$victim down ${RETURN_DELAY}s (> SITE_VERSION_TTL) ..."
  sleep "$RETURN_DELAY"

  # The owner returns on its STALE volume and reclaims ownership by HRW.
  restart_node "$victim"
  wait_ready "$victim" || abort "returning owner n$victim never became ready"
  log "   n$victim returned at $(date +%T) (stale volume, reclaims ownership)"

  # Settle: wait for a single owner again across all three.
  owner="$(wait_owner "$NODES")" || { for n in $NODES; do log "   n$n: subs=$(cdc_subscribers "$n") elected=$(elected_primary "$n" && echo yes || echo no)"; done; abort "no single owner settled after n$victim returned"; }
  log "   post-return OWNER = n$owner"
}

iter=1
while [ "$iter" -le "$ITERATIONS" ]; do cycle "$iter"; iter=$(( iter + 1 )); done

# ---- VERDICT: every node must hold every acknowledged write ---------------
log ""
log "-- convergence: every node's local wbench count must reach total_acked=$total_acked --"
deadline=$(( SECONDS + CONVERGE_TIMEOUT )); allok=0
while [ "$SECONDS" -lt "$deadline" ]; do
  allok=1
  for n in $NODES; do [ "$(count_local "$n")" = "$total_acked" ] || { allok=0; break; }; done
  [ "$allok" = 1 ] && break
  sleep 2
done

log ""
log "-- final local wbench counts (target = $total_acked acknowledged writes) --"
for n in $NODES; do
  c="$(count_local "$n")"
  if [ "$c" = "$total_acked" ]; then log "   n$n: $c  OK"
  else log "   n$n: $c  SHORT by $(( total_acked - c ))  <-- lost acknowledged writes"; FAIL=1; fi
done

log ""
if [ "$FAIL" = 0 ]; then
  log "=== PASS: every node holds all $total_acked acknowledged writes. No crash-restart loss. ==="
  log "=== log: $LOG ==="
  exit 0
fi
log "=== FAIL: acknowledged writes were lost across the crash-restart (#654). ==="
log "=== This build must NOT be tagged. log: $LOG ==="
exit 1
