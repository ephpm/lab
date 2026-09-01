#!/usr/bin/env bash
# Render k8s/laravel-v4.yaml into .generated/k8s/, optionally swapping the
# ePHPm image for a locally-built one.
#
# WHAT CHANGED AND WHY. This script used to substitute a placeholder token
# (`REPLACE_WITH_YOUR_EPHPM_SOURCE_IMAGE`) and refuse to run without
# EPHPM_SOURCE_IMAGE. That token no longer exists anywhere in the
# manifest -- laravel-v4.yaml now pins a published image directly -- so
# the substitution had become a no-op guarding a mandatory prompt: you
# were required to supply a value that was then thrown away, and
# `run-v4-worker-baseline.sh` (which reads .generated/) could not proceed
# without inventing one.
#
# Now: with EPHPM_SOURCE_IMAGE set, every `image: ephpm/ephpm:*` line is
# rewritten to it (which is what a source build actually needs). Without
# it, the manifest is copied through unchanged and the script says so,
# because the pinned published image is a perfectly good default.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${ROOT}/k8s/laravel-v4.yaml"
DEST_DIR="${ROOT}/.generated/k8s"
DEST="${DEST_DIR}/laravel-v4.yaml"
EPHPM_SOURCE_IMAGE="${EPHPM_SOURCE_IMAGE:-}"

mkdir -p "${DEST_DIR}"

if [ -n "${EPHPM_SOURCE_IMAGE}" ]; then
  sed -E "s#image: ephpm/ephpm:[^[:space:]]+#image: ${EPHPM_SOURCE_IMAGE}#g" \
    "${SRC}" > "${DEST}"
  echo "rendered with EPHPM_SOURCE_IMAGE=${EPHPM_SOURCE_IMAGE}" >&2
else
  cp "${SRC}" "${DEST}"
  echo "rendered with the manifest's pinned published image (set EPHPM_SOURCE_IMAGE to override)" >&2
fi

echo "${DEST}"
