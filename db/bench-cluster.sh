#!/usr/bin/env bash
# Turso single vs Turso CDC-clustered, whole-database and per-vhost.
#
# This is the replacement DB-BENCH.md promised when it marked the
# `engines` and `admission` suites historical: those lanes benchmark the
# rusqlite engine and the sqld sidecar, both removed in v0.7.0, and they
# are kept pinned to v0.6.3 as the record rather than edited. This suite
# asks the same questions of the machinery that actually ships.
#
#   S   turso   single-site,  single node      Turso, no cluster at all
#   W   turso   single-site,  clustered        one DB, CDC to a replica,
#                                              measured on the PRIMARY
#   P1  turso   multi-tenant, single node      one DB per vhost (the
#                                              v0.7.0+ multi-tenant default)
#   P2  turso   multi-tenant, clustered        one REPLICATED DB per vhost,
#                                              measured on the site's OWNER
#   P3  turso   multi-tenant, clustered        the same cluster, the same
#                                              site, measured on a node that
#                                              does NOT own it
#
# The pair that matters is P2 vs P3. In per-site clustered mode ownership
# of a vhost is decided by rendezvous hashing (HRW) over the alive nodes,
# and every node accepts reads and writes for every site: a non-owner
# forwards each ephpm_db_* statement to the owner over sql/<site>. P3
# minus P2 is the cost of that forward hop, on both the read and the
# write path. P1 is what the whole thing costs relative to not
# clustering, and S ties the matrix back to the historical `bridge`
# suite's B-turso lane.
#
# WHY THE LANES ARE NOT ALL COMPARABLE TO EACH OTHER. S and W are
# single-site; P1, P2 and P3 are multi-tenant. Read S->W as "what does
# clustering cost", P1->P2 as "what does clustering cost a tenant", and
# P2->P3 as "what does not owning the tenant cost". Reading S against P1
# compares two different deployment shapes and is not a measurement of
# anything.
#
# NOTE ON grep: this runs under Git Bash on Windows, where the default
# `grep` on PATH swallows -E/-i and prints the flag instead of filtering.
# Every filter here uses /usr/bin/grep explicitly. Raw oha output is kept
# in results-cluster/ regardless, so a filtering bug can never silently
# discard a measurement.
set -uo pipefail

# All five lanes run on the default image. Lanes P2 and P3 need per-site
# CLUSTERED replication (ephpm#416), which first appears in the v0.8.6
# tag; the v0.8.6/v0.8.7 images were published 2026-09-01, so any v0.8.6+
# image carries it and the default below tracks the newest published line.
# On an older image
# the mode gate refuses those two lanes with a message saying so, which
# is the entire reason the gate exists (see "GATES" below).
# EPHPM_PERSITE_CLUSTER_IMAGE still points P2/P3 at a different build
# than S/W/P1 when you need to.
IMG="${EPHPM_IMAGE:-docker.io/ephpm/ephpm:v0.10.8-php8.5}"
PS_IMG="${EPHPM_PERSITE_CLUSTER_IMAGE:-$IMG}"

OHA=ghcr.io/hatoo/oha:latest
CURL=docker.io/curlimages/curl:latest
NET=dbcluster-net
SUBNET=10.89.7.0/24
IP_PREFIX=10.89.7.1          # nodes are ${IP_PREFIX}1 .. ${IP_PREFIX}3
SITE=t1                      # the one vhost the per-site lanes measure
CPUS=1
DUR="${DUR:-15s}"
REPS="${REPS:-2}"
WARMUP="${WARMUP:-8s}"
G=/usr/bin/grep
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/results-cluster"
mkdir -p "$OUT"

# A dedicated network with an EXPLICIT subnet, not the shared
# `dbbench-net` the other suites use. The clustered configs name exact
# IPs (clustered replication fails closed on an unspecified bind address,
# because it would have nothing dialable to advertise), and the other
# suites' configs assume whatever subnet podman happened to hand
# `dbbench-net`. Declaring the subnet makes that assumption a fact.
if ! podman network exists "$NET" 2>/dev/null; then
  podman network create --subnet "$SUBNET" "$NET" >/dev/null || {
    echo "!! could not create network $NET with subnet $SUBNET (is it in use?)" >&2
    exit 2
  }
fi
podman image exists "$CURL" 2>/dev/null || podman pull -q "$CURL" >/dev/null

NODES="1 2 3"
cleanup_nodes() {
  for n in $NODES; do podman rm -f "dbcl-n$n" >/dev/null 2>&1 || true; done
}
cleanup_all() {
  cleanup_nodes
  for n in $NODES; do podman volume rm -f "dbclv-n$n" >/dev/null 2>&1 || true; done
  podman network rm "$NET" >/dev/null 2>&1 || true
}
trap cleanup_all EXIT

# ---------------------------------------------------------------- helpers

# get <node> <path> [host]  -- HTTP GET, optionally with an explicit Host.
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

# start_node <n> <config> <image> <multi-tenant?>
#
# The fixture directory is mounted at /var/www/html on every node so the
# default document root exists, and additionally at
# /var/www/sites/$SITE on the multi-tenant nodes. Mounting it in both
# places is deliberate: a request that arrives WITHOUT the vhost's Host
# header then reaches the same PHP files with no per-site database
# context and fails loudly ("no per-site database context for this
# request"), instead of 404ing in a way that could be mistaken for a
# routing typo. That negative control is asserted in gate 2b.
start_node() {
  local n="$1" cfg="$2" image="$3" multi="$4"
  local mounts=(-v "$HERE/fixtures/cluster:/var/www/html:ro")
  [ "$multi" = yes ] && mounts+=(-v "$HERE/fixtures/cluster:/var/www/sites/$SITE:ro")
  podman volume rm -f "dbclv-n$n" >/dev/null 2>&1 || true
  podman volume create "dbclv-n$n" >/dev/null
  podman run -d --name "dbcl-n$n" --network "$NET" --ip "${IP_PREFIX}${n}" --cpus "$CPUS" \
    "${mounts[@]}" \
    -v "$HERE/configs/$cfg:/etc/ephpm/ephpm.toml:ro" \
    -v "dbclv-n$n:/data" \
    "$image" >/dev/null
}

# Readiness is /_ephpm/health, NOT the seeder. Probing a seeder in a
# readiness loop re-runs its DDL every second while the cluster is still
# forming, which on a clustered lane means racing CREATE/DROP against a
# bootstrap.
wait_ready() {
  local n="$1"
  for _ in $(seq 1 90); do
    case "$(get "$n" "_ephpm/health")" in ?*) return 0 ;; esac
    sleep 1
  done
  return 1
}

# mode_gate <node> <expected startup log substring> <label>
#
# GATE 1, and the most important one in this suite. Four different
# database modes are selected by a CONJUNCTION of keys spread across
# [server], [db.sqlite], [db.sqlite.replication] and [cluster], and
# ephpm-config does not reject unknown fields. An image that predates a
# knob parses it, ignores it, and starts happily in a DIFFERENT mode --
# which then benchmarks perfectly well under the wrong label. This is not
# hypothetical: the first run of this suite pointed the per-site
# clustered lanes at the newest PUBLISHED image and got a healthy,
# fast, fully-2xx cluster that was running whole-database clustered mode,
# because `per_site` does not exist in that image. Only the log said so.
mode_gate() {
  local n="$1" want="$2" label="$3"
  if podman logs "dbcl-n$n" 2>&1 | $G -qF "$want"; then
    echo "   mode gate n$n: OK ($label)"
    return 0
  fi
  echo "!! MODE GATE FAILED on n$n: expected the startup log to contain:"
  echo "!!   $want"
  echo "!! This image is not running the mode this lane claims to measure."
  echo "!! Startup lines that mention the database mode:"
  podman logs "dbcl-n$n" 2>&1 | $G -iE "per-site|clustered|replication|engine" \
    | $G -viE "multi-tenant hardening|opcache|autotune" | head -6
  return 1
}

# gate <node> <description> <path> <expected substring> [host]
gate() {
  local n="$1" desc="$2" path="$3" want="$4" host="${5:-}" body
  body="$(get "$n" "$path" "$host")"
  echo "   $desc: $body"
  case "$body" in
    *"$want"*) return 0 ;;
    *) echo "!! GATE FAILED ($desc wanted $want) -- lane invalid"; return 1 ;;
  esac
}

# cdc_subscribers <node> -- attached CDC subscribers, or 0.
#
# This is the external, numeric answer to "is this node the one serving
# replication". On the whole-database lane the primary has subscribers
# and the replica has none. On the per-site lanes the gauge is
# process-global rather than per-site, which is exactly why this suite
# measures ONE vhost: with a single site in the cluster, "this node has
# subscribers" and "this node owns the site" are the same statement.
cdc_subscribers() {
  local n="$1" v
  v="$(get "$n" metrics | $G -E '^ephpm_cdc_subscribers ' | head -1 | awk '{print $2}')"
  case "$v" in ''|*[!0-9.]*) echo 0 ;; *) echo "${v%%.*}" ;; esac
}

# elected_primary <node> -- did this node's election ever claim primary?
elected_primary() {
  podman logs "dbcl-n$1" 2>&1 | $G -qF "elected as SQLite primary"
}

# measure <lane> <cell> <node> <path> [host]
measure() {
  local lane="$1" cell="$2" n="$3" path="$4" host="${5:-}"
  local hdr=()
  [ -n "$host" ] && hdr=(-H "Host: $host")
  local url="http://${IP_PREFIX}${n}:8080/$path"
  for conc in 1 16; do
    podman run --rm --network "$NET" "$OHA" -z "$WARMUP" -c "$conc" --no-tui \
      "${hdr[@]}" "$url" >/dev/null 2>&1
    for rep in $(seq 1 "$REPS"); do
      local f="$OUT/${lane}-${cell}-c${conc}-r${rep}.txt"
      podman run --rm --network "$NET" "$OHA" -z "$DUR" -c "$conc" --no-tui \
        "${hdr[@]}" "$url" > "$f" 2>&1
      printf '%-18s %-13s c=%-3s r=%s  ' "$lane" "$cell" "$conc" "$rep"
      $G -E "Requests/sec" "$f" | head -1 | tr -s ' '
    done
  done
}

banner() { echo ""; echo "############ LANE $1 ############"; }

# converge <writer-node> <observer-node> <rows> [host]
#
# GATE 4. Write through the BRIDGE on the writer, then poll the
# observer's LOCAL database over stock pdo_mysql until it agrees.
#
# The two paths are not interchangeable and picking the wrong one makes
# the gate vacuous. In per-site clustered mode the bridge on a non-owner
# FORWARDS to the site's owner, so a bridge-side count would read the
# owner's database from every node and would agree with itself even if
# replication were completely dead. Stock pdo_mysql is not forwarded --
# it resolves the node's own file -- so it is the only one of the two
# that can observe a replica.
converge() {
  local w="$1" o="$2" want="$3" host="${4:-}" r=""
  for _ in $(seq 1 "$want"); do get "$w" write.php "$host" >/dev/null; done
  for _ in $(seq 1 45); do
    r="$(get "$o" "count.php?t=wbench" "$host")"
    case "$r" in *"\"count\":$want"*) echo "   REPLICATION VERIFIED n$w -> n$o: $r"; return 0 ;; esac
    sleep 1
  done
  echo "   !! REPLICATION DID NOT CONVERGE n$w -> n$o (last: $r)"
  echo "   !! Numbers from this lane measure an effectively standalone"
  echo "   !! server and must NOT be compared with anything."
  return 1
}

FAILED=0

# =====================================================================
# Lane S -- Turso, single site, single node. No cluster.
# =====================================================================
lane_s() {
  local lane=S-turso-single
  banner "$lane (single-turso.toml, 1 node, --cpus $CPUS)"
  cleanup_nodes
  start_node 1 single-turso.toml "$IMG" no
  wait_ready 1 || { echo "!! n1 never became ready:"; podman logs dbcl-n1 2>&1 | tail -30; return 1; }
  mode_gate 1 "opened embedded database (single-node, Turso engine)" "single-node Turso" || return 1
  gate 1 "seed      " seed.php  '"sum":55' || return 1
  gate 1 "bridge pt " point.php '"sum":55' || return 1
  measure "$lane" bridge-point 1 point.php
  measure "$lane" bridge-write 1 write.php
  cleanup_nodes
}

# =====================================================================
# Lane W -- Turso, single site, whole-database clustered. On the primary.
# =====================================================================
lane_w() {
  local lane=W-cluster-primary
  banner "$lane (whole-cluster-primary/replica.toml, 2 nodes, --cpus $CPUS each)"
  cleanup_nodes
  start_node 1 whole-cluster-primary.toml "$IMG" no
  sleep 4
  start_node 2 whole-cluster-replica.toml "$IMG" no
  wait_ready 1 || { echo "!! primary never became ready:"; podman logs dbcl-n1 2>&1 | tail -30; return 1; }
  wait_ready 2 || { echo "!! replica never became ready:"; podman logs dbcl-n2 2>&1 | tail -30; return 1; }

  mode_gate 1 "starting EXPERIMENTAL Phase 2 CDC-native SQLite replication" "whole-DB clustered CDC" || return 1
  mode_gate 2 "starting EXPERIMENTAL Phase 2 CDC-native SQLite replication" "whole-DB clustered CDC" || return 1

  gate 1 "seed      " seed.php  '"sum":55' || return 1
  gate 1 "bridge pt " point.php '"sum":55' || return 1

  echo "-- replication proof --"
  converge 1 2 5 || return 1
  echo "   cdc subscribers: n1=$(cdc_subscribers 1) n2=$(cdc_subscribers 2)  (primary serves, replica does not)"

  measure "$lane" bridge-point 1 point.php
  measure "$lane" bridge-write 1 write.php
  cleanup_nodes
}

# =====================================================================
# Lane P1 -- per-site, single node. The multi-tenant reference point.
# =====================================================================
lane_p1() {
  local lane=P1-persite-single
  banner "$lane (persite-single.toml, 1 node, --cpus $CPUS)"
  cleanup_nodes
  start_node 1 persite-single.toml "$IMG" yes
  wait_ready 1 || { echo "!! n1 never became ready:"; podman logs dbcl-n1 2>&1 | tail -30; return 1; }
  mode_gate 1 "per-site database isolation enabled (one Turso database per virtual host)" \
    "per-site, single node" || return 1

  gate 1 "seed      " seed.php       '"sum":55' "$SITE" || return 1
  gate 1 "bridge pt " point.php      '"sum":55' "$SITE" || return 1
  gate 1 "wire pt   " wire-point.php '"sum":55' "$SITE" || return 1

  # GATE 2b, the negative control: the SAME files, no vhost Host header,
  # must get no per-site database context. If this passed, the tenant
  # would be selected by the mount rather than by the request, and every
  # per-site number in this suite would be meaningless.
  gate 1 "no-vhost  " point.php 'no per-site database context' || return 1

  measure "$lane" bridge-point 1 point.php      "$SITE"
  measure "$lane" bridge-write 1 write.php      "$SITE"
  measure "$lane" wire-point   1 wire-point.php "$SITE"
  cleanup_nodes
}

# =====================================================================
# Lanes P2/P3 -- per-site CLUSTERED, three nodes, one vhost.
#
# Run as one function because they share a cluster: measuring the owner
# and a non-owner of the SAME site against the SAME membership is the
# only way the difference between them is the forward hop and not two
# different clusters.
# =====================================================================
lane_p23() {
  banner "P2/P3 (persite-cluster-n1..n3.toml, 3 nodes, --cpus $CPUS each)"
  cleanup_nodes
  start_node 1 persite-cluster-n1.toml "$PS_IMG" yes
  sleep 4
  start_node 2 persite-cluster-n2.toml "$PS_IMG" yes
  start_node 3 persite-cluster-n3.toml "$PS_IMG" yes
  for n in $NODES; do
    wait_ready "$n" || { echo "!! n$n never became ready:"; podman logs "dbcl-n$n" 2>&1 | tail -30; return 1; }
  done

  for n in $NODES; do
    mode_gate "$n" "per-site CLUSTERED database isolation enabled" "per-site clustered" || {
      echo "!! Lanes P2/P3 need per-site clustered replication (ephpm#416), which is not in"
      echo "!! this image. It first appears in the ePHPm v0.8.6 tag. Set"
      echo "!!   EPHPM_PERSITE_CLUSTER_IMAGE=<a v0.8.6+ image>"
      echo "!! and re-run. Lanes S, W and P1 are unaffected."
      return 1
    }
    mode_gate "$n" "starting EXPERIMENTAL per-site clustered Turso replication" \
      "per-site CDC replication plane" || return 1
  done

  # Seed THROUGH THE BRIDGE, which lands on the site's owner wherever it
  # is (a non-owner forwards), so the tables exist once and replicate out.
  gate 1 "seed      " seed.php  '"sum":55' "$SITE" || return 1
  gate 1 "bridge pt " point.php '"sum":55' "$SITE" || return 1

  # Open the site's LOCAL database on every node. This is a setup step
  # with teeth, not a formality: on a non-owner the bridge hands back a
  # remote proxy and never opens the local file, so the registry's
  # open-hook never fires and that node never starts a replica driver for
  # the site. It would sit there replicating nothing, and the lane would
  # then measure a "cluster" in which two of three nodes hold no data.
  # A stock pdo_mysql request is what opens it locally.
  echo "-- opening the site locally on every node (starts the replica drivers) --"
  for n in $NODES; do
    echo "   n$n: $(get "$n" "count.php?t=bench" "$SITE")"
  done

  # GATE 3: exactly one owner, agreed on by two independent observations.
  echo "-- ownership --"
  local owner="" others="" subs
  for _ in $(seq 1 60); do
    owner=""; others=""
    for n in $NODES; do
      subs="$(cdc_subscribers "$n")"
      if [ "$subs" -gt 0 ] && elected_primary "$n"; then
        owner="${owner}${n}"
      else
        others="${others}${n}"
      fi
    done
    [ "${#owner}" = 1 ] && break
    sleep 2
  done
  for n in $NODES; do
    echo "   n$n: cdc_subscribers=$(cdc_subscribers "$n") elected_primary=$(elected_primary "$n" && echo yes || echo no)"
  done
  if [ "${#owner}" != 1 ]; then
    echo "!! OWNERSHIP GATE FAILED: expected exactly one node to own site '$SITE',"
    echo "!! found ${#owner} (\"$owner\"). With one site in the cluster, 'has CDC"
    echo "!! subscribers' and 'owns the site' must be the same node. Zero owners"
    echo "!! means no replica ever attached; two means the membership had not"
    echo "!! settled. Either way P2/P3 cannot be labelled and are invalid."
    return 1
  fi
  local nonowner="${others%${others#?}}"   # first character of $others
  echo "   OWNER = n$owner   NON-OWNER measured = n$nonowner"

  echo "-- replication proof --"
  converge "$owner" "$nonowner" 5 "$SITE" || return 1

  # ---- P2: on the owner. Local Turso, no hop. ----
  local l2=P2-persite-owner
  echo ""; echo "-- $l2 (node $owner owns '$SITE') --"
  measure "$l2" bridge-point "$owner" point.php      "$SITE"
  measure "$l2" bridge-write "$owner" write.php      "$SITE"
  measure "$l2" wire-point   "$owner" wire-point.php "$SITE"

  # ---- P3: on a non-owner. Every bridge statement crosses sql/<site>. ----
  local l3=P3-persite-remote
  echo ""; echo "-- $l3 (node $nonowner does NOT own '$SITE') --"
  measure "$l3" bridge-point "$nonowner" point.php      "$SITE"
  measure "$l3" bridge-write "$nonowner" write.php      "$SITE"
  # wire-point on a non-owner reads the LOCAL replica and is NOT
  # forwarded. It is measured to keep the P2/P3 bridge delta honest: if
  # this cell were also slower than P2's, the slowdown would be something
  # other than the forward hop.
  measure "$l3" wire-point   "$nonowner" wire-point.php "$SITE"

  # ---- Divergence probe. AFTER the measurement, never before. ----
  #
  # It writes a row that only one node will ever see, which is precisely
  # the kind of state a probe must not inject into a lane it precedes.
  echo ""
  echo "-- probe: stock pdo_mysql writes are NOT forwarded (documented gap) --"
  local before_owner after_owner after_local
  before_owner="$(get "$owner" "count.php?t=wbench" "$SITE")"
  get "$nonowner" wire-write.php "$SITE" >/dev/null
  sleep 3
  after_owner="$(get "$owner"    "count.php?t=wbench" "$SITE")"
  after_local="$(get "$nonowner" "count.php?t=wbench" "$SITE")"
  echo "   owner  n$owner    before: $before_owner"
  echo "   owner  n$owner    after : $after_owner"
  echo "   writer n$nonowner after : $after_local"
  echo "   Expected: the writer's local count is one HIGHER than the owner's."
  echo "   That row exists on exactly one node and is discarded when this"
  echo "   replica next re-bootstraps. Apps on the db-* drop-ins (ephpm_db_*)"
  echo "   are forwarded and unaffected; stock pdo_mysql on a non-owner is not."

  cleanup_nodes
}

# =====================================================================

SUITE_LANES="${1:-all}"
case "$SUITE_LANES" in
  all) lane_s || FAILED=1; lane_w || FAILED=1; lane_p1 || FAILED=1; lane_p23 || FAILED=1 ;;
  s)   lane_s   || FAILED=1 ;;
  w)   lane_w   || FAILED=1 ;;
  p1)  lane_p1  || FAILED=1 ;;
  p23) lane_p23 || FAILED=1 ;;
  *) echo "unknown lane selector: $SUITE_LANES (all|s|w|p1|p23)" >&2; exit 2 ;;
esac

echo ""
if [ "$FAILED" = 1 ]; then
  echo "=== one or more lanes FAILED their gates; raw output in $OUT ==="
  echo "=== a lane that could not be measured, WITH the reason, is a result. ==="
  echo "=== do not re-run until it looks reasonable.                        ==="
  exit 1
fi
echo "=== all lanes done; raw output in $OUT ==="
