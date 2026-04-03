#!/usr/bin/env bash
set -euo pipefail

# deploy-all.sh — Unified deployment with optional PR merge + health checks
# Usage:
#   deploy-all.sh <project>                  Deploy current main
#   deploy-all.sh --pr <N> <project>         Merge PR #N, then deploy
#   deploy-all.sh --group <group>            Deploy all projects in a group

PROJECTS_DIR="$HOME/projects"
CONFIG="$HOME/.claude/project-groups.json"
VPS="root@89.167.19.159"
PR_NUM=""
GROUP=""

# ─── Colors ───
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${BLUE}[deploy]${NC} $*"; }
ok()   { echo -e "${GREEN}[deploy]${NC} $*"; }
warn() { echo -e "${YELLOW}[deploy]${NC} $*"; }
err()  { echo -e "${RED}[deploy]${NC} $*" >&2; }

usage() {
  cat <<'EOF'
Usage:
  deploy-all.sh [options] <project>
  deploy-all.sh [options] --group <group>

Options:
  --pr <N>         Merge PR #N before deploying
  --group <name>   Deploy all projects in a group
  -h, --help       Show this help

Examples:
  deploy-all.sh voila-pcr
  deploy-all.sh --pr 12 voila-pcr
  deploy-all.sh --group voila
EOF
  exit 0
}

# ─── Parse arguments ───
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case $1 in
    --pr)    PR_NUM="$2"; shift 2 ;;
    --group) GROUP="$2"; shift 2 ;;
    -h|--help) usage ;;
    *)       POSITIONAL+=("$1"); shift ;;
  esac
done

PROJECT="${POSITIONAL[0]:-}"

# ─── Lookup project metadata ───
get_project_domain() {
  local proj="$1"
  python3 -c "
import json
with open('$CONFIG') as f:
    cfg = json.load(f)
info = cfg.get('projects', {}).get('$proj', {})
print(info.get('domain', ''))
"
}

get_project_repo() {
  local proj="$1"
  python3 -c "
import json
with open('$CONFIG') as f:
    cfg = json.load(f)
info = cfg.get('projects', {}).get('$proj', {})
print(info.get('repo', ''))
"
}

get_group_projects() {
  local group="$1"
  python3 -c "
import json, sys
with open('$CONFIG') as f:
    cfg = json.load(f)
projects = cfg.get('groups', {}).get('$group', [])
if not projects:
    print('ERROR: Unknown group: $group', file=sys.stderr)
    sys.exit(1)
print('\n'.join(projects))
"
}

# ─── Health check ───
health_check() {
  local proj="$1"
  local domain
  domain=$(get_project_domain "$proj")

  if [[ -z "$domain" ]]; then
    warn "[$proj] No domain configured, skipping health check"
    return 0
  fi

  log "[$proj] Health check: https://$domain ..."
  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "https://$domain" 2>/dev/null || echo "000")

  if [[ "$http_code" == "200" ]]; then
    ok "[$proj] Healthy (HTTP $http_code) - https://$domain"
    return 0
  else
    err "[$proj] Unhealthy (HTTP $http_code) - https://$domain"
    return 1
  fi
}

# ─── Deploy a single project ───
deploy_project() {
  local proj="$1"
  local pr="${2:-}"
  local proj_dir="$PROJECTS_DIR/$proj"

  if [[ ! -d "$proj_dir" ]]; then
    err "[$proj] Project directory not found: $proj_dir"
    return 1
  fi

  # Merge PR if specified
  if [[ -n "$pr" ]]; then
    local repo
    repo=$(get_project_repo "$proj")
    if [[ -z "$repo" ]]; then
      err "[$proj] No repo configured in project-groups.json"
      return 1
    fi
    log "[$proj] Merging PR #$pr on $repo..."
    if ! gh pr merge "$pr" --repo "$repo" --merge; then
      err "[$proj] Failed to merge PR #$pr"
      return 1
    fi
    ok "[$proj] PR #$pr merged"
  fi

  # Pull latest
  log "[$proj] Pulling latest main..."
  git -C "$proj_dir" checkout main 2>/dev/null || git -C "$proj_dir" checkout master 2>/dev/null || true
  git -C "$proj_dir" pull origin 2>/dev/null || true

  # Run deploy.sh
  if [[ -f "$proj_dir/deploy.sh" ]]; then
    log "[$proj] Running deploy.sh..."
    if bash "$proj_dir/deploy.sh"; then
      ok "[$proj] Deploy script completed"
    else
      err "[$proj] Deploy script failed"
      return 1
    fi
  else
    err "[$proj] No deploy.sh found in $proj_dir"
    return 1
  fi

  # Health check (give the service a moment to start)
  sleep 3
  health_check "$proj"
}

# ─── Main ───
if [[ -n "$GROUP" ]]; then
  PROJECTS=$(get_group_projects "$GROUP") || exit 1
  log "Deploying group '$GROUP'..."

  FAILED=0
  while IFS= read -r proj; do
    [[ -z "$proj" ]] && continue
    deploy_project "$proj" "" || ((FAILED++))
  done <<< "$PROJECTS"

  if (( FAILED > 0 )); then
    err "$FAILED deployment(s) failed"
    exit 1
  fi
  ok "All deployments complete."
else
  if [[ -z "$PROJECT" ]]; then
    err "No project specified. Run with --help for usage."
    exit 1
  fi
  deploy_project "$PROJECT" "$PR_NUM"
fi
