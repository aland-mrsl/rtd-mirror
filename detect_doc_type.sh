#!/usr/bin/env bash
# scripts/detect-doc-type.sh
# ─────────────────────────────────────────────────────────────────────────────
# Probes a documentation site or RTD slug and recommends the correct
# projects.yml `type` entry to use.
#
# Usage:
#   ./scripts/detect-doc-type.sh <slug-or-url> [--verbose]
#
# Examples:
#   ./scripts/detect-doc-type.sh flask
#   ./scripts/detect-doc-type.sh https://docs.docker.com/build/
#   ./scripts/detect-doc-type.sh https://docs.pydantic.dev/latest/ --verbose
#
# Requirements: curl, python3
# Optional:     git (for deeper GitHub repo inspection)
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[~]${RESET} $*"; }
ok()      { echo -e "${GREEN}[✓]${RESET} $*"; }
warn()    { echo -e "${YELLOW}[!]${RESET} $*"; }
fail()    { echo -e "${RED}[✗]${RESET} $*"; }
section() { echo -e "\n${BOLD}── $* ──${RESET}"; }

VERBOSE=false
INPUT=""

for arg in "$@"; do
  case "$arg" in
    --verbose|-v) VERBOSE=true ;;
    *) INPUT="$arg" ;;
  esac
done

if [[ -z "${INPUT:-}" ]]; then
  echo "Usage: $0 <rtd-slug-or-url> [--verbose]"
  echo ""
  echo "  Slug examples:  flask  requests  celery"
  echo "  URL  examples:  https://docs.docker.com/build/"
  echo "                  https://docs.pydantic.dev/latest/"
  exit 1
fi

verbose() { [[ "$VERBOSE" == true ]] && info "$*" || true; }

# ── Helpers ───────────────────────────────────────────────────────────────────
http_status() {
  curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
    -A "Mozilla/5.0 (compatible; rtd-mirror-detector/1.0)" \
    -L "$1" 2>/dev/null || echo "000"
}

http_body() {
  curl -sL --max-time 15 \
    -A "Mozilla/5.0 (compatible; rtd-mirror-detector/1.0)" \
    "$1" 2>/dev/null || true
}

http_headers() {
  curl -sI --max-time 10 \
    -A "Mozilla/5.0 (compatible; rtd-mirror-detector/1.0)" \
    -L "$1" 2>/dev/null || true
}

# Extract final URL after redirects
final_url() {
  curl -sL --max-time 10 -o /dev/null -w "%{url_effective}" \
    -A "Mozilla/5.0 (compatible; rtd-mirror-detector/1.0)" \
    "$1" 2>/dev/null || echo "$1"
}

github_file_exists() {
  local owner="$1" repo="$2" path="$3"
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 8 \
    "https://raw.githubusercontent.com/${owner}/${repo}/main/${path}" 2>/dev/null || echo "000")
  [[ "$code" == "200" ]] && return 0
  # try master branch too
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 8 \
    "https://raw.githubusercontent.com/${owner}/${repo}/master/${path}" 2>/dev/null || echo "000")
  [[ "$code" == "200" ]] && return 0
  return 1
}

github_file_content() {
  local owner="$1" repo="$2" path="$3"
  for branch in main master; do
    local content
    content=$(curl -sL --max-time 10 \
      "https://raw.githubusercontent.com/${owner}/${repo}/${branch}/${path}" 2>/dev/null || true)
    if [[ -n "$content" && "$content" != "404: Not Found" ]]; then
      echo "$content"
      return 0
    fi
  done
  return 1
}

# ── Determine if input is URL or RTD slug ─────────────────────────────────────
RESULT_TYPE=""
RESULT_SLUG=""
RESULT_REPO=""
RESULT_BRANCH="main"
RESULT_EXTRA=""

is_url=false
if [[ "$INPUT" == http* ]]; then
  is_url=true
  TARGET_URL="$INPUT"
  # Derive a slug from the URL hostname + path
  RESULT_SLUG=$(echo "$INPUT" | python3 -c "
import sys
from urllib.parse import urlparse
u = urlparse(sys.stdin.read().strip())
host = u.hostname.replace('docs.','').replace('www.','').split('.')[0]
print(host)
")
else
  TARGET_URL="https://${INPUT}.readthedocs.io/en/stable/"
  RESULT_SLUG="$INPUT"
fi

echo -e "\n${BOLD}RTD Mirror — Doc Type Detector${RESET}"
echo -e "Input : ${CYAN}${INPUT}${RESET}"
echo -e "Slug  : ${CYAN}${RESULT_SLUG}${RESET}\n"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 1 — Check if it's on Read the Docs
# ─────────────────────────────────────────────────────────────────────────────
section "Step 1: Checking Read the Docs"

rtd_slug="$RESULT_SLUG"
if $is_url; then
  # Try to extract RTD slug from URL patterns
  if [[ "$INPUT" == *".readthedocs.io"* ]]; then
    rtd_slug=$(echo "$INPUT" | sed 's|https://||;s|\.readthedocs\.io.*||')
    info "URL looks like an RTD-hosted project (slug: $rtd_slug)"
  fi
fi

htmlzip_url="https://${rtd_slug}.readthedocs.io/_/downloads/en/stable/htmlzip/"
htmlzip_status=$(http_status "$htmlzip_url")
verbose "htmlzip probe → $htmlzip_url ($htmlzip_status)"

if [[ "$htmlzip_status" == "200" ]]; then
  ok "RTD htmlzip available → ${htmlzip_url}"
  RESULT_TYPE="rtd"
  RESULT_SLUG="$rtd_slug"
else
  # Also check the RTD API (may be rate-limited from CI, so soft fail)
  rtd_api_status=$(http_status "https://readthedocs.org/api/v2/project/?slug=${rtd_slug}")
  rtd_found=false
  if [[ "$rtd_api_status" == "200" ]]; then
    count=$(http_body "https://readthedocs.org/api/v2/project/?slug=${rtd_slug}" | \
      python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('count',0))" 2>/dev/null || echo "0")
    if [[ "$count" -gt "0" ]]; then
      rtd_found=true
      ok "Found on RTD API (count=$count) — but htmlzip may require auth/cookie"
      warn "htmlzip probe returned $htmlzip_status — may be behind login or IP-blocked"
      RESULT_TYPE="rtd"
      RESULT_SLUG="$rtd_slug"
    fi
  fi
  if ! $rtd_found; then
    warn "Not found on RTD (htmlzip=$htmlzip_status, API=$rtd_api_status)"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 2 — Find the GitHub source repo
# ─────────────────────────────────────────────────────────────────────────────
section "Step 2: Looking for a GitHub source repo"

GH_OWNER=""
GH_REPO=""

# Try to extract GitHub link from the docs site HTML
if [[ -z "$RESULT_TYPE" ]] || [[ "$VERBOSE" == true ]]; then
  probe_url="$TARGET_URL"
  body=$(http_body "$probe_url")
  gh_match=$(echo "$body" | python3 -c "
import sys, re
html = sys.stdin.read()
# Look for GitHub repo links in page source
patterns = [
    r'github\.com/([a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+)',
]
seen = set()
for p in patterns:
    for m in re.findall(p, html):
        if m not in seen and 'github' not in m.lower():
            seen.add(m)
            print(m)
" 2>/dev/null | head -3 || true)

  if [[ -n "$gh_match" ]]; then
    first_match=$(echo "$gh_match" | head -1)
    GH_OWNER=$(echo "$first_match" | cut -d/ -f1)
    GH_REPO=$(echo "$first_match" | cut -d/ -f2)
    ok "Found GitHub repo link in page: ${GH_OWNER}/${GH_REPO}"
  else
    verbose "No GitHub link found in page HTML — trying common patterns"
    # Try slug-based guesses for well-known projects
    declare -A KNOWN_REPOS=(
      ["flask"]="pallets/flask"
      ["requests"]="psf/requests"
      ["celery"]="celery/celery"
      ["sphinx"]="sphinx-doc/sphinx"
      ["fastapi"]="tiangolo/fastapi"
      ["pydantic"]="pydantic/pydantic"
      ["docker"]="docker/docs"
      ["kubernetes"]="kubernetes/website"
      ["ansible"]="ansible/ansible-documentation"
      ["numpy"]="numpy/numpy"
      ["pandas"]="pandas-dev/pandas"
      ["pytest"]="pytest-dev/pytest"
      ["sqlalchemy"]="sqlalchemy/sqlalchemy"
      ["django"]="django/django"
      ["mkdocs"]="mkdocs/mkdocs"
    )
    if [[ -n "${KNOWN_REPOS[$RESULT_SLUG]+_}" ]]; then
      full="${KNOWN_REPOS[$RESULT_SLUG]}"
      GH_OWNER=$(echo "$full" | cut -d/ -f1)
      GH_REPO=$(echo "$full" | cut -d/ -f2)
      ok "Known project → GitHub: ${GH_OWNER}/${GH_REPO}"
    else
      warn "Could not determine GitHub repo automatically"
      warn "Try searching: https://github.com/search?q=${RESULT_SLUG}+docs&type=repositories"
    fi
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 3 — Detect SSG from repo contents
# ─────────────────────────────────────────────────────────────────────────────
DETECTED_SSG=""

if [[ -n "$GH_OWNER" && -n "$GH_REPO" ]]; then
  section "Step 3: Detecting SSG in ${GH_OWNER}/${GH_REPO}"

  RESULT_REPO="https://github.com/${GH_OWNER}/${GH_REPO}"

  # Check for SSG config files in order of specificity
  ssg_checks=(
    "hugo.toml:hugo"
    "hugo.yaml:hugo"
    "hugo.yml:hugo"
    "config.toml:hugo"          # Hugo uses config.toml
    "mkdocs.yml:mkdocs"
    "mkdocs.yaml:mkdocs"
    "docs/mkdocs.yml:mkdocs"
    "docs/en/mkdocs.yml:mkdocs"
    "next.config.js:nextjs"
    "next.config.ts:nextjs"
    "next.config.mjs:nextjs"
    "docusaurus.config.js:docusaurus"
    "docusaurus.config.ts:docusaurus"
    "docs/conf.py:sphinx"
    "doc/conf.py:sphinx"
    "docs/source/conf.py:sphinx"
  )

  for check in "${ssg_checks[@]}"; do
    file="${check%%:*}"
    ssg="${check##*:}"
    if github_file_exists "$GH_OWNER" "$GH_REPO" "$file"; then
      ok "Found: ${file} → ${BOLD}${ssg}${RESET}"
      DETECTED_SSG="$ssg"
      # Capture the config file path for the YAML output
      case "$ssg" in
        mkdocs)  RESULT_EXTRA="config: ${file}" ;;
        hugo)    RESULT_EXTRA="# uses ${file}" ;;
        nextjs)  RESULT_EXTRA="build_cmd: \"npm ci && npm run build\"\n    out_dir: out" ;;
        sphinx)  RESULT_EXTRA="# Sphinx project — check if also on RTD for simpler htmlzip download" ;;
      esac
      break
    else
      verbose "  Not found: ${file}"
    fi
  done

  if [[ -z "$DETECTED_SSG" ]]; then
    warn "Could not detect SSG from known config files"
    # Check if it's a pure static site (no build step)
    verbose "Repo may be a pre-built static site or use an unusual SSG"
  fi

  # Determine best branch
  for branch in main master; do
    branch_status=$(http_status "https://github.com/${GH_OWNER}/${GH_REPO}/tree/${branch}")
    if [[ "$branch_status" == "200" ]]; then
      RESULT_BRANCH="$branch"
      verbose "Default branch: $branch"
      break
    fi
  done
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 4 — Resolve final type
# ─────────────────────────────────────────────────────────────────────────────
section "Step 4: Resolution"

# Override type based on SSG detection if we found one
if [[ -n "$DETECTED_SSG" && "$DETECTED_SSG" != "sphinx" ]]; then
  case "$DETECTED_SSG" in
    mkdocs)    RESULT_TYPE="git-mkdocs" ;;
    hugo)      RESULT_TYPE="git-hugo" ;;
    nextjs)    RESULT_TYPE="git-nextjs" ;;
    docusaurus) RESULT_TYPE="git-node" ;;
  esac
elif [[ -n "$DETECTED_SSG" && "$DETECTED_SSG" == "sphinx" ]]; then
  if [[ -z "$RESULT_TYPE" ]]; then
    RESULT_TYPE="rtd"  # Sphinx almost always means RTD-hosted
    warn "Sphinx detected in repo — project is likely on RTD. Verify: https://${RESULT_SLUG}.readthedocs.io/"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 5 — Print recommended projects.yml entry
# ─────────────────────────────────────────────────────────────────────────────
section "Recommended projects.yml entry"

if [[ -z "$RESULT_TYPE" ]]; then
  RESULT_TYPE="wget"
  warn "Could not determine type — falling back to wget (last resort)"
fi

echo ""
echo -e "${GREEN}# Detected: ${BOLD}${RESULT_TYPE}${RESET}"
echo ""

case "$RESULT_TYPE" in
  rtd)
    cat <<EOF
- type: rtd
  slug: ${RESULT_SLUG}
  version: stable
  formats: [htmlzip]
EOF
    ;;
  git-mkdocs)
    echo "- type: git-mkdocs"
    echo "  slug: ${RESULT_SLUG}"
    echo "  repo: ${RESULT_REPO}"
    echo "  branch: ${RESULT_BRANCH}"
    if [[ -n "$RESULT_EXTRA" ]]; then
      echo "  ${RESULT_EXTRA}"
    fi
    ;;
  git-hugo)
    echo "- type: git-hugo"
    echo "  slug: ${RESULT_SLUG}"
    echo "  repo: ${RESULT_REPO}"
    echo "  branch: ${RESULT_BRANCH}"
    echo "  hugo_version: \"latest\"   # pin to a specific version for reproducibility"
    ;;
  git-nextjs)
    echo "- type: git-nextjs"
    echo "  slug: ${RESULT_SLUG}"
    echo "  repo: ${RESULT_REPO}"
    echo "  branch: ${RESULT_BRANCH}"
    if [[ -n "$RESULT_EXTRA" ]]; then
      echo -e "  ${RESULT_EXTRA}"
    fi
    ;;
  wget)
    cat <<EOF
- type: wget
  slug: ${RESULT_SLUG}
  url: ${TARGET_URL}
  depth: 4
EOF
    ;;
esac

echo ""
echo -e "${YELLOW}Tip:${RESET} Run with --verbose to see all probe results"
echo -e "${YELLOW}Tip:${RESET} Always verify the output renders correctly before adding to projects.yml"
echo ""