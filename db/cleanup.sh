#!/usr/bin/env bash
# Remove every podman resource the database suites create.
#
#   ./db/cleanup.sh          # show what would be removed
#   ./db/cleanup.sh --yes    # actually remove it
#
# WHY THIS EXISTS. The bench scripts reclaim their volumes at the START of
# a run (`volume rm -f X || true; volume create X`), which is correct for
# re-running the same lane but means everything they make OUTLIVES the
# run. A user who runs `scripts/run-db-bench.sh all` once and walks away
# is left with roughly ten named volumes -- one of them holding a full
# seeded WordPress tree -- plus a podman network, none of which any
# script removes. `bench-cluster.sh` cleans up after itself; the older
# suites predate that habit and are not being rewritten for it, since
# their traps are load-bearing for the historical lanes.
#
# The resource names are spread across four prefixes (`dbbench-*`,
# `dbv-*`, `wpbridge*`, `pcd-*`/`probe-*`, `dbcl*`) while sharing one
# network, so the obvious one-liner a user reaches for --
# `podman rm -f dbbench-*` -- misses about half of them. That is the
# other reason this file exists.
#
# NOTE ON grep: under Git Bash on Windows the default `grep` on PATH
# swallows -E and prints the flag instead of filtering. Use /usr/bin/grep.
set -uo pipefail
G=/usr/bin/grep

APPLY=no
[ "${1:-}" = "--yes" ] && APPLY=yes

# Containers, by exact name (every name any db/ script uses).
CONTAINERS="dbbench-c1 dbbench-c2 dbbench-lw dbbench-mysql dbbench-pg
            wpbridge wpbridge-cli
            pcd-lw pcd-px probe-lw probe-px probe-pg
            dbcl-n1 dbcl-n2 dbcl-n3"

# Volumes, by prefix -- lane-scoped names (dbv-A-sqlite-single, ...) are
# generated from lane lists and cannot be enumerated statically.
VOL_PREFIXES='^(dbv-|dbclv-|wpbridge-html$|pcd-v$|probe-lw-v$)'

NETWORKS="dbbench-net dbcluster-net"

echo "== containers =="
found_c=""
for c in $CONTAINERS; do
  if podman container exists "$c" 2>/dev/null; then
    echo "   $c"; found_c="$found_c $c"
  fi
done
[ -n "$found_c" ] || echo "   (none)"

echo "== volumes =="
found_v="$(podman volume ls --format '{{.Name}}' 2>/dev/null | $G -E "$VOL_PREFIXES")"
if [ -n "$found_v" ]; then echo "$found_v" | sed 's/^/   /'; else echo "   (none)"; fi

echo "== networks =="
found_n=""
for n in $NETWORKS; do
  if podman network exists "$n" 2>/dev/null; then
    echo "   $n"; found_n="$found_n $n"
  fi
done
[ -n "$found_n" ] || echo "   (none)"

if [ "$APPLY" != yes ]; then
  echo ""
  echo "Dry run. Re-run with --yes to remove the above."
  exit 0
fi

echo ""
echo "-- removing --"
# Containers first: a volume or network still attached to one cannot go.
for c in $found_c; do podman rm -f "$c" >/dev/null 2>&1 && echo "   removed container $c"; done
for v in $found_v; do podman volume rm -f "$v" >/dev/null 2>&1 && echo "   removed volume $v"; done
for n in $found_n; do podman network rm "$n" >/dev/null 2>&1 && echo "   removed network $n"; done
echo ""
echo "Raw oha output under db/results-*/ is NOT touched. It is the measurement;"
echo "a cleanup script must never be able to delete a result."
