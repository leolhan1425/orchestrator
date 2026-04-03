#!/usr/bin/env bash
set -euo pipefail

# review.sh — Standalone review agent for an existing branch
# Usage:
#   review.sh <project> <branch>
#   review.sh voila-pcr feature/dark-mode

PROJECTS_DIR="$HOME/projects"
LOG_DIR="$HOME/.claude/agent-logs"
REVIEW_BUDGET=3

# ─── Colors ───
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${BLUE}[review]${NC} $*"; }
ok()   { echo -e "${GREEN}[review]${NC} $*"; }
warn() { echo -e "${YELLOW}[review]${NC} $*"; }
err()  { echo -e "${RED}[review]${NC} $*" >&2; }

if [[ $# -lt 2 ]]; then
  echo "Usage: review.sh <project> <branch>"
  echo "Example: review.sh voila-pcr feature/dark-mode"
  exit 1
fi

PROJECT="$1"
BRANCH="$2"
PROJ_DIR="$PROJECTS_DIR/$PROJECT"

if [[ ! -d "$PROJ_DIR/.git" ]]; then
  err "Not a git repo: $PROJ_DIR"
  exit 1
fi

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
LOG_FILE="$LOG_DIR/${PROJECT}-review-${TIMESTAMP}.log"
SLUG=$(echo "$BRANCH" | tr '[:upper:]/' '[:lower:]-' | sed 's/[^a-z0-9-]/-/g' | cut -c1-40)

REVIEW_PROMPT=$(cat <<PROMPT
You are a review agent. Review the changes on branch "$BRANCH".

1. Run: git fetch origin && git checkout "$BRANCH"
2. Read CLAUDE.md (if it exists) to understand the project.
3. Review ALL changes on this branch (use git diff main..HEAD or similar).
4. Apply this engineering review checklist:
   - ARCHITECTURE: Does this fit the project's existing patterns?
   - CODE QUALITY: Naming, duplication, complexity.
   - EDGE CASES: Null/empty inputs, error states, boundary conditions.
   - SECURITY: No XSS, injection, auth bypasses, exposed secrets.
   - PERFORMANCE: No unnecessary re-renders, N+1 queries, unbounded loops.
   - BREAKING CHANGES: Does existing functionality still work?
5. Run ALL existing tests.
6. FIX any issues you find. Commit fixes separately.
7. If tests fail, fix the code until they pass.
8. If you find a CRITICAL issue you cannot fix, open a DRAFT PR with label "needs-human".
9. Otherwise open a regular PR with review findings in the body.
10. As your FINAL line, print: PR:<url>
PROMPT
)

log "Reviewing branch '$BRANCH' on $PROJECT..."
log "Log: $LOG_FILE"

OUTPUT=$(claude --print \
  --worktree "review/${SLUG}" \
  --dangerously-skip-permissions \
  --max-budget-usd "$REVIEW_BUDGET" \
  --append-system-prompt "$REVIEW_PROMPT" \
  -p "Review branch $BRANCH. Follow your system instructions exactly." \
  --cwd "$PROJ_DIR" \
  2>&1) || true

echo "$OUTPUT" > "$LOG_FILE"

PR_URL=$(echo "$OUTPUT" | grep -E '^(PR|DRAFT_PR):' | tail -1 | sed 's/^PR://' | sed 's/^DRAFT_PR://')
if [[ -n "$PR_URL" ]]; then
  if echo "$OUTPUT" | grep -q '^DRAFT_PR:'; then
    warn "Draft PR (needs human review): $PR_URL"
  else
    ok "PR created: $PR_URL"
  fi
else
  warn "No PR URL found. Check log: $LOG_FILE"
fi

# Cleanup
git -C "$PROJ_DIR" worktree remove "review/${SLUG}" --force 2>/dev/null || true
git -C "$PROJ_DIR" worktree prune 2>/dev/null || true

ok "Review complete. Log: $LOG_FILE"
