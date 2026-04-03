# Orchestrator

A lightweight two-pass AI agent pipeline for managing multiple projects with near-zero input. Built on top of [Claude Code](https://claude.ai/code)'s native capabilities — no frameworks, no SaaS, just three shell scripts.

You say what you want. Agents build it, review it, test it, and open a PR. You merge when you're happy.

## How It Works

Every task goes through two independent Claude Code agents:

```
You: "Add dark mode to the header"
         │
         ▼
┌─────────────────┐
│  Pass 1: BUILD  │  Implements the change in an isolated git worktree.
│                 │  Runs existing tests. Commits and pushes.
└────────┬────────┘
         │ branch name handoff
         ▼
┌─────────────────┐
│ Pass 2: REVIEW  │  Fresh agent reviews the code against an engineering
│                 │  checklist. Runs/writes tests. Fixes issues.
│                 │  Opens a PR with review findings in the body.
└────────┬────────┘
         │
         ▼
   GitHub PR ready for you to review
```

The review agent has **fresh context** — it sees the code like a new reviewer, not the person who wrote it. This catches bugs the build agent can't see in its own work.

## Quick Start

### Prerequisites

- [Claude Code](https://claude.ai/code) CLI installed and authenticated
- [GitHub CLI](https://cli.github.com/) (`gh`) installed and authenticated
- `tmux` (optional, for monitoring agents): `brew install tmux`

### Install

```bash
# Clone
git clone https://github.com/leolhan1425/orchestrator.git
cd orchestrator

# Copy scripts to your PATH
cp orchestrate.sh deploy-all.sh review.sh ~/bin/
chmod +x ~/bin/orchestrate.sh ~/bin/deploy-all.sh ~/bin/review.sh

# Set up your project registry
cp project-groups.example.json ~/.claude/project-groups.json
# Edit ~/.claude/project-groups.json with your own projects

# Create log directory
mkdir -p ~/.claude/agent-logs
```

### Configure Your Projects

Edit `~/.claude/project-groups.json`:

```json
{
  "groups": {
    "frontend": ["app-web", "marketing-site"],
    "backend": ["api-server", "worker"],
    "all": ["app-web", "marketing-site", "api-server", "worker"]
  },
  "projects": {
    "app-web":        { "domain": "app.example.com",  "port": 3000, "repo": "you/app-web" },
    "api-server":     { "domain": "api.example.com",  "port": 8080, "repo": "you/api-server" },
    "marketing-site": { "domain": "example.com",      "port": null, "repo": "you/marketing-site" },
    "worker":         { "domain": null,                "port": 9090, "repo": "you/worker" }
  }
}
```

Each project must:
- Live in `~/projects/<name>/`
- Be a git repo with a GitHub remote
- Have a `deploy.sh` in the project root (for `deploy-all.sh`)

## Usage

### orchestrate.sh — Build + Review Pipeline

```bash
# Full pipeline: build agent implements, review agent QAs, PR opens
orchestrate.sh my-project "Add a CSV export button to the results table"

# Quick mode: skip the review pass (for trivial changes)
orchestrate.sh --quick my-project "Fix typo: 'recieve' -> 'receive'"

# Fan out across a group of projects
orchestrate.sh --group frontend "Update footer copyright to 2026"

# Custom budget (default: $5 build + $3 review)
orchestrate.sh --budget 10 my-project "Major dashboard refactor"
```

**What happens:**
1. Pre-flight checks (project exists, `gh` is authenticated, GitHub remote exists)
2. **Build agent** implements the change in an isolated worktree, runs tests, pushes the branch
3. **Review agent** checks out that branch in a separate worktree and runs an engineering review:
   - Architecture fit
   - Code quality
   - Edge cases & error handling
   - Security (XSS, injection, auth)
   - Performance
   - Breaking changes
   - Runs/writes tests
4. Review agent fixes any issues it finds, then opens a PR with review notes in the body
5. Both worktrees are cleaned up automatically
6. PR URL is printed to your terminal

If the review agent finds a critical unfixable issue, it opens a **draft PR** with a `needs-human` label instead.

### deploy-all.sh — Deploy with Health Checks

```bash
# Deploy current main
deploy-all.sh my-project

# Merge a PR first, then deploy
deploy-all.sh --pr 12 my-project

# Deploy an entire group
deploy-all.sh --group frontend
```

Runs your project's `deploy.sh`, then checks the domain returns HTTP 200.

### review.sh — Standalone Review

```bash
# Review a branch you made yourself (interactively with Claude Code)
review.sh my-project feature/dark-mode
```

Same review checklist as the orchestrate.sh review pass, but for branches you've already created. Useful when you've been coding interactively and want a quality check before merging.

## Day-to-Day Workflow

**Morning (2 min):** Check GitHub for PRs from overnight agents. Each PR body has what was built, what the review found, and test results. Merge the good ones.

**Working:** Fire off tasks as you think of them:
```bash
orchestrate.sh my-app "Add dark mode toggle"
orchestrate.sh --group backend "Add /health endpoints"
orchestrate.sh --quick docs-site "Fix broken link on getting started page"
```

**Deploy:**
```bash
deploy-all.sh --pr 15 my-app
```

## What to Send to Agents vs. Do Yourself

**Good for orchestrate.sh:**
- Self-contained features (UI components, API endpoints, export buttons)
- Cross-project consistency (`--group all "update dependencies"`)
- Boring work (SEO tags, footer updates, dependency bumps)
- Blog/content generation
- Test coverage improvements

**Keep doing interactively:**
- Anything needing secrets or credentials (Stripe setup, DB migrations)
- Architectural decisions that need your judgment
- Deploy configuration (Caddy, systemd, DNS)
- Anything requiring physical assets (images, data files)

## Architecture

```
~/bin/
  orchestrate.sh          # Core two-pass dispatcher
  deploy-all.sh           # Unified deploy + health check
  review.sh               # Standalone review agent

~/.claude/
  project-groups.json     # Project registry (groups + domains)
  agent-logs/             # Timestamped logs from every agent run
    voila-pcr-20260402-091523.log
    ...
```

### How Branch Handoff Works

The build agent's system prompt requires it to output `BRANCH:<name>` as its final line. The script greps for this to extract the branch name and pass it to the review agent. The review agent launches in its own worktree and checks out the pushed branch.

### Concurrency

Group operations run up to 3 pipelines in parallel (configurable via `MAX_CONCURRENT` in orchestrate.sh). For same-repo tasks, run them sequentially to avoid worktree conflicts.

### Cost Controls

| Mode | Build Agent | Review Agent | Total |
|------|-------------|-------------|-------|
| Full pipeline | $5 max | $3 max | $2-8 |
| Quick mode | $5 max | skipped | $0.50-3 |

Override with `--budget <N>`. All budgets use Claude Code's `--max-budget-usd` flag.

## Review Checklist

The review agent applies this checklist (embedded in its system prompt):

1. **Architecture** — Does this fit the project's existing patterns?
2. **Code Quality** — Naming, duplication, complexity
3. **Edge Cases** — Null/empty inputs, error states, boundary conditions
4. **Security** — No XSS, injection, auth bypasses, exposed secrets
5. **Performance** — No unnecessary re-renders, N+1 queries, unbounded loops
6. **Breaking Changes** — Does existing functionality still work?
7. **Tests** — Run existing tests; write smoke tests if none exist for changed functionality
8. **Fix** — Fix issues found, commit separately with clear messages
9. **Gate** — Only open the PR if tests pass and no critical issues remain

## Logs

Every agent run is logged to `~/.claude/agent-logs/<project>-<timestamp>.log`. Full pipeline runs have both passes in one file:

```
=== PASS 1: BUILD ===
[build agent output...]

=== PASS 2: REVIEW ===
[review agent output...]
```

## Requirements

- macOS or Linux
- Claude Code CLI v2.1+
- GitHub CLI (`gh`) authenticated
- `python3` (for JSON config parsing)
- `tmux` (optional, for `--worktree --tmux` monitoring)
- Git repos with GitHub remotes

## License

MIT
