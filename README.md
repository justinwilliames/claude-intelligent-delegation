# claude-intelligent-delegation

A [Claude Code](https://docs.anthropic.com/en/docs/claude-code) skill that orchestrates complex builds by decomposing tasks, fanning work out to Sonnet sub-sessions and Codex in parallel, running QA, and presenting a unified diff — all without bloating the main session's context.

## Why

Long main sessions degrade reasoning quality and burn prompt cache. This skill keeps the orchestrator lean: it plans, delegates, verifies, and reports. Sonnet sub-sessions in isolated git worktrees do the implementation. Codex provides a second-opinion or handles deep precision work. You get better results at lower token cost.

## Prerequisites

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed
- [claude-code-codex-skill](https://github.com/tomc98/claude-code-codex-skill) installed at `~/.claude/skills/codex`
- `OPENAI_API_KEY` set (for Codex chunks)
- Git repository in the project you're delegating work on

## Installation

```bash
# 1. Install the codex skill (dependency)
git clone https://github.com/tomc98/claude-code-codex-skill ~/.claude/skills/codex

# 2. Install this skill
git clone https://github.com/justinwilliames/claude-intelligent-delegation \
  ~/.claude/skills/intelligent-delegation
```

## Updating

```bash
cd ~/.claude/skills/intelligent-delegation && git pull
```

## Usage

Once installed, Claude Code loads the skill automatically when you ask it to delegate or decompose work. You can also invoke directly:

```
/delegate plan "add user authentication and a settings page"
/delegate run "refactor the data layer to use the repository pattern"
/delegate qa
```

| Mode | What it does |
|------|-------------|
| `plan` | Decomposes the task and produces a `delegation-manifest.json`. No code runs. |
| `run` | Decomposes, confirms with you, fans out, collects, runs QA, presents diff. |
| `qa` | Re-runs the QA gate on the current integration branch. |

## How it works

1. **Decompose** — Opus 4.7 breaks the task into independent chunks and writes a manifest
2. **Confirm** — you review the manifest and approve before anything runs
3. **Fan out** — Sonnet 4.6 sub-sessions run in isolated git worktrees in parallel; Codex handles precision/review chunks in the background
4. **Collect** — results and worktree branches are gathered
5. **Integrate** — worktree branches are merged into a single `delegation/<timestamp>` branch
6. **QA gate** — per-chunk verification commands run, plus the project-wide test suite
7. **Present** — clean summary: what changed, what passed, what needs attention

Conflicts are always surfaced to you — never auto-resolved.

## Model routing

| Tier | Model | Used for |
|------|-------|---------|
| Orchestrator | Opus 4.7 (main session) | Planning, reviewing, QA, reporting |
| Build | Sonnet 4.6 (subagent + worktree) | Parallel implementation chunks |
| Precision | Codex GPT-5.5 | Deep work, second opinions, adversarial review |
| Lookup | Haiku 4.5 (Explore subagent) | File search, symbol lookup |

Full decision tree: [`references/routing.md`](references/routing.md)

## Repository layout

```
claude-intelligent-delegation/
├── SKILL.md                      # Skill definition (loaded by Claude Code)
├── README.md                     # This file
├── LICENSE                       # MIT
├── scripts/
│   ├── delegate.sh               # Manifest validation, worktree merge, QA runner
│   └── detect-verification.sh    # Auto-detect test/typecheck/build commands
└── references/
    ├── routing.md                # Full model-routing decision tree
    ├── manifest-schema.md        # delegation-manifest.json schema + examples
    ├── orchestration-patterns.md # Sequencing, conflict handling, anti-patterns
    └── prompt-templates.md       # Chunk prompt templates (Sonnet vs Codex)
```

## License

MIT © Justin Williames 2026
