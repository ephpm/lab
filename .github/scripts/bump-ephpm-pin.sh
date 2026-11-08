#!/usr/bin/env bash
#
# bump-ephpm-pin.sh — bump the lab's ACTIVE ePHPm image pins to the latest
# published ephpm/ephpm version, using .github/ephpm-active-pins.txt as the
# single source of truth for what is active. Historical suites are never
# touched (they are simply not listed, plus a belt-and-suspenders skip guard).
#
# Rules are deterministic — no per-run judgement:
#   * Only files listed in the manifest are ever modified.
#   * Each pin keeps its own `-php<minor>` suffix; only vX.Y.Z changes.
#   * Any line containing HISTORICAL_IMAGE or the marker `ephpm-pin:historical`
#     is skipped, even inside a listed file.
#   * `shellvar` entries only touch the named variable's assignment line.
#   * Idempotent: if every active pin already equals the target, exit 0 with no
#     changes ("already at vX.Y.Z, no changes").
#
# Usage:
#   bump-ephpm-pin.sh [--dry-run] [--version X.Y.Z] [--manifest PATH]
#
#   --dry-run        Show what would change; write nothing.
#   --version X.Y.Z  Bump to this version instead of querying Docker Hub.
#   --print-version  Resolve the target version, print it, and exit (no edits).
#   --manifest PATH  Override the active-pin manifest (default:
#                    .github/ephpm-active-pins.txt).
#
# Latest version is determined from Docker Hub (NOT GitHub Releases — the dind
# CI bug means images can publish without a Release): the newest semver tag for
# which BOTH `-php8.4` and `-php8.5` variants exist.
#
# Exit codes: 0 success (changes or no-op), 1 error.

set -euo pipefail

# --- portable tool selection -------------------------------------------------
# On Git Bash a broken grep.exe shim can shadow PATH; prefer the real msys/GNU
# grep at /usr/bin/grep. On CI (ubuntu) /usr/bin/grep is the normal GNU grep.
GREP=grep
[ -x /usr/bin/grep ] && GREP=/usr/bin/grep
SED=sed
[ -x /usr/bin/sed ] && SED=/usr/bin/sed
CMP=cmp
[ -x /usr/bin/cmp ] && CMP=/usr/bin/cmp
DIFF=diff
[ -x /usr/bin/diff ] && DIFF=/usr/bin/diff

DOCKER_HUB_TAGS_URL="https://hub.docker.com/v2/repositories/ephpm/ephpm/tags?page_size=100"
HISTORICAL_GUARD='HISTORICAL_IMAGE|ephpm-pin:historical'

DRY_RUN=0
PRINT_VERSION=0
VERSION=""
MANIFEST=""

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() {
  $SED -n '2,40p' "$0" | $SED 's/^#\{0,1\} \{0,1\}//'
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --print-version) PRINT_VERSION=1; shift ;;
    --version) VERSION="${2:-}"; shift 2 ;;
    --version=*) VERSION="${1#*=}"; shift ;;
    --manifest) MANIFEST="${2:-}"; shift 2 ;;
    --manifest=*) MANIFEST="${1#*=}"; shift ;;
    -h|--help) usage 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

# --- locate repo root + manifest ---------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)"; then
  :
else
  REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
fi
cd "$REPO_ROOT"

[ -n "$MANIFEST" ] || MANIFEST=".github/ephpm-active-pins.txt"
[ -f "$MANIFEST" ] || die "manifest not found: $MANIFEST"

# --- determine target version ------------------------------------------------
fetch_latest() {
  command -v curl >/dev/null 2>&1 || die "curl is required to query Docker Hub"
  command -v jq   >/dev/null 2>&1 || die "jq is required to query Docker Hub"
  local url="$DOCKER_HUB_TAGS_URL" page=0 resp names all=""
  while [ -n "$url" ] && [ "$url" != "null" ] && [ "$page" -lt 20 ]; do
    page=$((page + 1))
    resp="$(curl -fsSL -m 30 "$url")" || die "Docker Hub request failed"
    names="$(printf '%s' "$resp" | jq -r '.results[].name')"
    all="$all
$names"
    url="$(printf '%s' "$resp" | jq -r '.next')"
  done
  local v84 v85 both latest
  v84="$(printf '%s\n' "$all" | $GREP -E '^v[0-9]+\.[0-9]+\.[0-9]+-php8\.4$' | $SED -E 's/^v//; s/-php8\.4$//' | sort -u)"
  v85="$(printf '%s\n' "$all" | $GREP -E '^v[0-9]+\.[0-9]+\.[0-9]+-php8\.5$' | $SED -E 's/^v//; s/-php8\.5$//' | sort -u)"
  both="$(comm -12 <(printf '%s\n' "$v84") <(printf '%s\n' "$v85"))"
  latest="$(printf '%s\n' "$both" | $GREP -E '^[0-9]' | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)"
  [ -n "$latest" ] || die "no ephpm/ephpm version with both -php8.4 and -php8.5 variants found"
  printf '%s\n' "$latest"
}

if [ -z "$VERSION" ]; then
  printf 'Querying Docker Hub for the latest ephpm/ephpm version...\n' >&2
  VERSION="$(fetch_latest)"
  printf 'Latest published version (both -php8.4 and -php8.5 present): v%s\n' "$VERSION" >&2
fi

printf '%s' "$VERSION" | $GREP -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
  || die "invalid version '$VERSION' (expected X.Y.Z, no leading 'v')"

# --print-version: emit the resolved target version and stop (no edits).
if [ "$PRINT_VERSION" -eq 1 ]; then
  printf '%s\n' "$VERSION"
  exit 0
fi

# --- per-file transform ------------------------------------------------------
# Emits the transformed content of $file to stdout. Never writes.
#
# perl (not sed) does the edits: it preserves each line's exact bytes, including
# CRLF terminators, so this is safe on a Windows/CRLF working tree as well as on
# a Linux/LF checkout (CI). \Q..\E quotes the interpolated suffix/version so the
# literal '.' characters are matched literally. Under `perl -p`, `next` still
# prints the (unmodified) line via the implicit continue block.
transform() {
  local kind="$1" file="$2" suffix="$3" var="${4:-}"
  export EP_SFX="$suffix" EP_NEW="$VERSION" EP_VAR="$var"

  case "$kind" in
    manifest)
      perl -pe '
        next if /HISTORICAL_IMAGE|ephpm-pin:historical/;
        s{ephpm/ephpm:v\d+\.\d+\.\d+-\Q$ENV{EP_SFX}\E}{ephpm/ephpm:v$ENV{EP_NEW}-$ENV{EP_SFX}}g;
      ' "$file"
      ;;
    shellvar)
      [ -n "$var" ] || die "shellvar entry for $file is missing a variable name"
      perl -pe '
        next if /HISTORICAL_IMAGE|ephpm-pin:historical/;
        next unless /^\s*\Q$ENV{EP_VAR}\E=/;
        s{ephpm/ephpm:v\d+\.\d+\.\d+-\Q$ENV{EP_SFX}\E}{ephpm/ephpm:v$ENV{EP_NEW}-$ENV{EP_SFX}}g;
      ' "$file"
      ;;
    prose)
      # Detect the file's own current-pin version from its image-form pin, then
      # replace both the image-form pin and the bare version token. The bare
      # replace targets that exact version only (with a trailing non-digit
      # boundary), so historical bare mentions like v0.4.0 / v0.6.3 are untouched.
      local old
      old="$(perl -ne 'if(/ephpm\/ephpm:v(\d+\.\d+\.\d+)-\Q$ENV{EP_SFX}\E/){print $1; exit}' "$file")"
      if [ -n "$old" ]; then
        export EP_OLD="$old"
        perl -pe '
          next if /HISTORICAL_IMAGE|ephpm-pin:historical/;
          s{ephpm/ephpm:v\d+\.\d+\.\d+-\Q$ENV{EP_SFX}\E}{ephpm/ephpm:v$ENV{EP_NEW}-$ENV{EP_SFX}}g;
          s{v\Q$ENV{EP_OLD}\E(?![0-9])}{v$ENV{EP_NEW}}g;
        ' "$file"
      else
        # No image-form pin to anchor on: nothing to bump — emit as-is.
        cat "$file"
      fi
      ;;
    *)
      die "unknown manifest kind '$kind' for $file"
      ;;
  esac
}

# --- apply over the manifest -------------------------------------------------
CHANGED_FILES=""
TOTAL_CHANGED=0
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

while read -r kind file suffix var _rest; do
  # tolerate a CRLF-checked-out manifest: strip any trailing CR from each field
  kind="${kind%$'\r'}"; file="${file%$'\r'}"; suffix="${suffix%$'\r'}"; var="${var%$'\r'}"
  case "$kind" in ''|\#*) continue ;; esac   # skip blanks/comments
  [ -f "$file" ] || die "listed file not found: $file"

  transform "$kind" "$file" "$suffix" "$var" > "$TMP"

  if $CMP -s "$TMP" "$file"; then
    continue
  fi

  n="$($DIFF "$file" "$TMP" | $GREP -Ec '^> ' || true)"
  CHANGED_FILES="${CHANGED_FILES}${file} (${n} line(s))
"
  TOTAL_CHANGED=$((TOTAL_CHANGED + 1))

  printf '\n=== %s ===\n' "$file"
  # Show only the changed lines, old -> new.
  $DIFF "$file" "$TMP" | $GREP -E '^[<>]' || true

  if [ "$DRY_RUN" -eq 0 ]; then
    cat "$TMP" > "$file"
  fi
done < "$MANIFEST"

printf '\n----------------------------------------------------------------\n'
if [ "$TOTAL_CHANGED" -eq 0 ]; then
  printf 'already at v%s, no changes\n' "$VERSION"
  exit 0
fi

if [ "$DRY_RUN" -eq 1 ]; then
  printf 'DRY RUN: would bump %d file(s) to v%s:\n' "$TOTAL_CHANGED" "$VERSION"
else
  printf 'bumped %d file(s) to v%s:\n' "$TOTAL_CHANGED" "$VERSION"
fi
printf '%s' "$CHANGED_FILES"
exit 0
