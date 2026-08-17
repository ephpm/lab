#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# containment-tax: what does `[php] crash_containment = true` cost?
#
# Two lanes on the SAME binary, both on `[php] fpm_engine = "pool"` (the only
# engine where containment is active — see is_crash_containment_active()):
#
#   happy   A/B: crash_containment=false vs true on {hello.php, db.php} x
#           {c=1, c=CHI}. Interleaved ABBA-AB run order (fresh server per
#           run), REPS runs per lane, report the MEDIAN — this pins the
#           "containment is performance-free on the happy path" claim.
#
#   storm   crash_containment=true only: STORM_N sequential requests to
#           stack_overflow.php (copied from ephpm tests/docroot — each one
#           SIGSEGVs a pool thread on purpose). Records: per-crash wall time,
#           ephpm_fpm_pool_contained_crashes_total before/after (must equal
#           STORM_N), RSS before/after (the bounded leak, KB/crash), thread
#           retirement evidence in the log, whether concurrent hello traffic
#           kept its p99, and a post-storm recovery run.
#
# SOURCE-TIER suite (see scale/README.md): bare-process from-source binary.
# Requires Go (builds ../scale/loadgen as the closed-loop driver).
#
# Usage:
#   BIN=/path/to/ephpm bash containment/bench-containment.sh          # both
#   BIN=... bash containment/bench-containment.sh happy|storm
# ---------------------------------------------------------------------------
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB="$(dirname "$HERE")"

BIN="${BIN:?set BIN=/path/to/ephpm (from-source release build)}"
RUN="${RUN:-$HOME/ephpm-containment-run}"
PORT="${PORT:-8123}"
CHI="${CHI:-32}"              # the "c=high" concurrency
DUR="${DUR:-15}"
WARMUP="${WARMUP:-3}"
REPS="${REPS:-3}"             # runs per lane per cell (ABBA-AB interleave)
STORM_N="${STORM_N:-500}"
STORM_DEPTH="${STORM_DEPTH:-200000}"
OUT="${OUT:-$HERE/results-containment}"
mkdir -p "$OUT"

case "$RUN" in
  /mnt/*) echo "RUN=$RUN is on DrvFs (/mnt/*) — use a native path" >&2; exit 1 ;;
esac

mkdir -p "$RUN/docroot"
cp "$HERE/fixtures/"*.php "$RUN/docroot/"
LOADGEN="$RUN/loadgen"
( cd "$LAB/scale/loadgen" && go build -o "$LOADGEN" . )

LOG="$RUN/server.log"
SRV_PID=""
stop_server() {
  [ -n "$SRV_PID" ] || return 0
  kill "$SRV_PID" 2>/dev/null || true
  for _ in $(seq 1 50); do kill -0 "$SRV_PID" 2>/dev/null || break; sleep 0.1; done
  kill -9 "$SRV_PID" 2>/dev/null || true
  SRV_PID=""
}
trap stop_server EXIT

start_server() {  # containment(true|false)
  local contain="$1"
  cat > "$RUN/ephpm-containment.toml" <<EOF
[server]
listen = "127.0.0.1:$PORT"
document_root = "$RUN/docroot"

[server.limits]
per_ip_rate = 1000000.0
per_ip_burst = 1000000

[server.metrics]
enabled = true

[php]
mode = "fpm"
fpm_engine = "pool"
crash_containment = $contain
max_execution_time = 60

[db.sqlite]
path = "$RUN/bench.db"

[db.analysis]
query_stats = false
EOF
  : > "$LOG"
  ( cd "$RUN" && exec "$BIN" serve --config "$RUN/ephpm-containment.toml" ) >>"$LOG" 2>&1 &
  SRV_PID=$!
  for _ in $(seq 1 100); do
    if curl -s -o /dev/null -m 2 "http://127.0.0.1:$PORT/hello.php"; then break; fi
    kill -0 "$SRV_PID" 2>/dev/null || { echo "server died:"; tail -20 "$LOG"; exit 1; }
    sleep 0.2
  done
  # Gates: the pool engine must be up, and the containment knob must match.
  grep -q "fpm execution pool started" "$LOG" || { echo "!! no pool startup line"; exit 1; }
  # The knob's own startup evidence (crates/ephpm/src/main.rs): the armed
  # path warns "crash_containment is ON"; the inert combinations warn
  # "IGNORED". Gate both directions so a lane can never be mislabelled.
  if [ "$contain" = "true" ]; then
    if ! grep -q "crash_containment is ON" "$LOG"; then
      echo "!! containment=true but no 'crash_containment is ON' startup line"; tail -30 "$LOG"; exit 1
    fi
  else
    if grep -q "crash_containment is ON" "$LOG"; then
      echo "!! containment=false but the guard armed"; exit 1
    fi
  fi
  # Seed + fixture gate.
  local s; s="$(curl -s -m 10 "http://127.0.0.1:$PORT/seed.php")"
  case "$s" in *'"count":10'*) ;; *) echo "!! seed gate failed: $s"; exit 1;; esac
  local d; d="$(curl -s -m 10 "http://127.0.0.1:$PORT/db.php")"
  case "$d" in *'"sum":55'*) ;; *) echo "!! db fixture gate failed: $d"; exit 1;; esac
}

metric() {  # name -> summed value (0 if absent)
  curl -s -m 5 "http://127.0.0.1:$PORT/metrics" \
    | awk -v m="$1" '$1 ~ "^"m {s += $NF} END {printf "%d", s}'
}
rss_kb()  { awk '/^VmRSS:/{print $2}'  "/proc/$SRV_PID/status" 2>/dev/null || echo 0; }
vmhwm_kb(){ awk '/^VmHWM:/{print $2}'  "/proc/$SRV_PID/status" 2>/dev/null || echo 0; }

run_cell() {  # lane fixture conc rep
  local lane="$1" fx="$2" conc="$3" rep="$4"
  local f="$OUT/happy-${lane}-${fx%.php}-c${conc}-r${rep}.json"
  "$LOADGEN" -base "http://127.0.0.1:$PORT" -n 1 -c "$conc" \
    -front "/$fx" -wfront 1 -wperm 0 -wrest 0 \
    -warmup "$WARMUP" -d "$DUR" \
    -label "containment=$lane $fx c=$conc rep=$rep" > "$f"
  printf '%-6s %-9s c=%-3s r=%s  rps=%s p50=%s p99=%s status=%s\n' \
    "$lane" "${fx%.php}" "$conc" "$rep" \
    "$(grep -o '"rps": *[0-9.]*' "$f" | head -1 | grep -o '[0-9.]*')" \
    "$(grep -o '"p50": *[0-9.]*' "$f" | head -1 | grep -o '[0-9.]*$')" \
    "$(grep -o '"p99": *[0-9.]*' "$f" | head -1 | grep -o '[0-9.]*$')" \
    "$(grep -o '"status": *{[^}]*}' "$f" | head -1)"
}

happy() {
  echo "== happy-path A/B (A=containment off, B=on; order ABBA-AB x fixtures x {1,$CHI}) =="
  # Fresh server per run; the lane sequence interleaves drift across A and B.
  local seq="false true true false false true"
  for fx in hello.php db.php; do
    for conc in 1 "$CHI"; do
      local ra=0 rb=0
      for lane in $seq; do
        if [ "$lane" = "false" ]; then ra=$((ra+1)); rep=$ra; else rb=$((rb+1)); rep=$rb; fi
        start_server "$lane"
        run_cell "$lane" "$fx" "$conc" "$rep"
        stop_server
      done
    done
  done
  echo "happy-path raw JSON in $OUT (report per-cell MEDIANS of the $REPS reps)"
}

storm() {
  echo "== crash-storm (containment=true, $STORM_N contained SIGSEGVs) =="
  start_server true
  local before after rss0 rss1 hwm0 hwm1
  before="$(metric ephpm_fpm_pool_contained_crashes_total)"
  rss0="$(rss_kb)"; hwm0="$(vmhwm_kb)"
  echo "baseline: contained=$before rss_kb=$rss0 vmhwm_kb=$hwm0"

  # Concurrent well-behaved traffic for the whole storm: does non-crashing
  # p99 hold while threads are being retired and respawned?
  "$LOADGEN" -base "http://127.0.0.1:$PORT" -n 1 -c 8 \
    -front /hello.php -wfront 1 -wperm 0 -wrest 0 \
    -warmup 2 -d 180 -label "hello during crash storm" \
    > "$OUT/storm-concurrent-hello.json" &
  local lg=$!

  local t_start t_end statuses="$OUT/storm-crash-statuses.txt"
  : > "$statuses"
  t_start=$(date +%s.%N)
  for i in $(seq 1 "$STORM_N"); do
    curl -s -o /dev/null -m 30 \
      -w "%{http_code} %{time_total}\n" \
      "http://127.0.0.1:$PORT/stack_overflow.php?depth=$STORM_DEPTH" >> "$statuses" \
      || echo "000 curl-fail" >> "$statuses"
  done
  t_end=$(date +%s.%N)

  wait "$lg" || echo "!! concurrent loadgen exited nonzero"
  after="$(metric ephpm_fpm_pool_contained_crashes_total)"
  rss1="$(rss_kb)"; hwm1="$(vmhwm_kb)"
  local survived=true; kill -0 "$SRV_PID" 2>/dev/null || survived=false
  local retired; retired="$(grep -aci "retir" "$LOG" || true)"

  # Post-storm recovery run on the same instance.
  "$LOADGEN" -base "http://127.0.0.1:$PORT" -n 1 -c 8 \
    -front /hello.php -wfront 1 -wperm 0 -wrest 0 \
    -warmup 2 -d 10 -label "recovery after storm" \
    > "$OUT/storm-recovery-hello.json" || true

  {
    echo "storm_n=$STORM_N depth=$STORM_DEPTH"
    echo "survived=$survived"
    echo "contained_before=$before contained_after=$after delta=$((after-before))"
    echo "rss_before_kb=$rss0 rss_after_kb=$rss1 growth_kb=$((rss1-rss0)) growth_kb_per_crash=$(awk "BEGIN{printf \"%.1f\", ($rss1-$rss0)/$STORM_N}")"
    echo "vmhwm_before_kb=$hwm0 vmhwm_after_kb=$hwm1"
    echo "storm_wall_s=$(awk "BEGIN{printf \"%.1f\", $t_end-$t_start}") s_per_crash=$(awk "BEGIN{printf \"%.3f\", ($t_end-$t_start)/$STORM_N}")"
    echo "crash_status_histogram: $(awk '{print $1}' "$statuses" | sort | uniq -c | tr '\n' ' ')"
    echo "log_thread_retire_lines=$retired"
  } | tee "$OUT/storm-summary.txt"
  stop_server
}

echo "binary=$BIN"
sha256sum "$BIN" | tee "$OUT/provenance.txt"

WANT="${1:-happy storm}"
case " $WANT " in *" happy "*) happy;; esac
case " $WANT " in *" storm "*) storm;; esac
echo "done; results in $OUT"
