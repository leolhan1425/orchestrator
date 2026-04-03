#!/usr/bin/env bash
set -euo pipefail

# orchestrate.sh — Two-pass AI agent dispatcher for project portfolio
# Usage:
#   orchestrate.sh <project> "directive"
#   orchestrate.sh --group <group> "directive"
#   orchestrate.sh --quick <project> "directive"       (skip review pass)
#   orchestrate.sh --budget <N> <project> "directive"   (custom budget)

PROJECTS_DIR="$HOME/projects"
CONFIG="$HOME/.claude/project-groups.json"
LOG_DIR="$HOME/.claude/agent-logs"
MAX_CONCURRENT=3
BUILD_BUDGET=5
REVIEW_BUDGET=3
QUICK=false
GROUP=""

# ─── Colors ───
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${BLUE}[orchestrate]${NC} $*"; }
ok()   { echo -e "${GREEN}[orchestrate]${NC} $*"; }
warn() { echo -e "${YELLOW}[orchestrate]${NC} $*"; }
err()  { echo -e "${RED}[orchestrate]${NC} $*" >&2; }

usage() {
  cat <<'EOF'
Usage:
  orchestrate.sh [options] <project> "directive"
  orchestrate.sh [options] --group <group> "directive"

Options:
  --quick          Skip review pass (for trivial changes)
  --budget <N>     Set build agent budget in USD (default: 5)
  --group <name>   Run on all projects in a group (voila, trackers, web, all)
  -h, --help       Show this help

Examples:
  orchestrate.sh voila-pcr "Add a CSV export button"
  orchestrate.sh --group voila "Update footer to 2026"
  orchestrate.sh --quick voilascience "Fix typo on about page"
  orchestrate.sh --budget 10 voila-pcr "Major dashboard refactor"
EOF
  exit 0
}

# ─── Parse arguments ───
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case $1 in
    --quick)   QUICK=true; shift ;;
    --budget)  BUILD_BUDGET="$2"; shift 2 ;;
    --group)   GROUP="$2"; shift 2 ;;
    -h|--help) usage ;;
    *)         POSITIONAL+=("$1"); shift ;;
  esac
done

if [[ -n "$GROUP" ]]; then
  DIRECTIVE="${POSITIONAL[0]:-}"
else
  PROJECT="${POSITIONAL[0]:-}"
  DIRECTIVE="${POSITIONAL[1]:-}"
fi

if [[ -z "$DIRECTIVE" ]]; then
  err "Missing directive. Run with --help for usage."
  exit 1
fi

# ─── Pre-flight checks ───
preflight() {
  if ! command -v claude &>/dev/null; then
    err "claude CLI not found. Install Claude Code first."
    exit 1
  fi
  if ! gh auth status &>/dev/null 2>&1; then
    err "GitHub CLI not authenticated. Run: gh auth login"
    exit 1
  fi
  if [[ ! -f "$CONFIG" ]]; then
    err "Project config not found at $CONFIG"
    exit 1
  fi
}

validate_project() {
  local proj="$1"
  local proj_dir="$PROJECTS_DIR/$proj"

  if [[ ! -d "$proj_dir" ]]; then
    err "Project directory not found: $proj_dir"
    return 1
  fi
  if [[ ! -d "$proj_dir/.git" ]]; then
    err "Not a git repo: $proj_dir"
    return 1
  fi
  if ! git -C "$proj_dir" remote get-url origin &>/dev/null; then
    err "No GitHub remote for $proj. Set one up: git remote add origin <url>"
    return 1
  fi
  return 0
}

# ─── Build agent system prompt ───
build_prompt() {
  local directive="$1"
  cat <<PROMPT
You are a build agent working autonomously. Follow these steps exactly:

1. Read CLAUDE.md (if it exists) to understand the project.
2. Implement the following directive:
   $directive
3. Run any existing tests (look for package.json scripts, Playwright configs, pytest, etc.). Fix failures.
4. Stage and commit all changes with a clear, descriptive commit message.
5. Push the branch to origin.
6. As your ABSOLUTE FINAL line of output, print ONLY the branch name in this exact format:
   BRANCH:<branch-name>

Do NOT open a pull request. Just implement, test, commit, push, and output the branch name.
PROMPT
}

# ─── Review agent system prompt ───
review_prompt() {
  local directive="$1"
  local branch="$2"
  local build_summary="$3"
  cat <<PROMPT
You are a review agent. A build agent just implemented a change on branch "$branch".

The original directive was:
  $directive

Your job:
1. Run: git fetch origin && git checkout "$branch"
2. Read CLAUDE.md (if it exists) to understand the project.
3. Review ALL changes on this branch (use git diff main..HEAD or similar).
4. Apply this engineering review checklist:
   - ARCHITECTURE: Does this fit the project's existing patterns?
   - CODE QUALITY: Naming, duplication, complexity. Flag anything questionable.
   - EDGE CASES: Null/empty inputs, error states, boundary conditions.
   - SECURITY: No XSS, injection, auth bypasses, exposed secrets, unsafe evals.
   - PERFORMANCE: No unnecessary re-renders, N+1 queries, unbounded loops.
   - BREAKING CHANGES: Does existing functionality still work?
5. Run ALL existing tests. If the project has Playwright, run those. If no tests exist for the changed functionality, write basic smoke tests.
6. FIX any issues you find. Commit fixes separately with clear messages like "review: fix XSS in ..." or "review: add missing null check".
7. If tests fail, fix the code until they pass.
8. If you find a CRITICAL architectural issue you cannot fix, open a DRAFT PR with the label "needs-human":
   gh pr create --draft --label "needs-human" --title "..." --body "..."
   Then output: DRAFT_PR:<url>
   And stop.
9. If everything looks good (or you fixed all issues), open a regular PR:
   gh pr create --title "<concise title>" --body "\$(cat <<'PRBODY'
## Summary
<what was built>

## Review Findings
<what the review agent checked, any issues found and fixed>

## Test Results
<which tests ran, pass/fail>

## Caveats
<any warnings for human reviewer, or "None">
PRBODY
)"
10. As your ABSOLUTE FINAL line of output, print the PR URL in this exact format:
    PR:<url>
PROMPT
}

# ─── Quick mode prompt (single pass, build + PR) ───
quick_prompt() {
  local directive="$1"
  cat <<PROMPT
You are a build agent working autonomously. Follow these steps exactly:

1. Read CLAUDE.md (if it exists) to understand the project.
2. Implement the following directive:
   $directive
3. Run any existing tests. Fix failures.
4. Stage and commit all changes with a clear commit message.
5. Push the branch to origin.
6. Open a PR:
   gh pr create --title "<concise title>" --body "\$(cat <<'PRBODY'
## Summary
<what was changed and why>

## Test Results
<which tests ran, or "no tests found">
PRBODY
)"
7. As your ABSOLUTE FINAL line of output, print the PR URL in this exact format:
   PR:<url>
PROMPT
}

# ─── Run pipeline for a single project ───
run_pipeline() {
  local proj="$1"
  local directive="$2"
  local proj_dir="$PROJECTS_DIR/$proj"
  local timestamp
  timestamp=$(date +%Y%m%d-%H%M%S)
  local log_file="$LOG_DIR/${proj}-${timestamp}.log"
  local slug
  slug=$(echo "$directive" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | cut -c1-40)

  log "[$proj] Starting pipeline..."
  log "[$proj] Log: $log_file"

  if ! validate_project "$proj"; then
    return 1
  fi

  if [[ "$QUICK" == "true" ]]; then
    # ─── Quick mode: single pass ───
    log "[$proj] Quick mode — single pass (no review)"
    local output
    output=$(claude --print \
      --worktree "agent/${slug}" \
      --dangerously-skip-permissions \
      --max-budget-usd "$BUILD_BUDGET" \
      --append-system-prompt "$(quick_prompt "$directive")" \
      -p "$directive" \
      --cwd "$proj_dir" \
      2>&1) || true

    echo "$output" > "$log_file"

    local pr_url
    pr_url=$(echo "$output" | grep '^PR:' | tail -1 | sed 's/^PR://')
    if [[ -n "$pr_url" ]]; then
      ok "[$proj] PR created: $pr_url"
    else
      warn "[$proj] No PR URL found in output. Check log: $log_file"
    fi

    # Cleanup worktree
    git -C "$proj_dir" worktree remove "agent/${slug}" --force 2>/dev/null || true
    git -C "$proj_dir" worktree prune 2>/dev/null || true

    return 0
  fi

  # ─── Pass 1: Build Agent ───
  log "[$proj] Pass 1/2 — Build agent starting..."
  local build_output
  build_output=$(claude --print \
    --worktree "agent/${slug}" \
    --dangerously-skip-permissions \
    --max-budget-usd "$BUILD_BUDGET" \
    --append-system-prompt "$(build_prompt "$directive")" \
    -p "$directive" \
    --cwd "$proj_dir" \
    2>&1) || true

  echo "=== PASS 1: BUILD ===" > "$log_file"
  echo "$build_output" >> "$log_file"

  # Extract branch name
  local branch
  branch=$(echo "$build_output" | grep '^BRANCH:' | tail -1 | sed 's/^BRANCH://')
  if [[ -z "$branch" ]]; then
    err "[$proj] Build agent did not output a branch name. Check log: $log_file"
    # Cleanup
    git -C "$proj_dir" worktree remove "agent/${slug}" --force 2>/dev/null || true
    git -C "$proj_dir" worktree prune 2>/dev/null || true
    return 1
  fi

  log "[$proj] Build agent pushed branch: $branch"

  # Cleanup build worktree before review
  git -C "$proj_dir" worktree remove "agent/${slug}" --force 2>/dev/null || true

  # ─── Pass 2: Review Agent ───
  log "[$proj] Pass 2/2 — Review agent starting on branch $branch..."
  local review_output
  review_output=$(claude --print \
    --worktree "review/${slug}" \
    --dangerously-skip-permissions \
    --max-budget-usd "$REVIEW_BUDGET" \
    --append-system-prompt "$(review_prompt "$directive" "$branch" "")" \
    -p "Review and QA the changes on branch $branch. Follow your system instructions exactly." \
    --cwd "$proj_dir" \
    2>&1) || true

  echo "" >> "$log_file"
  echo "=== PASS 2: REVIEW ===" >> "$log_file"
  echo "$review_output" >> "$log_file"

  # Extract PR URL
  local pr_url
  pr_url=$(echo "$review_output" | grep -E '^(PR|DRAFT_PR):' | tail -1 | sed 's/^PR://' | sed 's/^DRAFT_PR://')
  if [[ -n "$pr_url" ]]; then
    if echo "$review_output" | grep -q '^DRAFT_PR:'; then
      warn "[$proj] Draft PR (needs human review): $pr_url"
    else
      ok "[$proj] PR created: $pr_url"
    fi
  else
    warn "[$proj] No PR URL found in review output. Check log: $log_file"
  fi

  # Cleanup review worktree
  git -C "$proj_dir" worktree remove "review/${slug}" --force 2>/dev/null || true
  git -C "$proj_dir" worktree prune 2>/dev/null || true

  ok "[$proj] Pipeline complete. Log: $log_file"
}

# ─── Get projects from a group ───
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

# ─── Main ───
preflight

if [[ -n "$GROUP" ]]; then
  # Group mode: run pipelines in parallel
  PROJECTS=$(get_group_projects "$GROUP") || exit 1
  PROJECT_COUNT=$(echo "$PROJECTS" | wc -l | tr -d ' ')
  log "Running on group '$GROUP' ($PROJECT_COUNT projects, max $MAX_CONCURRENT concurrent)..."

  # Run with concurrency limit
  PIDS=()
  RUNNING=0
  while IFS= read -r proj; do
    [[ -z "$proj" ]] && continue

    run_pipeline "$proj" "$DIRECTIVE" &
    PIDS+=($!)
    ((RUNNING++))

    # Wait if we hit the concurrency limit
    if (( RUNNING >= MAX_CONCURRENT )); then
      wait -n 2>/dev/null || true
      ((RUNNING--))
    fi
  done <<< "$PROJECTS"

  # Wait for remaining
  for pid in "${PIDS[@]}"; do
    wait "$pid" 2>/dev/null || true
  done

  ok "All pipelines complete."
else
  # Single project mode
  if [[ -z "$PROJECT" ]]; then
    err "No project specified. Run with --help for usage."
    exit 1
  fi
  run_pipeline "$PROJECT" "$DIRECTIVE"
fi
