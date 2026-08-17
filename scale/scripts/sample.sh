#!/usr/bin/env bash
# Sample a process's RSS, CPU, and open-fd count from /proc over a window, then
# emit a JSON summary. Peak RSS uses VmHWM (kernel high-water mark, exact);
# steady RSS is the mean of the second half of the window; CPU cores is the
# mean over per-interval utime+stime deltas.
#
# Usage: sample.sh <pid> <seconds> <out.json>
set -euo pipefail
PID="$1"; SECS="$2"; OUT="$3"
CLK=$(getconf CLK_TCK)

read_cpu() { awk '{print $14+$15}' "/proc/$1/stat"; }        # utime+stime (ticks)
read_rss() { awk '/^VmRSS:/{print $2}' "/proc/$1/status"; }  # kB
read_hwm() { awk '/^VmHWM:/{print $2}' "/proc/$1/status"; }  # kB
read_fds() { ls "/proc/$1/fd" 2>/dev/null | wc -l; }

declare -a RSS CORES FDS
prev_cpu=$(read_cpu "$PID"); prev_t=$(date +%s.%N)
for ((s=0; s<SECS; s++)); do
  sleep 1
  [ -d "/proc/$PID" ] || break
  now_cpu=$(read_cpu "$PID"); now_t=$(date +%s.%N)
  dt=$(awk -v a="$now_t" -v b="$prev_t" 'BEGIN{print a-b}')
  cores=$(awk -v dc="$((now_cpu - prev_cpu))" -v clk="$CLK" -v dt="$dt" 'BEGIN{printf "%.4f", (dc/clk)/dt}')
  RSS+=("$(read_rss "$PID")"); CORES+=("$cores"); FDS+=("$(read_fds "$PID")")
  prev_cpu=$now_cpu; prev_t=$now_t
done

hwm=$(read_hwm "$PID" 2>/dev/null || echo 0)
{
  printf '{'
  printf '"vmhwm_kb": %s,' "${hwm:-0}"
  # steady RSS = mean of second half; peak RSS observed; max fds; mean cores
  printf '"rss_steady_kb": %s,' "$(printf '%s\n' "${RSS[@]}" | awk '{a[NR]=$1} END{if(NR==0){print 0; exit} s=int(NR/2); sum=0; c=0; for(i=s+1;i<=NR;i++){sum+=a[i];c++} printf "%d", (c? sum/c : a[NR])}')"
  printf '"rss_peak_kb": %s,' "$(printf '%s\n' "${RSS[@]}" | sort -n | tail -1)"
  printf '"cpu_cores_mean": %s,' "$(printf '%s\n' "${CORES[@]}" | awk '{s+=$1;c++} END{printf "%.3f", (c? s/c : 0)}')"
  printf '"cpu_cores_peak": %s,' "$(printf '%s\n' "${CORES[@]}" | sort -n | tail -1)"
  printf '"fd_max": %s,' "$(printf '%s\n' "${FDS[@]}" | sort -n | tail -1)"
  printf '"samples": %s,' "${#RSS[@]}"
  # 1 Hz RSS series (kB) — exposes the growth SHAPE (bounded vs climbing),
  # which the steady/peak summary alone can hide under overload.
  printf '"rss_series_kb": [%s]' "$(printf '%s\n' "${RSS[@]}" | paste -sd, -)"
  printf '}\n'
} > "$OUT"
