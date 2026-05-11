# Orchestration Patterns

Patterns the orchestrator should reach for, and anti-patterns to avoid. Assume the git-free, workspace + state.tsv engine.

## The canonical run

```
init → write-manifest → validate → preflight → user confirms
     → prepare → fan-out (parallel) → collect → audit → apply → qa → summary
```

Each arrow corresponds to one `delegate.sh` subcommand. The orchestrator does not invent intermediate steps. If you find yourself reaching for `git`, `mv`, or `rsync` directly, stop — the engine already covers it.

## Parallelism

**Default**: every chunk with `depends_on: []` is launched in a single tool-call batch (`Agent` for sonnet, `Bash` background for codex). The orchestrator then waits on `TaskOutput` / task-notification for each.

**With dependencies**: topologically sort. Launch all chunks whose deps are satisfied in one batch. When a wave returns, mark `status=done`, then launch the next wave.

**Hard ordering constraint**: chunks that overlap in `files_touched` MUST have a `depends_on` edge between them. `validate` enforces this; the engine refuses to run a manifest where two siblings claim the same file.

## State updates

Set state at the natural transitions, not on every internal event:

| Event | State update |
|---|---|
| Chunk launched | `set status=running` |
| Chunk completes successfully | `set status=done tokens=… duration_ms=… result=pass:N/M` |
| Chunk completes with verification failing | `set status=failed result="<one-line summary>"` |
| Chunk crashes / hits ceiling / cancelled | `set status=failed result="<reason>"` |
| User skips a chunk on resume | `set status=skipped` |

Never write to `state.tsv` directly — always via `delegate.sh set`. The schema may evolve.

## Collecting telemetry

`tokens` and `duration_ms` come from the runner:
- Sonnet `Agent` `task-notification` includes `<usage><total_tokens>` and `<duration_ms>` fields. Parse them from the notification block and store via `delegate.sh set` (the orchestrator must call this — the engine doesn't auto-capture for sonnet).
- Codex: the engine's `cmd_codex` parses JSONL `turn.completed` events for `usage.input_tokens + usage.output_tokens` and auto-stores the sum.

This data is the whole point of doing the orchestration in the first place — it tells the user whether codex was cheaper than sonnet for this chunk class.

## Retry policy — transient vs hard failure

A chunk failure is either transient (recoverable on retry) or hard (needs user intervention). The orchestrator decides which by parsing the failure message.

**Transient markers** (keywords in the failure message): `timeout`, `rate limit`, `connection reset`, `daemon`, `503`, `429`, `ECONNRESET`, `temporary failure`.

**On transient failure:**
1. Set `result=transient:<reason>`.
2. Wait 30 seconds.
3. Re-fan the chunk once with the same prompt.
4. If the retry succeeds, mark `done` as normal. If it fails again, treat as hard.

**On hard failure:**
1. Set `result=hard:<reason>`.
2. Surface to the user immediately — chunk id, intent, error, suggested fix.
3. Do NOT auto-retry.

Hard rule: at most one transient retry per chunk per run. Anything beyond that is hard.

## While the fan-out runs

Background subagents take 30s–5min to complete. Use that window productively in the main session:

- Draft the user-facing summary skeleton (chunks done, files changed, QA status — leave numbers blank).
- Pre-load any project conventions the audit step will need (style guide, lint config, naming patterns).
- Write the QA edge-case checklist (which verifications to scrutinise, which file overlaps to watch).
- Prep the apply-stage summary template.

Do NOT idle. The prompt cache TTL is 5 minutes. Letting the main session sit silent for 4 minutes means a cold-cache penalty when you resume for QA. Either work the in-flight time productively, or accept a long pause (>=1200s) and commit to a cold restart.

## Orchestrator-initiated abort

The orchestrator should call `{base}/scripts/delegate.sh abort <run-id>` when it detects a runaway chunk. Triggers:

- **Stale output.** `output.log` has not changed for 5+ minutes.
- **Contradictory state.** The chunk reports `done` but its workspace is empty, or vice versa.
- **Infinite loop in stdout.** Repeated phrases, ballooning output size, the chunk is clearly stuck.
- **User signal.** The user says "stop", "abort", "kill the run".

Behaviour: `abort` marks all `running` chunks `failed` with `result=aborted:<reason>`, writes an `ABORTED` marker file to the run dir, and prevents the `apply` step from running. Re-fan via `/delegate resume` after the root cause is identified and fixed.

Do NOT call abort for a chunk that's merely slow — only when it's demonstrably stuck. A 4-minute Sonnet subagent is fine; a 30-minute one is not.

## Audit failures

`delegate.sh audit` halts on two conditions:

1. **Undeclared file in a workspace.** The chunk produced something its manifest didn't claim. Either the prompt was under-specified (chunk made a reasonable inference) or the chunk went rogue. Show the user the file and its content. Options: add the file to `files_touched` and re-audit (if intentional), or `clean` the run and re-fan (if accidental).
2. **Same file emitted by two chunks.** Shouldn't happen if `validate` passed — implies a chunk wrote outside its declared paths. Treat as a bug; surface both workspaces' versions and ask the user which (if either) to keep.

**Never** auto-resolve. The whole point of audit is to be the human-checkpoint before files land in the project.

## QA failures

`delegate.sh qa` fails when a chunk's `verification` or the `project_verification` exits non-zero. Show the user:

1. Which check failed.
2. The chunk(s) most likely responsible (look at `files_touched` overlap with the failing test).
3. `delegate.sh diff <run-id> <chunk-id>` for that chunk to show file list.
4. Suggested next step: revert apply by `clean`-ing the run, or fix forward.

## Resume patterns

`/delegate resume <run-id>` is for two cases:

- **Single chunk failed**: leave `done` chunks alone, re-fan the failed one only.
- **Run was killed mid-flight**: any `pending` or `running` chunks get re-launched. (Note: `running` is treated as "not done"; the engine assumes a crashed orchestrator left it stale.)

The orchestrator on resume should:
1. `delegate.sh state <run-id>` to read the full picture.
2. `delegate.sh pending <run-id>` to list re-fan candidates.
3. For each candidate, re-launch with the **same prompt template** as the original run (files_touched, intent, runner all live in the manifest).
4. Audit, apply, QA as normal.

## When NOT to use this skill

- Single-file edit, single-step task: just edit it.
- Conversational task: just respond.
- Task fits in <30% of remaining context: do it in-session.
- Tightly coupled refactor where chunks would constantly step on each other: serialize via `depends_on` chain — but if every chunk depends on every prior chunk, you have one chunk, not many.
- Exploratory work where the scope keeps changing: design first in the main session, fan out only when boundaries stabilise.

## Anti-patterns

- **Editing the manifest after `write-manifest`.** Manifest is immutable per run. To change the plan: `clean` + `init` a new run.
- **Skipping `audit`.** Even when you trust the chunks, the audit is the last guard before user files get touched.
- **Letting chunks write into the project.** They go to workspaces. Always.
- **Auto-resolving conflicts.** The user decides. Always.
- **Holding chunk diffs in your context.** Use `delegate.sh diff <run-id> <chunk-id>` on demand. State.tsv has everything else.
- **Spawning a new orchestrator turn per chunk.** Fan out all parallelizable chunks in a single batch. Don't serialize what can be parallel.
