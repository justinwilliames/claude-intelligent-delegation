<p align="center">
  <img src="assets/caldwell.png" alt="Caldwell, the orchestrator" width="180">
</p>

<h1 align="center">claude-intelligent-delegation</h1>

<p align="center">
  A <a href="https://docs.anthropic.com/en/docs/claude-code">Claude Code</a> skill that orchestrates complex builds by decomposing tasks, fanning work out to Sonnet sub-sessions and Codex in parallel, running QA, and presenting a unified diff — all without bloating the main session's context.
</p>

---

## One-shot install (in Claude Code)

Paste this into a Claude Code session and let Claude do the install:

```
Install the intelligent-delegation skill: clone https://github.com/justinwilliames/claude-intelligent-delegation into ~/.claude/skills/intelligent-delegation, then verify by listing ~/.claude/skills/intelligent-delegation/SKILL.md. If you want Codex chunks too, also clone https://github.com/tomc98/claude-code-codex-skill into ~/.claude/skills/codex. Confirm jq is on PATH; if not, install it via brew install jq.
```

Or in a terminal:

```bash
git clone https://github.com/justinwilliames/claude-intelligent-delegation \
  ~/.claude/skills/intelligent-delegation

# optional, for Codex chunks
git clone https://github.com/tomc98/claude-code-codex-skill ~/.claude/skills/codex

# dependency
brew install jq   # or: apt install jq
```

Then start a Claude Code session and ask it to "delegate" or "fan out" a multi-part task. The skill loads automatically.

## Why

Long main sessions degrade reasoning quality and burn prompt cache. This skill keeps the orchestrator lean: it plans, delegates, verifies, and reports. Sonnet sub-sessions do the implementation; Codex provides second opinions or handles deep precision work.

**No git required.** State lives in `$TMPDIR/delegate/<run-id>/` — works in any directory.

## Upfront triage — the load-bearing behaviour

The skill is designed to fire **at the start of every non-trivial task**, before the main session reads files or spawns Explore subagents. Claude runs a 5-second, 4-question check:

1. **Scope** — does this touch 2+ independent files/features/deliverables?
2. **Context** — would in-session execution burn >30% of remaining context?
3. **Fresh-window** — would a single deep task benefit from a fresh prompt cache + clean reasoning surface?
4. **Parallelism** — are there 2+ independent units that could run concurrently?

If any answer is yes, delegate. Even a 1-chunk delegate run is worth it for fresh-window value alone — parallelism is the optimisation, fresh context is the primary win.

Claude states the call in a single line so you can redirect early:

> `Delegation triage: delegating — 4 independent feature chunks, would burn ~50% main-session context.`

Skip the triage for conversational replies, status questions, single-line edits, or lookups under 3 file reads.

## Prerequisites

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed
- [claude-code-codex-skill](https://github.com/tomc98/claude-code-codex-skill) installed at `~/.claude/skills/codex` (only if you want Codex chunks)
- `jq` on PATH

## Updating

```bash
cd ~/.claude/skills/intelligent-delegation && git pull
```

## Usage

Claude Code loads the skill automatically when you ask it to delegate or decompose work. You can also invoke directly:

```
/delegate plan "<task>"          # decompose only
/delegate run "<task>"           # decompose → confirm → fan out → audit → apply → QA → present
/delegate review "<draft>"       # 1-chunk Codex run — adversarial second opinion (review.md, no apply)
/delegate resume [run-id]        # re-fan only pending/failed chunks (defaults to last run)
/delegate qa <run-id>            # re-run QA on an existing run
/delegate abort <run-id>         # kill all running chunks; mark them failed
/delegate watch [run-id]         # compact one-shot snapshot of state.tsv (used for in-chat progress)
```

## How it works

1. **Init** — fresh run dir at `$TMPDIR/delegate/<run-id>/`, with a compact `state.tsv` the orchestrator re-reads on demand.
2. **Decompose** — Opus writes a manifest describing each chunk: id, intent, files_touched, runner, verification.
3. **Validate + preflight** — schema check, file-collision check across chunks, and a guard against overwriting existing project files.
4. **Confirm** — manifest shown; you approve.
5. **Prepare workspaces** — each chunk gets a private `<chunk-id>/workspace/` directory to write into.
6. **Fan out** — Sonnet subagents and Codex run in parallel, each constrained to their own workspace.
7. **Audit** — verifies each chunk only produced its declared files and no two chunks emitted the same file.
8. **Apply** — copies workspace outputs into the project, preserving relative paths.
9. **QA gate** — per-chunk verification + project-wide test suite, run against the integrated project.
10. **Present** — table of chunks, files, tokens, durations, pass/fail. Plus the `run_id` for resume.

Audit and QA failures are always surfaced to you — never auto-resolved.

## Model routing

| Tier | Model | Used for |
|------|-------|---------|
| Orchestrator | Opus 4.7 (main session) | Planning, reviewing, QA, reporting |
| Planning | Opus 4.7 (Plan subagent) | Manifest authoring for non-trivial decompositions |
| Build | Sonnet 4.6 (Agent) | Parallel implementation chunks |
| Integration | Opus 4.7 (main, in-line) | `runner: main` chunks — glue, cross-cutting edits |
| Precision | Codex GPT-5.5 | Deep work, adversarial review, second opinions |
| Lookup | Haiku 4.5 (Explore subagent) | File search, symbol lookup |

Full decision tree: [`references/routing.md`](references/routing.md)

## State model

```
$TMPDIR/delegate/<run-id>/
├── manifest.json             # immutable plan
├── state.tsv                 # compact orchestrator state (one row per chunk)
├── chunk-1/workspace/        # chunk writes here, relative paths
├── chunk-2/workspace/
└── …
```

`state.tsv` is ~80 chars per chunk — designed so the orchestrator can re-read it for under 250 tokens between turns.

## Engine commands

`scripts/delegate.sh` exposes the full lifecycle:

```
init / write-manifest / validate / preflight / prepare /
set / get / state / workspace / pending / resume /
diff / audit / apply / qa / summary / handoff / watch /
abort / clean / last / autodetect / codex
```

`DELEGATE_DEBUG=1` enables an ERR trap that prints failing line + command + exit code.

## Repository layout

```
intelligent-delegation/
├── SKILL.md                      # Skill definition (loaded by Claude Code)
├── README.md                     # This file
├── LICENSE                       # MIT
├── assets/
│   └── caldwell.png              # Project mascot
├── scripts/
│   ├── delegate.sh               # Full orchestrator engine (git-free)
│   └── detect-verification.sh    # Auto-detect test/typecheck commands
└── references/
    ├── routing.md                # Model-routing decision tree
    ├── manifest-schema.md        # Manifest schema + examples
    ├── orchestration-patterns.md # Sequencing, audit, resume, anti-patterns
    └── prompt-templates.md       # Chunk prompt templates (Sonnet, Codex, Review)
```

## License

MIT © Justin Williames 2026
