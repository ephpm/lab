#!/usr/bin/env bash
# Seed ONE real-WordPress site by driving the web installer over HTTP, so the
# db-wordpress drop-in creates the full WP schema + default content (Hello
# World post, Sample Page, one comment) in that site's own per-site Turso DB.
# run_sweep.sh then copies the resulting file to all N sites.
#
# Usage: seed_wp_real.sh <base-url> <site-host>
set -euo pipefail
BASE="$1"; HOST="$2"

# install.php step 2 creates the tables and the admin user. pw_weak=1 accepts a
# weak password (fine for a throwaway bench install).
code=$(curl -s -o /tmp/wp_install_out.html -w '%{http_code}' \
  -H "Host: $HOST" \
  --data-urlencode "weblog_title=Scalebench $HOST" \
  --data-urlencode "user_name=admin" \
  --data-urlencode "admin_password=scalebench-pw-123" \
  --data-urlencode "admin_password2=scalebench-pw-123" \
  --data-urlencode "pw_weak=1" \
  --data-urlencode "admin_email=admin@example.com" \
  --data-urlencode "blog_public=0" \
  --data-urlencode "language=" \
  --data-urlencode "Submit=Install WordPress" \
  "$BASE/wp-admin/install.php?step=2")

if [ "$code" != "200" ]; then
  echo "wp install returned HTTP $code" >&2
  head -40 /tmp/wp_install_out.html >&2 || true
  exit 1
fi

# Verify the front page renders (schema present, drop-in wired).
front=$(curl -s -o /dev/null -w '%{http_code}' -H "Host: $HOST" "$BASE/")
echo "wp-real seeded on $HOST (install=$code front=$front)"
