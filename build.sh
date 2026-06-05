#!/usr/bin/env bash
# Build all docs in parallel, tolerate failures, push final nginx image.
# Usage:
#   ./build.sh                  # build all, push nginx
#   ./build.sh --no-push        # build all, skip push
#   ./build.sh --slug flask      # rebuild one specific doc

set -euo pipefail

REGISTRY="${REGISTRY:-duncanal}"
CACHE_DIR="${CACHE_DIR:-/tmp/rtd-mirror-cache}"
PUSH=true
SINGLE_SLUG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-push)   PUSH=false; shift ;;
    --slug)      SINGLE_SLUG="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

mkdir -p "$CACHE_DIR"

CACHE_FLAGS=(
  --set "*.cache-from=type=local,src=$CACHE_DIR"
  --set "*.cache-to=type=local,dest=$CACHE_DIR,mode=max"
)

# ── Regenerate Dockerfiles + bake file from projects.yml ──────────────────────
echo "==> Generating Dockerfiles and bake file..."
python3 scripts/generate-bake.py --projects projects.yml

# ── If rebuilding a single slug, just do that then exit ───────────────────────
if [[ -n "$SINGLE_SLUG" ]]; then
  echo "==> Rebuilding $SINGLE_SLUG..."
  REGISTRY="$REGISTRY" docker buildx bake "$SINGLE_SLUG" --load "${CACHE_FLAGS[@]}"
  echo "Done. Re-run without --slug to rebuild nginx."
  exit 0
fi

# ── Build the base layer first (all docs depend on it) ────────────────────────
echo "==> Building base image..."
REGISTRY="$REGISTRY" docker buildx bake base --load "${CACHE_FLAGS[@]}"

# ── Build each doc target in parallel ─────────────────────────────────────────
echo "==> Building doc targets in parallel..."

all_slugs=($(python3 -c "
import yaml
sources = yaml.safe_load(open('projects.yml'))['sources']
print(' '.join(s['slug'] for s in sources if s.get('slug')))
"))

declare -A pids
for slug in "${all_slugs[@]}"; do
  echo "  Starting: $slug"
  REGISTRY="$REGISTRY" docker buildx bake "$slug" --load "${CACHE_FLAGS[@]}" \
    >"$CACHE_DIR/${slug}.log" 2>&1 &
  pids[$slug]=$!
done

# ── Wait for all, collect successes ───────────────────────────────────────────
echo "==> Waiting for doc builds..."
succeeded=()
failed=()
for slug in "${all_slugs[@]}"; do
  if wait "${pids[$slug]}"; then
    echo "  ✓ $slug"
    succeeded+=("$slug")
  else
    echo "  ✗ $slug (failed — see $CACHE_DIR/${slug}.log)"
    failed+=("$slug")
  fi
done

if [[ ${#failed[@]} -gt 0 ]]; then
  echo ""
  echo "WARNING: ${#failed[@]} doc(s) failed: ${failed[*]}"
  echo "         nginx will be built without them."
  echo ""
fi

if [[ ${#succeeded[@]} -eq 0 ]]; then
  echo "ERROR: All doc builds failed. Aborting." >&2
  exit 1
fi

# ── Regenerate Dockerfile.nginx with only the successful slugs ────────────────
echo "==> Regenerating Dockerfile.nginx for ${#succeeded[@]} successful docs..."
python3 scripts/generate-bake.py --projects projects.yml --nginx-slugs "${succeeded[@]}"

# ── Build and optionally push the final nginx image ───────────────────────────
echo "==> Building nginx image..."
REGISTRY="$REGISTRY" docker buildx bake nginx --load "${CACHE_FLAGS[@]}"

if [[ "$PUSH" == "true" ]]; then
  echo "==> Pushing ${REGISTRY}/rtd-mirror:latest..."
  docker push "${REGISTRY}/rtd-mirror:latest"
fi

echo ""
echo "Done! Included docs: ${succeeded[*]}"
[[ ${#failed[@]} -gt 0 ]] && echo "Skipped:       ${failed[*]}"
