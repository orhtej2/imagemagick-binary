#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/" && pwd)"
LOCK_FILE="$ROOT_DIR/dependencies.lock"

if [[ ! -f "$LOCK_FILE" ]]; then
  echo "Lock file not found: $LOCK_FILE" >&2
  exit 1
fi

# shellcheck source=/dev/null
source "$LOCK_FILE"

latest_tag_from_remote() {
  local repo_url="$1"
  local tag_pattern="$2"

  local tags
  tags=$(git ls-remote --tags --refs "$repo_url" \
    | awk '{print $2}' \
    | sed 's#refs/tags/##' \
    | grep -Ei "$tag_pattern" \
    | grep -Eiv 'alpha|beta|rc|pre|preview' || true)

  if [[ -z "$tags" ]]; then
    return 1
  fi

  printf '%s\n' "$tags" | sort -V | tail -n 1
}

update_var_if_newer() {
  local var_name="$1"
  local repo_var_name="$2"
  local tag_pattern="$3"

  local current_tag="${!var_name}"
  local repo_url="${!repo_var_name}"

  local latest_tag
  if ! latest_tag=$(latest_tag_from_remote "$repo_url" "$tag_pattern"); then
    echo "Could not resolve latest tag for $repo_url"
    return 0
  fi

  if [[ "$latest_tag" != "$current_tag" ]]; then
    printf -v "$var_name" '%s' "$latest_tag"
    echo "Updated $var_name: $current_tag -> $latest_tag"
    return 0
  fi

  echo "No change for $var_name ($current_tag)"
}

update_var_if_newer "ZLIB_TAG" "ZLIB_REPO" '^v?[0-9]+(\.[0-9]+){1,3}$'
update_var_if_newer "LIBJPEG_TURBO_TAG" "LIBJPEG_TURBO_REPO" '^[0-9]+(\.[0-9]+){1,3}$'
update_var_if_newer "LIBPNG_TAG" "LIBPNG_REPO" '^v?[0-9]+(\.[0-9]+){2,3}$'
update_var_if_newer "FREETYPE_TAG" "FREETYPE_REPO" '^VER-[0-9]+(-[0-9]+){2,3}$'
update_var_if_newer "HARFBUZZ_TAG" "HARFBUZZ_REPO" '^v?[0-9]+(\.[0-9]+){1,3}$'
update_var_if_newer "LIBWEBP_TAG" "LIBWEBP_REPO" '^v?[0-9]+(\.[0-9]+){2,3}$'
update_var_if_newer "LIBTIFF_TAG" "LIBTIFF_REPO" '^v?[0-9]+(\.[0-9]+){2,3}$'
update_var_if_newer "FONTCONFIG_TAG" "FONTCONFIG_REPO" '^[0-9]+(\.[0-9]+){2,3}$'

cat > "$LOCK_FILE" <<EOF
# Pinned dependency sources and tags for build.sh
# Update with: scripts/update-dependency-lock.sh

ZLIB_REPO="$ZLIB_REPO"
ZLIB_TAG="$ZLIB_TAG"

LIBJPEG_TURBO_REPO="$LIBJPEG_TURBO_REPO"
LIBJPEG_TURBO_TAG="$LIBJPEG_TURBO_TAG"

LIBPNG_REPO="$LIBPNG_REPO"
LIBPNG_TAG="$LIBPNG_TAG"

FREETYPE_REPO="$FREETYPE_REPO"
FREETYPE_TAG="$FREETYPE_TAG"

HARFBUZZ_REPO="$HARFBUZZ_REPO"
HARFBUZZ_TAG="$HARFBUZZ_TAG"

LIBWEBP_REPO="$LIBWEBP_REPO"
LIBWEBP_TAG="$LIBWEBP_TAG"

LIBTIFF_REPO="$LIBTIFF_REPO"
LIBTIFF_TAG="$LIBTIFF_TAG"

FONTCONFIG_REPO="$FONTCONFIG_REPO"
FONTCONFIG_TAG="$FONTCONFIG_TAG"
EOF

echo "Wrote updated lock file: $LOCK_FILE"
