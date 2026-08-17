#!/usr/bin/env bash
# Provision N virtual-host docroots by symlinking each site-NNNN to ONE shared
# read-only codebase. Shared code is realistic (production runs identical WP
# core across tenants) AND exercises the shared opcache; per-site divergence is
# the DATABASE, created separately by seeding.
#
# Usage: provision.sh <sites_dir> <shared_docroot> <N> [pad]
set -euo pipefail
SITES_DIR="$1"; DOCROOT="$2"; N="$3"; PAD="${4:-4}"

[ -d "$DOCROOT" ] || { echo "shared docroot missing: $DOCROOT" >&2; exit 1; }
mkdir -p "$SITES_DIR"

# Remove any sites beyond N from a previous larger run so the instance serves
# EXACTLY N tenants (clean per-N data point).
shopt -s nullglob
existing=("$SITES_DIR"/site-*)
if [ "${#existing[@]}" -gt 0 ]; then
  for link in "${existing[@]}"; do rm -f "$link"; done
fi

for i in $(seq 1 "$N"); do
  key=$(printf "site-%0*d" "$PAD" "$i")
  ln -sfn "$DOCROOT" "$SITES_DIR/$key"
done
echo "provisioned $N vhosts under $SITES_DIR -> $DOCROOT"
