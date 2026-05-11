---
name: intelligent-delegation
description: Orchestrate complex builds by decomposing tasks, fanning out to Sonnet sub-sessions and Codex in parallel, then collecting, QA-ing, and presenting a unified diff. Use when the user says 'delegate', 'fan out', 'parallel build', 'decompose this task', 'hand off to codex', or presents a large multi-part build request. Also use when 3+ files have already been read this turn, when the user request mentions 2+ independent files/features/deliverables, or when 2+ Explore subagents have already fired.
allowed-tools: Bash, Read, Grep, Glob, Write, Edit, Agent, TaskOutput
---

# Intelligent Delegation

> Paths below use `{base}` as shorthand for this skill's base directory, provided automatically at the top of the prompt when the skill loads.

You are the **orchestrator**. Your job: decompose, delegate, collect, verify, present. You do not implement chunks yourself — that's what sub-sessions and Codex are for. You hold the context, own the QA gate, and report back.

**No git required.** Project directories, plain folders, Notion exports, scratch dirs — anything works. State lives in a tmp run dir, not in branches.

## Model Routing — the tier table

| Tier | Model | Session | Use for |
|------|-------|---------|---------|
| **Orchestrator** | Opus (main session) | Stays | Decompose, review diffs, QA, reconcile dual-model reviews, talk to the user |
| **QA reviewer A** | Opus (fresh subagent) | Subagent | Cold semantic review of an applied major run (Step 10.5) |
| **QA reviewer B** | Codex GPT-5.5 `--effort high` | Background | Adversarial review of an applied major run, parallel to reviewer A (Step 10.5) |
| **Planning** | Opus (Plan subagent) | Subagent | Architecture, multi-file refactor design |
| **Build** | Sonnet (Agent) | Fresh per chunk | Parallel independent implementation chunks |
| **Precision** | Codex GPT-5.5 | Background | Adversarial review, deep algorithms, second opinions |
| **Lookup** | Haiku (Explore subagent) | Subagent | File location, grep-for-symbol, quick searches |
| **Integration** | Opus (main session, in-line) | Stays | runner: `main` chunks — cross-cutting edits, package.json, config wiring, glue between sibling chunks |

Use `runner: main` sparingly — typically the final chunk in a chain when integration genuinely requires orchestrator context (sibling-chunk awareness, cross-file decisions). Most chunks should be `sonnet-subagent`.

## Effort Levels per Runner

| Runner | Effort control | Default | Override |
|--------|---------------|---------|----------|
| **Orchestrator (Opus)** | Model tier — always Opus 4.7 | Full | Stay on Opus; never switch to Sonnet manually |
| **Sonnet subagents** | Model tier — always `model="sonnet"` | Full Sonnet | No per-call knob; model IS the effort |
| **Codex** | `CODEX_EFFORT` env var → `model_reasoning_effort` | `medium` | `CODEX_EFFORT=high` for deep algorithmic work |
| **Haiku (Explore)** | Model tier — always `model="haiku"` | Full Haiku | No knob |

**Session advice:** Start and stay on Opus 4.7. The skill routes sub-runners automatically. Switching to Sonnet manually to "save tokens" just degrades the orchestrator — the planning and QA gates are where Opus earns its keep.

## Session Handoff — when to suggest a fresh start

The orchestrator must proactively suggest a handoff when it detects diminishing returns from held context. Don't wait for the user to notice. The trigger is any one of:

| Signal | Threshold | Action |
|--------|-----------|--------|
| Context window | **>75%** full | Suggest handoff immediately — before the next fan-out or QA gate |
| Mid-run stall | Collect phase done, QA not started, session feels stale | Suggest handoff before QA |
| Repeated clarifications | Same question asked / context re-explained 2+ times | Stop and suggest handoff |
| User says "handoff" | Explicit | Always produce the prompt block |

**How to surface it — always inline, always copyable:**

Say clearly: *"Sir, here's your transfer prompt — paste this into a new session:"*

Then produce a fenced code block containing the self-contained prompt. The user copies it and pastes it as the first message in a new session. No files to read, no scripts to run, no setup.

**Transfer prompt format:**

~~~
```
Pick up where the last session left off. Here's the full context:

## What was done
<bullet list — shipped features, confirmed facts, dead ends proven>

## Current state
<what exists now, what version shipped, what's live>

## Next action
<single concrete first step — tool call, command, or decision>

## Open unknowns
<what hasn't been verified yet, what could break>

## Key files
<file path — what's relevant about it>
<file path — what's relevant about it>

## Dead ends — do not retry
<approach — why it fails>
```
~~~

Keep it tight enough to paste without hesitation. If there's a delegate run in progress, add:

```
## Delegate run
run_id: <run-id>
project: <path>
pending chunks: <ids>
next step: /delegate resume <run-id>
```

**The rule:** every handoff lives in the chat as a copyable block. No file, no script, no "go read HANDOFF.md". The prompt IS the handoff.

## Context Budget Rules

- **<30% context**: do the work in-session. Delegation overhead not worth it.
- **30–60%**: hand exploration to Explore subagents. Keep implementation local.
- **>60%** OR **2+ independent units**: decompose and fan out. The sweet spot.
- **Cache discipline**: prompt cache TTL is 5 min. Stay <270s between turns or commit to ≥1200s. Sub-sessions start with fresh cache.
- **Single-chunk delegation is valid.** A 1-chunk run to Sonnet or Codex is worth it when you want a *fresh context window* for one large task — not just for parallelism. Use this for: a deep refactor in one module (Sonnet, fresh cache), an adversarial review of one file (Codex, `--effort high`), or any task that would burn 40%+ of main-session context if done in-place. Parallelism is an optimisation; fresh-context is the primary value of delegation.

## When to Use Codex vs Sonnet Subagent

| Use Codex | Use Sonnet subagent |
|-----------|---------------------|
| One focused file/function | Multi-file chunk |
| Want a different model's opinion | Follows project conventions |
| Adversarial review | Parallelisable with siblings |
| Deep algorithmic work | Output is a clean diff |

## Usage

```
/delegate plan "<task>"     # Decompose only — produce manifest, no execution
/delegate run "<task>"      # Decompose + fan out + collect + audit + apply + QA + present
/delegate resume [run-id]   # Re-fan only chunks still pending or failed
/delegate qa <run-id>       # Re-run QA gate on an existing run
/delegate review "<draft-or-task>"  # 1-chunk Codex run for adversarial second opinion (review.md, no apply)
```

Review mode is a 1-chunk Codex run that produces a `review.md` artefact instead of code files. Use for: adversarial second opinion on an Opus-authored plan, sanity-checking a risky integration, getting model-diversity on a critical algorithm. See `references/prompt-templates.md` for the review-mode template.

## State model

Every run lives at `$TMPDIR/delegate/<run-id>/`. The orchestrator never holds chunk diffs in context — it reads `state.tsv` on demand. `state.tsv` is the source of truth.

```
$TMPDIR/delegate/<run-id>/
  manifest.json             ← authored once, then read-only
  state.tsv                 ← compact orchestrator state (see below)
  <chunk-id>/workspace/     ← chunk writes files here (relative paths)
  <chunk-id>/output.log     ← captured chunk stdout (telemetry only)
```

**`state.tsv` layout** — header comment + column header + one row per chunk:

```
# run_id=20260511-153022-a4b project=/path task="add slugify + truncate"
id      status   runner           files                    verification              tokens  duration_ms  result
chunk-1 done     sonnet-subagent  src/slugify.js,...       node --test src/slug...   1234    4500         pass:5/5
chunk-2 done     codex            src/truncate.js,...      node --test src/trun...   2100    8200         pass:4/4
```

Status values: `pending` → `running` → `done` | `failed` | `skipped`. The whole file is ~80 chars per row — re-reading it mid-run costs <250 tokens.

**Token capture:** Sonnet chunks report exact tokens via the `task-notification` `<usage><total_tokens>` field — the orchestrator must parse and call `delegate.sh set ... tokens=<N>` (the engine doesn't auto-capture for sonnet). Codex chunks are auto-captured by `cmd_codex` from JSONL `turn.completed` events.

## Orchestration Flow (run mode)

### Step 1 — Init the run

```bash
OUT=$({base}/scripts/delegate.sh init "<task>" --project <project-path>)
RUN_ID=$(echo "$OUT" | awk '/^RUN_ID:/ {print $2}')
```

Returns `RUN_ID`, `RUN_DIR`, `PROJECT`. Stash the RUN_ID in your scratchpad — every other command takes it.

### Step 1.5 — Autodetect verification commands

Before authoring the manifest, run:
```bash
{base}/scripts/delegate.sh autodetect <project-path>
```
Use the output to populate `project_verification` and chunk `verification` fields in the manifest. Avoids the orchestrator inventing wrong commands (e.g. `npm test` on a Python project). If autodetect prints `NO_VERIFICATION_DETECTED`, fall back to a minimal sanity check (`bash -n script.sh`) or omit verification.

### Step 2 — Decompose

Author a manifest with this shape (see `references/manifest-schema.md` for the full spec):

```json
{
  "task": "high-level description",
  "run_id": "<RUN_ID from step 1>",
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

`files_touched` is **required** and **non-empty** — it's how chunks are kept disjoint and how audits work later.

Install the manifest into the run:
```bash
{base}/scripts/delegate.sh write-manifest "$RUN_ID" /tmp/manifest.json
```

### Step 2.5 — (Optional) Delegate manifest authoring to a Plan subagent

For non-trivial decompositions (>3 chunks, unfamiliar project, or heavy file analysis), delegate the manifest-authoring to a Plan subagent (Opus, fresh subagent context) instead of doing it in the main session. Hand it the task + project path + a brief on the runner enum, and ask for JSON-only output. Main session reviews the returned manifest and installs via `write-manifest`. Saves main-session tokens on planning. Skip this for simple 2-3 chunk runs — overhead exceeds the benefit.

### Step 3 — Validate + preflight

```bash
{base}/scripts/delegate.sh validate "$RUN_ID"
{base}/scripts/delegate.sh preflight "$RUN_ID"
```

- `validate` checks schema, runner enum, duplicate IDs, dep cycles, **and concurrent file overlaps**.
- `preflight` halts if any target file already exists in the project (override with `--force` if the user explicitly wants to overwrite).

### Step 4 — Confirm with the user

Show the manifest. Get explicit yes before fanning out.

### Step 5 — Prepare workspaces

```bash
{base}/scripts/delegate.sh prepare "$RUN_ID"
```

Creates `$RUN_DIR/<chunk-id>/workspace/` for every chunk. **This is where chunks write.** They never write directly to the project.

### Step 6 — Fan Out (parallel)

Resolve absolute workspace paths up-front so each chunk gets a self-contained prompt:

```bash
WS_C1=$({base}/scripts/delegate.sh workspace "$RUN_ID" chunk-1)
```

**Sonnet subagent chunks** — Agent tool, background, no worktree isolation (we don't need git):
```
Agent(
  subagent_type="general-purpose",
  model="sonnet",
  run_in_background=True,
  prompt="""
You are chunk-1 of a delegated build.

PROJECT (read-only context — do not modify): /Users/.../my-project
WORKSPACE (write here, relative paths under it): /tmp/delegate/<run-id>/chunk-1/workspace

Create exactly these files inside WORKSPACE:
  - src/foo.ts
  - src/foo.test.ts

[intent here]

When done, run: cd WORKSPACE && <verification command using ABSOLUTE imports>
Report: file list + test summary in your final message.
"""
)
```

**Codex chunks** — `--dir` points at the chunk workspace, `--add-dir` (read) points at the project:
```bash
{base}/../codex/scripts/codex.sh run "<intent + same workspace contract>" \
  --dir "$WS_C1" --sandbox workspace-write
```

Mark each chunk `running` as you launch:
```bash
{base}/scripts/delegate.sh set "$RUN_ID" chunk-1 status=running
```

### Step 6.5 — While the fan-out runs

Background subagents take 30s–5min to complete. Use that time productively in the main session: draft the user-facing summary skeleton, pre-load any project conventions the audit step will need, write the QA edge-case checklist, prep the apply summary template. Do NOT let the main session idle — the prompt cache decays after 270s and you'll pay a cold-cache penalty on the QA gate.

### Step 7 — Collect

When each agent/codex run returns, update state:

```bash
{base}/scripts/delegate.sh set "$RUN_ID" chunk-1 \
  status=done tokens=1234 duration_ms=4500 result=pass:5/5
```

On failure, set `status=failed` and copy the error into `result=…`. **Do not** retry automatically — surface to the user.

> On failure, see retry policy in `references/orchestration-patterns.md` (transient vs hard failure handling).

### Step 8 — Audit

```bash
{base}/scripts/delegate.sh audit "$RUN_ID"
```

Catches: chunks that produced files not declared in `files_touched`; the same file emitted by two different chunks. If either fires, halt and ask the user how to proceed — **do not auto-resolve.**

### Step 9 — Apply

```bash
{base}/scripts/delegate.sh apply "$RUN_ID"
```

Copies each `done` chunk's workspace into the project, preserving relative paths. Prints `APPLIED: <path> (from <chunk-id>)` per file and a final `APPLIED_CHUNKS: N`.

### Step 10 — QA gate

```bash
{base}/scripts/delegate.sh qa "$RUN_ID"
```

Runs each chunk's `verification` in the project root, then runs `project_verification`. Prints `PASS|FAIL` per check and `QA_PASS: N/N` or `QA_FAIL: N/M failed` at the end.

If anything fails: show the failure, show the offending chunk's `diff` (`delegate.sh diff "$RUN_ID" <chunk-id>` lists files), ask how to proceed.

### Step 10.5 — Dual-model QA review (major runs)

Mechanical QA (Step 10) verifies that tests pass. It does not verify that the code is **good** — correct, idiomatic, safe, free of subtle bugs, complete. For major runs, a second pass is mandatory: **Opus 4.7 reviews in the main session, Codex GPT-5.5 reviews in a fresh background context, both in parallel, then the orchestrator reconciles and fixes.**

#### When this step fires (the "major" trigger)

Run dual-model review if **any** of the following hold:

| Trigger | Threshold |
|---------|-----------|
| Chunk count | ≥3 chunks applied (excluding pure review runs) |
| Files changed | ≥5 files written to the project |
| Risk surface | Touches auth, payments, migrations, billing, security, data-loss-capable code paths, or anything user-facing in production |
| Lines of code | ≥300 net new lines across the run |
| User flag | User said "high-stakes", "critical", "production", "ship-ready", or explicitly requested review |

For runs that don't trip any trigger (1-2 chunk runs, scratch work, prototypes), skip straight to Step 11. The overhead of dual review is not worth it for trivial work.

**Do NOT skip this step on a major run to "save time".** The reconcile-and-fix loop is exactly where bugs get caught before they ship. Mechanical QA passing is necessary but not sufficient.

#### How to run it

**1. Spawn both reviews in parallel** (same message, two tool calls):

- **Opus review** — Agent tool, `subagent_type="general-purpose"`, no `model=` override (inherits Opus from the orchestrator session). Fresh context window — the subagent has not seen the build conversation, so it reviews the applied code cold. Hand it: the project path, the list of files changed, the original task description, the manifest, and the review dimensions below.
- **Codex review** — `{base}/../codex/scripts/codex.sh run` with `--effort high --model gpt-5.5`, background. Hand it the same brief. Codex's review writes `review-codex.md` to a temp workspace.

Both reviewers MUST be given:
- The original task and manifest (so they know what was supposed to be built).
- The exact list of files changed (so they know where to look).
- The project path (read-only for both — they do not modify code).
- The dimensions: **correctness, edge cases, missing tests, security, scalability, conventions, completeness vs. spec**.
- The output shape: structured findings with severity (`blocker` / `major` / `minor` / `nit`), file:line refs, and a concrete fix recommendation per finding.

Use the review template in `references/prompt-templates.md` (the `/delegate review` template) as the base, adapted for "review this just-applied delegate run" framing.

**2. Collect both reviews.** Read them into the main session. Do NOT have either reviewer fix anything — reviewers review, the orchestrator decides.

**3. Reconcile** in the main session (this is Opus orchestrator work):

| Reconciliation step | What you do |
|---------------------|-------------|
| Dedupe | Same issue flagged by both reviewers → single finding with both citations |
| Resolve conflicts | Reviewers disagree → orchestrator decides, names the reasoning in one line |
| Prioritise | Sort: blockers → majors → minors → nits |
| Filter | Drop nits unless trivial to fix; drop findings the user explicitly accepted as out of scope |
| Produce a reconciled punch list | Markdown, severity-grouped, with file:line refs and the agreed fix per item |

**4. Surface the reconciled list to the user.** Lead with: blockers count, majors count, your recommended action (ship as-is / fix-then-ship / re-architect). Get explicit yes before fixing.

**5. Fix the agreed items.** Use the same delegation calculus:
- Single-file mechanical fixes → do inline in main session.
- Multiple independent fixes → fan out via a follow-up `/delegate run` with the punch list as the task.
- One deep correctness fix → 1-chunk Codex run with `--effort high`.

**6. Re-run mechanical QA** (`delegate.sh qa "$RUN_ID"`) after fixes land. If it fails, loop. If it passes, proceed to Step 11.

**7. Re-review only if blockers were fixed.** If only minors/nits were patched, trust the mechanical QA and move on. Do not infinite-loop the review pass.

#### Anti-patterns specific to this step

- **Skipping reconciliation** — handing two raw review files to the user is lazy and noisy. Reconciliation is the orchestrator's job.
- **Auto-fixing without confirmation** — even when both reviewers agree, the user gets to see the punch list and approve scope before fixes land. Some findings will be deliberate design choices.
- **Running both reviews sequentially** — they're independent; parallel is free latency. Same message, two tool calls.
- **Letting reviewers see each other's output** — model-diversity is the point. Each reviewer must produce findings independently.
- **Treating Codex's `do-not-ship` verdict as veto** — Codex is opinionated and sometimes wrong. Weigh both reviewers, decide in the main session, be willing to overrule with reasoning.

### Step 11 — Present

```bash
{base}/scripts/delegate.sh summary "$RUN_ID"
```

Shows the run header + the full state.tsv as a column-aligned table. Lead the user with: chunks done, files added, mechanical QA result, dual-review result (if Step 10.5 ran), reconciled findings fixed, run_id (for resume).

## Resume

If a chunk fails or the user kills the run:

```bash
{base}/scripts/delegate.sh resume          # uses last run
{base}/scripts/delegate.sh resume <run-id> # specific run
{base}/scripts/delegate.sh pending <run-id> # just the chunk ids
```

Re-fan only the `pending` and `failed` chunks. State.tsv preserves the rest.

```bash
{base}/scripts/delegate.sh abort <run-id> [reason]
```

`/delegate abort <run-id> [reason]` — Mark all running chunks `failed` with `result=aborted:<reason>`, write an `ABORTED` marker, prevent the apply step from running. The orchestrator should call this when it detects a runaway chunk (no progress in output.log for 5+ min, contradictory state, infinite loop in stdout). Re-fan via `/delegate resume` after the root cause is fixed.

## Self-Healing

If scripts break, edit them directly — you have authorization to modify anything under `{base}/`:
- `scripts/delegate.sh` — the entire engine (init, validate, audit, apply, qa, etc.)
- `scripts/detect-verification.sh` — auto-detect test commands
- `references/routing.md` — full decision tree
- `references/manifest-schema.md` — JSON schema + examples
- `references/orchestration-patterns.md` — sequencing patterns
- `references/prompt-templates.md` — chunk prompt templates

Set `DELEGATE_DEBUG=1` to enable an ERR trap that prints the failing line + command + exit code.

## Anti-Patterns

- Do NOT delegate a chunk that touches the same file as a concurrent chunk. `validate` will refuse to run, but don't try.
- Do NOT auto-resolve audit failures (undeclared files, cross-chunk file overlap). The user decides.
- Do NOT fan out if <30% context. The overhead exceeds the benefit.
- Do NOT use this for conversational tasks or single-file edits — just do them.
- Do NOT skip `preflight`. Overwriting the user's in-progress work is the worst-case failure mode.
- Do NOT let chunks write directly into the project path. Workspaces only.
- Do NOT skip Step 10.5 (dual-model QA review) when a run trips any "major" trigger — chunks ≥3, files ≥5, risk surface, ≥300 LOC, or user-flagged. Mechanical QA passing is necessary, not sufficient.
- Do NOT auto-apply fixes from the reconciled review punch list. Surface, get approval, then fix.
