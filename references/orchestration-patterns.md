# Orchestration Patterns and Anti-Patterns

This document covers the execution patterns that keep delegated work reliable. The orchestrator's job is not just to split work. It must split work in a way that can be merged, verified, explained, and abandoned safely when needed.

## Fan-Out Topology

The default topology is simple:
- Run independent implementation chunks in parallel.
- Run dependent chunks sequentially.
- Express the sequencing in `depends_on`.

### When parallel execution is correct

Parallel chunks are appropriate when all of the following are true:
- Each chunk has a clear objective.
- Each chunk owns a distinct file set.
- One chunk does not require code produced by another.
- Review and QA can still attribute outcomes to the correct chunk.

Good parallel example:
- Chunk A: backend API in `server/routes/*`
- Chunk B: frontend page in `web/src/pages/*`
- Chunk C: analytics event wiring in `server/events/*`

These can run together if the contracts are stable or already known.

### When sequential execution is correct

Run sequentially when:
- A later chunk needs a type, route, schema, or interface from an earlier chunk.
- Two chunks would otherwise touch the same file.
- A review chunk depends on a stable merged implementation.
- The second chunk exists mainly to consume or validate the first.

Good sequential example:
- Chunk A adds a backend route.
- Chunk B wires the frontend to the route.
- Chunk C performs adversarial review after A and B land.

Encode that order explicitly:

```json
{
  "id": "frontend-wireup",
  "depends_on": ["backend-route"]
}
```

## File Conflict Prevention

Two concurrent chunks must not touch the same file.

That rule is stricter than "they probably will not conflict." The reason is not just merge mechanics. It is ownership clarity.

Why the rule exists:
- Git conflicts are the obvious failure mode, but silent semantic conflicts are worse.
- If two workers both modify the same file, no one chunk cleanly owns the outcome.
- Review becomes slower because the orchestrator has to reconstruct intent across overlapping diffs.
- QA failures become harder to attribute.

Practical guidance:
- Use `files_touched` as a preflight conflict detector.
- If overlap appears, redraw the chunk boundary or serialize the work with `depends_on`.
- Prefer vertical slices with exclusive file ownership over horizontal slices that all thread through the same core files.

Bad split:
- Chunk A and Chunk B both edit `src/auth/session.ts`.

Better split:
- Chunk A owns session storage.
- Chunk B waits on A and then updates the UI consumer.

## Confirmation Checkpoint

Always show the manifest before running anything.

This checkpoint exists because the manifest is where the dangerous mistakes are easiest to catch:
- overlapping files
- wrong runner choice
- missing dependencies
- over-sized or under-sized chunks
- bad verification commands

Why the checkpoint is mandatory:
- It lets Sir reject a bad decomposition before work starts.
- It turns the plan into a shared contract rather than hidden orchestration state.
- It prevents "surprise" fan-out into a repo when the user expected a local edit.

What to show:
- Overall task
- Integration branch name
- Every chunk with runner, dependencies, files, and verification command

What not to do:
- Do not summarize the manifest so aggressively that file overlap and execution order disappear.

## Conflict Handling

If integration produces conflicts, stop and surface them to Sir.

Do not auto-resolve.

Minimum information to present:
- Which chunks or branches conflicted
- Which files are conflicted
- Whether the conflict is textual, semantic, or both
- The next safe options

Example operator message:
- `Merge conflict between token-backend and token-ui on server/routes/orgTokens.ts and web/src/api/orgTokens.ts. I stopped before resolving. Choose whether to re-chunk, resolve manually, or drop one chunk.`

Why auto-resolution is banned:
- The orchestrator does not have authority to silently pick between conflicting implementations.
- A technically clean merge may still violate the user's intent or one chunk's assumptions.

## QA Failure Handling

If a chunk verification or project verification fails, surface the failure and the offending diff, then ask Sir how to proceed.

Do not hide the failing command behind a generic "QA failed" message.

Minimum information to present:
- The exact verification command that failed
- Whether it was chunk-level or project-level verification
- The chunk most likely responsible
- The relevant diff or file list
- The captured failure output, summarized if long

Recommended flow:
1. Stop the pipeline at the first meaningful failure.
2. Identify the offending chunk when possible.
3. Show the chunk diff and the failed command.
4. Ask whether to repair, re-run, or discard the integration branch.

Why this matters:
- The user needs attribution, not just failure.
- Re-running blindly often wastes time if the failure is deterministic.

## Integration Branch Naming

Use this exact format:

`delegation/YYYYMMDD-HHMMSS`

Example:
- `delegation/20260511-163210`

Why this naming convention works:
- It is sortable.
- It makes delegated work clearly temporary and operational.
- It avoids colliding with feature branches or user-owned branches.

Do not improvise branch names like:
- `temp-work`
- `wip/parallel`
- `misc-refactor`

Those lose the operational meaning of the branch.

## Post-QA Branch Handling

Once QA passes, the integration branch has served its purpose. Decide what happens next.

Valid outcomes:
- Open a PR from the integration branch
- Merge the integration branch into the user's target branch
- Keep it temporarily for review and follow-up fixes
- Discard it if the user decides not to proceed

The orchestrator should state the branch name clearly in the final report so Sir can act on it.

Recommended final note:
- `QA passed on delegation/20260511-163210. You can now open a PR, merge it into the base branch, or discard it if you only wanted the experiment.`

## Rollback

If QA fails badly or the integration is clearly unsalvageable, delete the integration branch and return to the base branch.

Use rollback when:
- Multiple chunks are in conflict and the decomposition was wrong
- The failing branch is not worth repairing
- The user wants to abandon the delegated attempt

Rollback goals:
- Leave the repo in a predictable state
- Avoid stranding partial integration work as if it were valid
- Preserve the lesson: the manifest or chunking strategy needs adjustment

Operational sequence:
1. Stop further QA and merge attempts.
2. Return to the base branch.
3. Delete the integration branch.
4. Report that the delegated attempt was discarded.

What not to do:
- Do not leave a badly broken integration branch checked out as the apparent current state.

## Chunk Sizing

Chunk sizing is where most orchestration quality is won or lost.

### Too big

Bad example:
- One chunk owns the whole feature: backend, frontend, tests, docs, and rollout wiring.

Why it is bad:
- It defeats parallelism.
- The chunk prompt becomes vague.
- Review attribution disappears because one worker owns everything.
- A failure forces you to reason about the whole feature at once.

### Too small

Bad example:
- One chunk changes a single helper function that could have been edited inline in the main session.

Why it is bad:
- Prompt-writing and collection overhead exceed the implementation cost.
- The manifest becomes cluttered with work units that do not deserve orchestration.

### Right-sized

Good chunks usually have:
- One coherent outcome
- One file cluster or subsystem boundary
- One verification command that proves that outcome
- A size large enough to benefit from isolated focus, but small enough to review cleanly

Examples of good chunk sizes:
- `Implement backend token issuance and its tests`
- `Build the admin token management page and component tests`
- `Review the integrated auth flow for error propagation and missing tests`

## Common Anti-Patterns

### Fake parallelism

Bad:
- Two chunks run in parallel but both rely on the same unstable interface that neither has defined yet.

Result:
- The second chunk guesses, then breaks or conflicts later.

Fix:
- Make the interface-producing chunk run first.

### Hidden main-session work

Bad:
- The orchestrator quietly performs meaningful implementation outside the manifest after workers return.

Result:
- The reported plan no longer matches reality.
- Review attribution breaks.

Fix:
- If the main session must do a real piece of work, represent it as a `main` chunk.

### Weak verification

Bad:
- Every chunk uses a placeholder command or the same generic repo-level test command.

Result:
- Failures are slow to detect and hard to attribute.

Fix:
- Give each chunk a narrow, meaningful verification command and reserve the full suite for `project_verification`.

### Manifest after the fact

Bad:
- Fan-out starts before the manifest is shown or agreed.

Result:
- The user only sees the decomposition once the repo has already been touched.

Fix:
- Always checkpoint on the manifest first.
