# Model Routing Decision Tree

This document explains how the orchestrator should decide between keeping work in the main Opus session, fanning out to Sonnet subagents, asking Codex for precision work, or using Haiku for cheap lookup. The goal is not to maximize delegation. The goal is to maximize output quality while keeping the main session lean and the prompt cache warm.

## Tier Table

| Tier | Model | Primary job | When to use it | What stays in session |
|------|-------|-------------|----------------|-----------------------|
| Orchestrator | Opus 4.7 | Planning, decomposition, QA, reporting, user communication | Always. The main session owns the task, writes the manifest, approves fan-out, reviews outputs, and presents the result. | The full task narrative, tradeoffs, manifest state, QA status, and user-facing explanation stay here. |
| Build | Sonnet 4.6 subagent in a worktree | Parallel implementation chunks | Use for independent chunks that touch multiple files, follow repo conventions, and should land as mergeable diffs. This is the default worker for real build work. | Only the chunk prompt, the worktree branch, and the chunk result live in the subagent. Main-session knowledge does not automatically carry over. |
| Precision | Codex GPT-5.5 | Deep precision work, adversarial review, second opinion | Use when you want a different model family, a skeptical review, a narrowly scoped algorithmic fix, or a careful pass over a risky integration point. | Codex reads the repo fresh. The main session should keep only the ask, the returned result, and any review findings. |
| Lookup | Haiku 4.5 explore subagent | Fast file discovery and lightweight searches | Use for grep-like tasks, symbol discovery, finding entry points, or locating candidate files before deciding where build work belongs. | Only the extracted facts and file paths should be carried back. Haiku should not own implementation context. |

## Decision Tree

1. Start with the context budget.
2. Decide whether the task is truly independent work or just one local edit.
3. If delegation is justified, split by file ownership boundaries first.
4. Pick Sonnet when the chunk should produce a conventional repo diff.
5. Pick Codex when you want an independent model perspective or a narrow precision task.
6. Keep integration, conflict decisions, QA, and user communication in the main Opus session.

## Context Budget Thresholds

### `<30%` context used

Keep the work in session.

Rationale:
- The orchestrator still has enough room to inspect files, edit directly, and verify without paying delegation overhead.
- Spinning up workers adds prompt-writing, collection, merge, and QA coordination costs that will usually exceed the savings.
- At this level, the main risk is over-engineering the workflow rather than losing reasoning quality.

Typical action:
- Read the relevant files.
- Make the change directly.
- Run verification.
- Do not create a delegation manifest unless the task has an unusual need for independent review.

### `30-60%` context used

Stay mostly local, but offload lookup and exploration.

Rationale:
- The main session still has enough room to implement, but context growth can become noisy.
- Haiku can cheaply locate files, tests, or symbols without forcing the main session to ingest everything.
- Delegating implementation at this range is only worth it if there are clearly independent chunks.

Typical action:
- Use Haiku or lightweight search helpers to map the repo.
- Keep the implementation in the main session unless you find 2 or more independent units.
- If one chunk would be materially better with an outside perspective, use Codex surgically.

### `>60%` context used

Decompose and fan out unless the task is genuinely tiny.

Rationale:
- At this point the main session becomes expensive to maintain and easier to confuse with implementation detail.
- Parallel work lets each worker start from a fresh prompt and avoid inheriting irrelevant history.
- The orchestrator should spend its remaining context on decomposition, chunk prompts, QA, and user decisions.

Typical action:
- Write `delegation-manifest.json`.
- Split independent chunks by file ownership.
- Route build chunks to Sonnet.
- Route skeptical review or precision work to Codex.

## Cache Discipline

Claude prompt cache TTL is 5 minutes. Treat that as a hard operational constraint.

Rules:
- Prefer keeping the main session cadence under `270` seconds between turns.
- If you know the next meaningful update will take longer, do not hover around the TTL boundary.
- Either return before the cache expires or accept that the cache will be cold and structure the workflow around that.
- When the pause will be long, aim for `>=1200` seconds rather than drifting around `300`.
- Never plan around exactly `300` seconds. It is too close to the expiration boundary to be reliable.

Why this matters:
- A near-expiry pause risks paying the cost of a cold session while still acting as if context is cheap.
- Sonnet and Codex workers already benefit from fresh, narrow prompts, so the main session should preserve its own cache discipline instead of letting it decay.

Operational rule of thumb:
- If you can answer, prompt, or checkpoint quickly, do it fast.
- If you need a long-running build or review cycle, lean into fan-out and treat the main session as a coordinator that returns after meaningful milestones.

## Sonnet vs Codex

Use this table after you have already decided that a chunk should not stay in the main session.

| Decision factor | Prefer Sonnet subagent | Prefer Codex |
|-----------------|------------------------|--------------|
| File scope | Multi-file changes, repo-wide conventions, a chunk that will create a branch to merge | One file, one subsystem, one algorithm, or one targeted review pass |
| Need for independent perspective | Low to medium. You mostly want throughput and clean implementation. | High. You want a second model family or an adversarial opinion. |
| Project conventions | Strongly matters. Sonnet is the default for following established local patterns and producing mergeable worktree diffs. | Less about convention-following, more about precision and skepticism. |
| Output shape | A chunk result that can be merged with sibling branches | A review report, a narrow patch, a risk assessment, or a deep focused diff |
| Typical role | Builder | Precision worker or reviewer |

### Choose Sonnet when

- The chunk touches several related files.
- The repo has strong conventions that should be mirrored.
- You want parallelizable implementation throughput.
- The output should merge cleanly into an integration branch.

### Choose Codex when

- The task benefits from an independent model perspective.
- You want adversarial review before or after integration.
- The risky part is narrow but subtle.
- You need a direct, highly scoped ask without loading a large narrative.

## Anti-Patterns

### Delegating too eagerly

Bad pattern:
- A small single-file fix is decomposed into a manifest, two worker chunks, and a QA round.

Why it fails:
- Coordination cost dominates the actual work.
- You burn time writing prompts and merging trivial diffs.
- The main session gains no meaningful context relief.

Preferred action:
- Do the edit locally when the task is small and context is healthy.

### Delegating when context is low

Bad pattern:
- Context is at 15%, but the orchestrator fans out because delegation "feels scalable."

Why it fails:
- You spend more tokens on orchestration than implementation.
- You increase branch, merge, and prompt overhead with no quality gain.

Preferred action:
- Keep the work in session.
- Use direct edits and local verification.

### Parallel chunks on the same files

Bad pattern:
- Two Sonnet chunks both touch `src/auth/session.ts` and `src/auth/types.ts`.

Why it fails:
- Merge conflicts become likely, and even "clean" merges can be semantically wrong.
- Review gets harder because no single chunk owns the file.
- The parallelism is fake because one chunk logically depends on the other.

Preferred action:
- Make one chunk depend on the other with `depends_on`.
- Or redraw chunk boundaries so file ownership is exclusive.

## Worked Examples

### Example 1: Small single-file fix

Task:
- Fix an off-by-one bug in `src/pagination.ts`.
- Add one unit test in `src/pagination.test.ts`.

Routing decision:
- Do not delegate.

Why:
- Context is likely under 30%.
- The change is small and tightly local.
- The implementation and verification cost is lower than manifest + fan-out overhead.

Recommended execution:
- Read the two files.
- Patch them in the main session.
- Run the targeted test command.

### Example 2: Medium three-chunk feature

Task:
- Add API key management to an admin console.
- Requires backend endpoints, frontend settings UI, and audit-log integration.

Routing decision:
- Delegate to Sonnet subagents.

Suggested chunking:
1. Backend API chunk
   - Files: `server/routes/adminKeys.ts`, `server/services/keyService.ts`, tests
2. Frontend settings chunk
   - Files: `web/src/pages/AdminKeys.tsx`, `web/src/components/KeyTable.tsx`
3. Audit-log chunk
   - Files: `server/services/auditLog.ts`, `server/events/adminKeyEvents.ts`

Why Sonnet:
- Each chunk spans multiple files.
- All chunks should follow project conventions and return mergeable diffs.
- The work is parallelizable if file ownership is clean.

Why not Codex:
- The value here is throughput, not an outside opinion.
- The chunk boundaries map naturally to conventional implementation work.

### Example 3: Large refactor with adversarial review

Task:
- Move a monolithic data-access layer to a repository pattern.
- Update services and tests across several modules.
- Validate that transaction handling and error propagation did not regress.

Routing decision:
- Mix Sonnet and Codex.

Suggested routing:
1. Sonnet chunk: repository interfaces and base implementations
2. Sonnet chunk: migrate service layer consumers
3. Sonnet chunk: update integration tests and fixtures
4. Codex chunk: adversarial review of transaction boundaries, failure modes, and missing tests

Why this mix works:
- Sonnet handles the broad multi-file refactor and produces mergeable branches.
- Codex provides a skeptical second pass that is not anchored to the same implementation assumptions.
- The main session integrates the branches, reviews Codex findings, runs project QA, and decides whether to address review comments before presenting the result.

Practical note:
- The Codex review chunk should not race against files still changing underneath it.
- Run it after the implementation chunks land, or point it at a stable integration branch snapshot.
