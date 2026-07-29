#!/bin/sh
# SessionStart: sync this repo AND the auto-memory repo with origin before any work.
#
# Leo works from two Macs. On 2026-07-27 a session on the other Mac had stale memory
# and rebuilt a project against rules it could not see; the cost was a compliance
# drift, not a merge conflict. Fresh code is not enough  -  memory has to be fresh too.
#
# This is the PORTABLE hook: it travels with the repo via git, so it works on a machine
# that was never configured, and it is deliberately SELF-SUFFICIENT  -  it pulls the
# memory repo itself rather than assuming a global hook exists. On a machine that does
# have ~/.claude/hooks/session-git-sync.sh (which does strictly more: all-repo drift
# scan, standing-rule injection), this steps aside to avoid duplicate fetches.
#
# Never blocks a session: no-ops on non-git / no-upstream / already-current, and never
# touches a dirty or diverged tree (it warns instead). Always exits 0.
[ -x "$HOME/.claude/hooks/session-git-sync.sh" ] && exit 0
export GIT_TERMINAL_PROMPT=0
NOTE=""

# --- auto-memory repo, found by glob so it works whatever the home path is ----------
for mem in "$HOME"/.claude/projects/*/memory; do
  [ -d "$mem/.git" ] || continue
  before=$(git -C "$mem" rev-parse HEAD 2>/dev/null)
  if git -C "$mem" pull --ff-only -q 2>/dev/null; then
    after=$(git -C "$mem" rev-parse HEAD 2>/dev/null)
    if [ -n "$before" ] && [ "$before" != "$after" ]; then
      n=$(git -C "$mem" rev-list --count "$before..$after" 2>/dev/null)
      NOTE="Auto-memory was just updated with $n commit(s) from the other machine, so \
memories recalled in this session may predate them  -  re-read any memory file you rely \
on before acting on it. "
    fi
  else
    NOTE="WARNING: the auto-memory repo could not be fast-forwarded (offline, or it has \
diverged). Memory may be STALE and may be missing decisions made on the other machine  -  \
say so before relying on it. "
  fi
done

# --- this repo ----------------------------------------------------------------------
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { [ -n "$NOTE" ] && printf \
  '{"systemMessage":"git: memory synced","hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' "$NOTE"; exit 0; }
git fetch -q --no-tags 2>/dev/null || exit 0
ab=$(git rev-list --left-right --count '@{u}...HEAD' 2>/dev/null) || exit 0
behind=$(printf '%s' "$ab" | awk '{print $1}')
ahead=$(printf '%s' "$ab" | awk '{print $2}')
branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)

if [ "${behind:-0}" -eq 0 ] 2>/dev/null; then
  [ -n "$NOTE" ] && printf \
    '{"systemMessage":"git: memory synced, %s current","hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' "$branch" "$NOTE"
  exit 0
fi

# Let git itself decide whether a dirty file is in the way: a fast-forward that would
# clobber local edits is refused by git, while one that touches unrelated files
# succeeds. Blanket-refusing on any dirty file made this hook useless in repos that
# always carry a regenerated artifact (voila-pcr/blot's sitemap.xml).
if [ "${ahead:-0}" -eq 0 ]; then
  if git merge --ff-only -q '@{u}' 2>/dev/null; then
    files=$(git diff --name-only 'HEAD@{1}' HEAD 2>/dev/null | head -15 | tr '\n' ' ')
    printf '{"systemMessage":"git: fast-forwarded %s +%s from origin","hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%sThis repo was just fast-forwarded +%s commit(s) from origin. Changed files: %s. READ the ones relevant to your task, and any HANDOFF_*.md, BEFORE editing anything."}}\n' \
      "$branch" "$behind" "$NOTE" "$behind" "$files"
  else
    printf '{"systemMessage":"git: %s is %s behind, ff refused (local edit in the way)","hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%sThis repo is %s commit(s) behind origin and git refused the fast-forward because a local edit would be overwritten. Reconcile with the user before editing files here."}}\n' \
      "$branch" "$behind" "$NOTE" "$behind"
  fi
else
  printf '{"systemMessage":"git: %s is %s behind origin, NOT pulled  -  reconcile","hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%sThis repo is %s commit(s) behind origin and could NOT be fast-forwarded: it has unpushed commits, or a local edit would be overwritten by the incoming changes. Do NOT edit files here until this is reconciled with the user."}}\n' \
    "$branch" "$behind" "$NOTE" "$behind"
fi
exit 0
