---
name: intelligent-delegation
description: Orchestrate complex builds by decomposing tasks, fanning out to Sonnet sub-sessions and Codex in parallel, then collecting, QA-ing, and presenting a unified diff. Use when the user says 'delegate', 'fan out', 'parallel build', 'decompose this task', 'hand off to codex', or presents a large multi-part build request. Also use when context exceeds 60% or 2+ independent implementation units are present.
allowed-tools: Bash, Read, Grep, Glob, Write, Edit, Agent, TaskOutput
---

# Intelligent Delegation

> Paths below use `{base}` as shorthand for this skill's base directory, provided automatically at the top of the prompt when the skill loads.

You are the **orchestrator**. Your job: decompose, delegate, collect, verify, present. You do not implement chunks yourself — that's what sub-sessions and Codex are for. You hold the context, own the QA gate, and report back to Sir.

## Model Routing — the tier table

| Tier | Model | Session | Use for |
|------|-------|---------|---------|
| **Orchestrator** | Opus 4.7 (main session) | Stays | Decompose, review diffs, QA, talk to Sir |
| **Planning** | Opus 4.7 (Plan subagent) | Subagent | Architecture, multi-file refactor design, broad context |
| **Build** | Sonnet 4.6 (Agent + worktree) | Fresh per chunk | Parallel independent implementation chunks |
| **Precision** | Codex GPT-5.5 | Background | Adversarial review, deep algorithms, second opinions |
| **Lookup** | Haiku 4.5 (Explore subagent) | Subagent | File location, grep-for-symbol, quick searches |

## Context Budget Rules

- **<30% context**: do the work in-session. Delegation overhead not worth it.
- **30–60%**: hand exploration to Explore subagents. Keep implementation local.
- **>60%** OR **2+ independent units**: decompose and fan out. This is the skill's sweet spot.
- **Cache discipline**: prompt cache TTL is 5 min. Stay <270s between turns or commit to ≥1200s. Sub-sessions start with fresh cache — that's a feature.

## When to Use Codex vs Sonnet Subagent

| Use Codex | Use Sonnet subagent (worktree) |
|-----------|-------------------------------|
| One focused file/function | Multi-file chunk |
| Want a different model's opinion | Follows project conventions |
| Adversarial review | Parallelisable with sibling chunks |
| Deep algorithmic work | Output is a clean diff to merge |

## Usage

```
/delegate plan "<task>"   # Decompose only — produce manifest, no execution
/delegate run "<task>"    # Decompose + fan out + collect + QA + present diff
/delegate qa               # Re-run QA gate on current integration branch
```

## Orchestration Flow (run mode)

### Step 1 — Decompose

Produce a `delegation-manifest.json` in the project root with this shape:

```json
{
  "task": "high-level description",
  "integration_branch": "delegation/YYYYMMDD-HHMMSS",
  "project_verification": "npm test",
  "chunks": [
    {
      "id": "chunk-1",
      "title": "short title",
      "intent": "what this chunk must accomplish",
      "files_touched": ["src/foo.ts", "src/bar.ts"],
      "runner": "sonnet-subagent",
      "depends_on": [],
      "verification": "npm run typecheck"
    }
  ]
}
```

Runner options: `sonnet-subagent` | `codex` | `main`

### Step 2 — Confirm

Show the manifest to Sir. Get explicit yes before fanning out.

### Step 3 — Fan Out (parallel)

**Sonnet subagent chunks:**
```python
Agent(
  subagent_type="general-purpose",
  model="sonnet",
  isolation="worktree",
  prompt="<self-contained chunk prompt — see references/prompt-templates.md>",
  run_in_background=True
)
```

**Codex chunks:**
```bash
{base}/../codex/scripts/codex.sh run "<intent>" --dir /project/path
```
Run in background. Requires the codex skill to be installed.

**Main chunks:** Execute after fan-out returns.

### Step 4 — Collect

Block on TaskOutput for each agent task. Capture worktree path + branch from result.

### Step 5 — Integrate

```bash
{base}/scripts/delegate.sh merge-worktrees <integration-branch> <branch1> <branch2> ...
```

On conflict: **surface to Sir, do not auto-resolve.**

### Step 6 — QA Gate

```bash
{base}/scripts/delegate.sh qa <integration-branch> delegation-manifest.json
```

If anything fails: show the failure + the offending chunk's diff. Ask Sir how to proceed.

### Step 7 — Present

Summary: what each chunk did, files changed, tests run, pass/fail, integration branch name.

## Self-Healing

If scripts break, edit them directly — you have authorization to modify anything under `{base}/`:
- `scripts/delegate.sh` — merge + QA runner
- `scripts/detect-verification.sh` — auto-detect test commands
- `references/routing.md` — full decision tree detail
- `references/manifest-schema.md` — JSON schema + examples
- `references/orchestration-patterns.md` — sequencing + conflict patterns
- `references/prompt-templates.md` — chunk prompt templates

## Anti-Patterns

- Do NOT delegate a chunk that touches the same file as another concurrent chunk — schedule sequentially via `depends_on`.
- Do NOT auto-resolve merge conflicts — Sir decides.
- Do NOT fan out if <30% context — the overhead exceeds the benefit.
- Do NOT use this for conversational tasks or single-file edits — just do them.
