#!/bin/sh
# SessionStart: sync this repo with origin before any work begins.
# Leo works from two Macs; a stale clone caused real misalignment (2026-07-28).
#
# This is the PORTABLE fallback — it travels with the repo via git, so it works
# on any machine, even one that has not been configured yet. On a machine with
# the global hook (~/.claude/hooks/session-git-sync.sh) that hook does strictly
# more (memory repo, all-repo scan, standing rule), so this one steps aside.
#
# Never blocks a session: no-ops on non-git / no-upstream / already-current, and
# never touches a dirty or diverged tree (it warns instead). Always exits 0.
[ -x "$HOME/.claude/hooks/session-git-sync.sh" ] && exit 0
export GIT_TERMINAL_PROMPT=0
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0
git fetch -q --no-tags 2>/dev/null || exit 0
ab=$(git rev-list --left-right --count '@{u}...HEAD' 2>/dev/null) || exit 0
behind=$(printf '%s' "$ab" | awk '{print $1}')
ahead=$(printf '%s' "$ab" | awk '{print $2}')
branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
[ "${behind:-0}" -gt 0 ] || exit 0
if [ "${ahead:-0}" -eq 0 ] && [ -z "$(git status --porcelain 2>/dev/null)" ]; then
  if git merge --ff-only -q '@{u}' 2>/dev/null; then
    files=$(git diff --name-only 'HEAD@{1}' HEAD 2>/dev/null | head -15 | tr '\n' ' ')
    printf '{"systemMessage":"git: fast-forwarded %s +%s from origin","hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"This repo was just fast-forwarded +%s commit(s) from origin. Changed files: %s. READ the ones relevant to your task (and any HANDOFF_*.md) BEFORE editing anything."}}\n' \
      "$branch" "$behind" "$behind" "$files"
  fi
else
  printf '{"systemMessage":"git: %s is %s behind origin, NOT pulled (dirty/diverged)","hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"This repo is %s commit(s) behind origin and was NOT auto-pulled because the tree is dirty or diverged. Reconcile with the user before editing files here."}}\n' \
    "$branch" "$behind" "$behind"
fi
exit 0
