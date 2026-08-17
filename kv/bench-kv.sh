#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# kv-micro: per-op cost of ePHPm's KV store on its two access paths.
#
#   sapi  ephpm_kv_set/get/incr called in-process (ns/op, tight PHP loop,
#         hrtime inside the fixture — bare-loop numbers by construction)
#   resp  RESP2 SET/GET round-trip over TCP to the embedded listener
#         (µs/op, strict ping-pong from a raw PHP socket)
#
# This is a SOURCE-TIER suite (see scale/README.md): it drives a from-source
# ephpm binary as a bare process on the host, because the SAPI numbers are
# nanoseconds wide and a container quota adds nothing but noise. Provenance
# (binary rev + sha256) is printed into the results and must be published
# with any number from this suite.
#
# Why it exists: guides/kv-from-php.md publishes "~100 ns per op" (SAPI) and
# "~10-100 µs per op" (RESP) with no harness behind either number.
#
# Usage:
#   BIN=/path/to/ephpm bash kv/bench-kv.sh
#   RUN=$HOME/ephpm-kv-run SIZES="64 4096 65536" REPS=3 ...
# ---------------------------------------------------------------------------
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BIN="${BIN:?set BIN=/path/to/ephpm (from-source release build)}"
RUN="${RUN:-$HOME/ephpm-kv-run}"
PORT="${PORT:-8121}"
RESP_PORT="${RESP_PORT:-16390}"
SIZES="${SIZES:-64 4096 65536}"
SAPI_OPS="${SAPI_OPS:-200000}"
RESP_OPS="${RESP_OPS:-20000}"
REPS="${REPS:-3}"
OUT="${OUT:-$HERE/results-kv}"
mkdir -p "$OUT"

# The DrvFs trap (README "Traps That Taint A Run"): the server cwd and
# docroot must be native-filesystem. Refuse /mnt/* outright.
case "$RUN" in
  /mnt/*) echo "RUN=$RUN is on DrvFs (/mnt/*) — use a native path" >&2; exit 1 ;;
esac

mkdir -p "$RUN/docroot"
cp "$HERE/fixtures/kv_sapi.php" "$HERE/fixtures/kv_resp.php" "$RUN/docroot/"
CFG="$RUN/ephpm-kv.toml"
cat > "$CFG" <<EOF
[server]
listen = "127.0.0.1:$PORT"
document_root = "$RUN/docroot"

[server.limits]
per_ip_rate = 1000000.0
per_ip_burst = 1000000

[php]
mode = "fpm"
max_execution_time = 300

[kv.redis_compat]
enabled = true
listen = "127.0.0.1:$RESP_PORT"

[db.analysis]
query_stats = false
EOF

LOG="$RUN/server.log"
: > "$LOG"
( cd "$RUN" && exec "$BIN" serve --config "$CFG" ) >>"$LOG" 2>&1 &
SRV_PID=$!
trap 'kill "$SRV_PID" 2>/dev/null || true' EXIT

for _ in $(seq 1 100); do
  if curl -s -o /dev/null -m 2 "http://127.0.0.1:$PORT/kv_sapi.php?ops=1000"; then break; fi
  kill -0 "$SRV_PID" 2>/dev/null || { echo "server died:"; tail -20 "$LOG"; exit 1; }
  sleep 0.2
done

# Gates: the RESP listener must have announced itself, and both fixtures must
# return clean JSON before anything is recorded.
if ! grep -qi "resp" "$LOG"; then
  echo "!! startup log has no RESP listener line — [kv.redis_compat] did not take" >&2
  tail -20 "$LOG" >&2; exit 1
fi
probe="$(curl -s -m 30 "http://127.0.0.1:$PORT/kv_resp.php?size=64&ops=500&port=$RESP_PORT")"
case "$probe" in
  *'"lane":"resp"'*) echo "gate/resp OK: $probe" ;;
  *) echo "!! RESP gate failed: $probe" >&2; exit 1 ;;
esac

echo "binary=$BIN"
echo "rev=$(git -C "$(dirname "$BIN")" rev-parse --short HEAD 2>/dev/null || echo unknown)"
sha256sum "$BIN" | tee "$OUT/provenance.txt"

# Interleaved reps: sapi and resp alternate so drift hits both lanes equally.
for rep in $(seq 1 "$REPS"); do
  for size in $SIZES; do
    f="$OUT/sapi-s${size}-r${rep}.json"
    curl -s -m 300 "http://127.0.0.1:$PORT/kv_sapi.php?size=${size}&ops=${SAPI_OPS}" > "$f"
    echo "sapi size=$size rep=$rep: $(cat "$f")"
    case "$(cat "$f")" in *error*) echo "!! sapi lane failed" >&2; exit 1;; esac
    f="$OUT/resp-s${size}-r${rep}.json"
    curl -s -m 300 "http://127.0.0.1:$PORT/kv_resp.php?size=${size}&ops=${RESP_OPS}&port=${RESP_PORT}" > "$f"
    echo "resp size=$size rep=$rep: $(cat "$f")"
    case "$(cat "$f")" in *error*) echo "!! resp lane failed" >&2; exit 1;; esac
  done
done

echo "done; raw JSON in $OUT (report the MEDIAN of the $REPS reps per cell)"
