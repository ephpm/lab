#!/usr/bin/env bash
# Parse an oha results directory into a table: RPS, p50, p99, and full
# response accounting.
#
#   ./parse.sh results-proxy
#
# Response accounting is not decoration. RPS alone cannot distinguish a
# fast server from one that is fast because it is failing, and a proxy
# lane that exhausts its connection pool answers 500s at an impressive
# rate. Every row prints its completed-2xx count and any non-2xx or
# transport error, and rows that are not clean are prefixed `!!`. A row
# that is not 100% 2xx is not a measurement.
#
# oha always reports "[N] aborted due to deadline" for the requests still
# in flight when the timer expires. That is N, not a failure, and it is
# expected on every row.
#
# grep NOTE: under Git Bash on Windows the default `grep` on PATH
# swallows -E/-i and prints the flag instead of filtering, which can
# silently discard measurements. Everything here calls /usr/bin/grep.
set -uo pipefail
G=/usr/bin/grep
DIR="${1:-results}"
cd "$(dirname "$0")/$DIR" 2>/dev/null || { echo "no such results dir: $DIR" >&2; exit 1; }

printf '%-24s %-6s %-5s %-3s %10s %12s %12s %9s  %s\n' \
  LANE FIX CONC REP RPS p50 p99 DONE STATUS
for f in *-c*-r*.txt; do
  [ -e "$f" ] || continue
  base="${f%.txt}"
  lane="${base%%-db-*}"; lane="${lane%%-write-*}"
  fix=db; case "$base" in *-write-*) fix=write;; esac
  conc="$(echo "$base" | sed -n 's/.*-c\([0-9]*\)-r[0-9]*/\1/p')"
  rep="$(echo  "$base" | sed -n 's/.*-r\([0-9]*\)$/\1/p')"

  rps="$("$G" -E '^  Requests/sec:' "$f" | head -1 | awk '{print $2}')"
  p50="$("$G" -E '^  50\.00% in ' "$f" | head -1 | sed 's/^  50\.00% in //')"
  p99="$("$G" -E '^  99\.00% in ' "$f" | head -1 | sed 's/^  99\.00% in //')"

  ok="$( "$G" -E '^  \[200\] ' "$f" | awk '{print $2}')"
  bad="$("$G" -E '^  \[[45][0-9][0-9]\] ' "$f" | tr -s ' ' | tr '\n' ' ')"
  err="$("$G" -A6 '^Error distribution:' "$f" \
        | "$G" -E '^  \[' | "$G" -v 'aborted due to deadline' | tr -s ' ' | tr '\n' ' ')"

  status="${ok:-0}x200"
  [ -n "$bad" ] && status="$status BAD:$bad"
  [ -n "$err" ] && status="$status ERR:$err"
  if [ -n "$bad" ] || [ -n "$err" ] || [ "${ok:-0}" = "0" ]; then status="!! $status"; fi

  printf '%-24s %-6s %-5s %-3s %10s %12s %12s %9s  %s\n' \
    "$lane" "$fix" "$conc" "$rep" "${rps:-?}" "${p50:-?}" "${p99:-?}" "${ok:-?}" "$status"
done | sort
