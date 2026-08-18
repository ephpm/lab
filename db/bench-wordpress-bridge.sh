#!/usr/bin/env bash
# WordPress on the embedded database: mysqli wire vs the
# ephpm/db-wordpress drop-in (wp-content/db.php), per engine.
#
#   wp-sqlite   rusqlite engine -- REMOVED in ePHPm v0.7.0. Opt-in via
#               WP_BRIDGE_LEGACY_SQLITE=1, and then only on the pinned
#               v0.6.3 image; a historical row, not a lane of this run.
#   wp-turso    Turso engine -- the only engine from v0.7.0 on, and the
#               default lane of this suite.
#
# Each lane is ONE ePHPm container serving a real WordPress install from
# the embedded database, measured twice on two pages:
#
#   wire-home    /            stock mysqli wpdb -> 127.0.0.1:3306 (litewire)
#   wire-post    /?p=<id>     same, single-post page
#   bridge-home  /            ephpm/db-wordpress drop-in -> ephpm_db_*()
#   bridge-post  /?p=<id>     same, single-post page
#
# The ONLY difference between the wire and bridge cells is the presence
# of wp-content/db.php — same container, same engine, same content, same
# mu-plugins. The X-Db-Driver gate (mu-plugin, present in both cells)
# proves which wpdb class actually served, because the drop-in is
# designed to fall back to mysqli silently and a fallen-back "bridge"
# cell would otherwise benchmark the wire path under the wrong label.
#
# WordPress is installed by wp-cli THROUGH the MySQL wire frontend
# (mysqli -> litewire -> embedded engine) — the same bootstrap the
# ephpm/turso-cluster-e2e demo uses. Content is deterministic: the stock
# install plus 20 posts with fixed titles/bodies, no RNG anywhere.
#
# Needs ephpm >= v0.6.3 (ephpm_db_* functions) and network access on
# first run (wp core download, drop-in clone; both cached in the
# wpbridge-html volume afterwards).
#
# NOTE ON grep: Git Bash on Windows ships a broken default grep on PATH
# (swallows -E/-i and prints the flag). Every filter here uses
# /usr/bin/grep explicitly, and raw oha output is kept in results/.
set -uo pipefail

# See bench-bridge.sh: the rusqlite lane cannot run on v0.7.0+ (hard startup
# error), so it is opt-in and hard-pinned to the last image that has it.
# Two lanes on two ePHPm releases are not an engine A/B -- keep them apart.
IMG="${EPHPM_IMAGE:-docker.io/ephpm/ephpm:v0.7.0-php8.5}"
LEGACY_IMG="${EPHPM_LEGACY_IMAGE:-docker.io/ephpm/ephpm:v0.6.3-php8.5}"
OHA=ghcr.io/hatoo/oha:latest
CURL=docker.io/curlimages/curl:latest
WPCLI=docker.io/library/wordpress:cli
GITIMG=docker.io/alpine/git:latest
NET=dbbench-net
CPUS=1
DUR="${DUR:-15s}"
REPS="${REPS:-2}"
G=/usr/bin/grep
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/results-wp-bridge"
HTMLVOL=wpbridge-html
mkdir -p "$OUT"

podman network exists "$NET" 2>/dev/null || podman network create "$NET" >/dev/null
podman image exists "$CURL" 2>/dev/null || podman pull -q "$CURL" >/dev/null

cleanup() {
  podman rm -f wpbridge wpbridge-cli >/dev/null 2>&1 || true
}
trap cleanup EXIT

get()  { podman run --rm --network "$NET" "$CURL" -s  --max-time 30 "$1" 2>/dev/null; }
head_of() { podman run --rm --network "$NET" "$CURL" -sI --max-time 30 "$1" 2>/dev/null; }

# wp-cli, bypassing the image entrypoint (it no longer honors
# WP_CLI_PHP_ARGS; the default 128M is too small for core download).
wp_cli() {
  podman run --rm --name wpbridge-cli --network "$NET" \
    -v "$HTMLVOL:/var/www/html" -w /var/www/html --user root \
    --entrypoint php "$WPCLI" \
    -d memory_limit=512M /usr/local/bin/wp --allow-root "$@"
}

# Shell inside the shared docroot volume, with the repo fixtures visible.
vol_sh() {
  podman run --rm -v "$HTMLVOL:/var/www/html" \
    -v "$HERE/fixtures/wp:/fixtures:ro" -w /var/www/html --user root \
    --entrypoint sh "$WPCLI" -c "$1"
}

wait_db() {  # wait for litewire's MySQL frontend, from the network side
  for _ in $(seq 1 90); do
    if podman run --rm --network "$NET" --entrypoint php "$WPCLI" -r \
      '$m = @new mysqli("wpbridge", "root", "", "", 3306); exit($m->connect_errno ? 1 : 0);' \
      >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  return 1
}

setup_wordpress() {  # fresh DB volume each lane; docroot volume is cached
  vol_sh '[ -f wp-load.php ] || exit 42' || {
    echo "-- wp core download (first run only) --"
    wp_cli core download --force >/dev/null
  }
  wp_cli config create --dbname=wordpress --dbuser=root --dbpass= \
    --dbhost=wpbridge:3306 --skip-check --force >/dev/null
  wp_cli config set DISABLE_WP_CRON true --raw --type=constant >/dev/null
  wp_cli config set AUTOMATIC_UPDATER_DISABLED true --raw --type=constant >/dev/null
  wp_cli db create >/dev/null 2>&1 || true
  wp_cli core install --url="http://wpbridge:8080" \
    --title="ePHPm bridge bench" --admin_user=admin \
    --admin_password=admin --admin_email=admin@example.test \
    --skip-email >/dev/null

  # Deterministic content: 20 posts, fixed titles and bodies. The
  # measured post page is #10.
  POST_ID=""
  local i id para
  para="$(printf 'The quick brown fox jumps over the lazy dog. %.0s' 1 2 3 4 5 6 7 8)"
  for i in $(seq 1 20); do
    id="$(wp_cli post create --post_title="Bench post $i" \
      --post_content="$para" --post_status=publish --porcelain | tr -d '\r')"
    [ "$i" = 10 ] && POST_ID="$id"
  done

  # The driver gate must be present in BOTH cells.
  vol_sh 'mkdir -p wp-content/mu-plugins && cp /fixtures/driver-header.php wp-content/mu-plugins/driver-header.php'
  # Start every lane on the wire path: no drop-in.
  vol_sh 'rm -f wp-content/db.php'
}

dropin_install() {
  vol_sh '[ -d wp-content/db-wordpress ] || exit 42' || {
    echo "-- cloning ephpm/db-wordpress (first run only) --"
    podman run --rm -v "$HTMLVOL:/var/www/html" -w /var/www/html "$GITIMG" \
      clone --depth 1 https://github.com/ephpm/db-wordpress wp-content/db-wordpress >/dev/null 2>&1
  }
  # Shim, not copy: the drop-in resolves its src/ classes relative to its
  # own file, so it must execute from inside the package checkout.
  vol_sh "printf '%s\n' '<?php require __DIR__ . \"/db-wordpress/dropin/db.php\";' > wp-content/db.php"
}

dropin_remove() { vol_sh 'rm -f wp-content/db.php'; }

driver_gate() {  # url expected-substring cellname
  local hdr
  hdr="$(head_of "$1" | "$G" -i 'X-Db-Driver' | tr -d '\r')"
  echo "   $3 driver: ${hdr:-<missing>}"
  case "$hdr" in
    *"$2"*) return 0 ;;
    *) echo "!! DRIVER GATE FAILED ($3 wanted $2) -- cell invalid"; return 1 ;;
  esac
}

page_gate() {  # url want cellname
  local body; body="$(get "$1")"
  case "$body" in
    *"$2"*) echo "   $3 page: ok" ;;
    *) echo "!! PAGE GATE FAILED ($3: no '$2' in body)"; return 1 ;;
  esac
}

measure() {  # cellname url
  local cell="$1" url="$2"
  for conc in 1 8; do
    podman run --rm --network "$NET" "$OHA" -z 8s -c "$conc" --no-tui "$url" >/dev/null 2>&1
    for rep in $(seq 1 "$REPS"); do
      local f="$OUT/${LANE}-${cell}-c${conc}-r${rep}.txt"
      podman run --rm --network "$NET" "$OHA" -z "$DUR" -c "$conc" --no-tui "$url" > "$f" 2>&1
      printf '%-10s %-12s c=%-2s r=%s  ' "$LANE" "$cell" "$conc" "$rep"
      "$G" -E "Requests/sec" "$f" | head -1 | tr -s ' '
    done
  done
}

run_lane() {  # lane cfg img
  LANE="$1"; local cfg="$2" img="$3"
  echo ""; echo "############ LANE $LANE ($cfg, --cpus $CPUS) ############"
  echo "   image: $img"
  cleanup
  podman volume rm -f "dbv-$LANE" >/dev/null 2>&1 || true
  podman volume create "dbv-$LANE" >/dev/null
  podman run -d --name wpbridge --network "$NET" --cpus "$CPUS" \
    -v "$HTMLVOL:/var/www/html" \
    -v "$HERE/configs/$cfg:/etc/ephpm/ephpm.toml:ro" \
    -v "dbv-$LANE:/data" \
    "$img" >/dev/null
  if ! wait_db; then
    echo "!! $LANE MySQL frontend never became ready:"; podman logs wpbridge 2>&1 | tail -40; return 1
  fi
  echo "-- engine selection --"
  podman logs wpbridge 2>&1 | "$G" -iE "turso|engine|experimental" | head -5

  echo "-- wordpress install (wire path, via wp-cli) --"
  setup_wordpress || { echo "!! $LANE wordpress setup failed"; return 1; }
  echo "   post id under test: $POST_ID"

  local home="http://wpbridge:8080/" post="http://wpbridge:8080/?p=$POST_ID"

  echo "-- gates: wire cells --"
  driver_gate "$home" 'wpdb'       wire-home || return 1
  page_gate   "$home" 'Bench post' wire-home || return 1
  page_gate   "$post" "Bench post 10" wire-post || return 1
  measure wire-home "$home"
  measure wire-post "$post"

  echo "-- activating ephpm/db-wordpress drop-in --"
  dropin_install
  echo "-- gates: bridge cells --"
  driver_gate "$home" 'Ephpm'      bridge-home || return 1
  page_gate   "$home" 'Bench post' bridge-home || return 1
  page_gate   "$post" "Bench post 10" bridge-post || return 1
  measure bridge-home "$home"
  measure bridge-post "$post"

  dropin_remove
  cleanup
}

FAILED=0
if [ "${WP_BRIDGE_LEGACY_SQLITE:-0}" = 1 ]; then
  if [ "$LEGACY_IMG" != "$IMG" ]; then
    echo "!! lane wp-sqlite runs on $LEGACY_IMG, lane wp-turso on $IMG --"
    echo "!! a whole release apart. Separate historical row, never one table."
  fi
  run_lane wp-sqlite wp-bridge-sqlite.toml "$LEGACY_IMG" || FAILED=1
fi
run_lane wp-turso  wp-bridge-turso.toml  "$IMG" || FAILED=1

echo ""
if [ "$FAILED" = 1 ]; then
  echo "=== one or more lanes FAILED their gates; raw output in $OUT ==="
  exit 1
fi
echo "=== all lanes done; raw output in $OUT ==="
