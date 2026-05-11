# Chunk Prompt Templates

This document defines the prompt structure for each runner type. The prompts should not sound literary. They should be concrete, bounded, and operational.

The most important rule is this:

- Sonnet subagents do not see the main session.

That means every Sonnet chunk prompt must be fully self-contained. If the prompt omits a constraint, a file boundary, a verification command, or critical project context, the worker does not have it.

Codex prompts can be shorter because Codex will inspect files directly. Main chunks are not prompts at all; they are imperative instructions the orchestrator executes itself after fan-out returns.

## Sonnet Subagent Template

Use this for implementation chunks executed in isolated worktrees.

### Required structure

```text
You are implementing one chunk of a larger delegated task in an isolated git worktree.

Task context:
- <overall feature or refactor goal>
- <why this chunk exists in the larger task>

Specific intent for this chunk:
- <exact outcome this chunk must achieve>

Files to touch:
- <path> - <why this file belongs to the chunk>
- <path> - <why this file belongs to the chunk>

Files not to touch:
- <path or subsystem to avoid>
- <path or subsystem to avoid>

Project context:
- Language: <language>
- Framework: <framework>
- Test runner: <test runner>
- Build or package tool: <tool if relevant>

Constraints:
- Follow existing project conventions.
- Keep the change scoped to this chunk.
- Do not make unrelated refactors.
- If you discover a blocker outside the allowed files, report it instead of expanding scope.

Verification command:
- <command>

Definition of done:
- <specific outcome 1>
- <specific outcome 2>
- <tests or checks expected to pass>

Output:
- Summarize what changed.
- List the files changed.
- Report whether the verification command passed.
```

### Why this structure matters

- Task context tells the worker how the chunk fits into the bigger job.
- Specific intent prevents the worker from "helpfully" broadening scope.
- Files to touch and files not to touch create ownership boundaries.
- Project context reduces bad assumptions about language, framework, and test tooling.
- Definition of done makes evaluation concrete.

## Filled-In Sonnet Example 1

```text
You are implementing one chunk of a larger delegated task in an isolated git worktree.

Task context:
- The overall task is to add organization-scoped API tokens for admins.
- This chunk owns the backend issuance and revocation flow so the UI and audit work can build on a stable server contract.

Specific intent for this chunk:
- Implement organization token creation, revocation, persistence, and server-side tests.

Files to touch:
- server/services/orgTokenService.ts - core token creation and revocation logic belongs here
- server/routes/orgTokens.ts - admin HTTP endpoints belong here
- server/routes/orgTokens.test.ts - route-level verification belongs here

Files not to touch:
- web/src/pages/OrgTokens.tsx
- web/src/components
- docs/

Project context:
- Language: TypeScript
- Framework: Node.js with Express-style route modules
- Test runner: Vitest
- Build or package tool: pnpm

Constraints:
- Follow existing route and service conventions in the repo.
- Keep the scope limited to backend token behavior.
- Do not add frontend code or documentation changes.
- If you need a new shared type outside these files, report it instead of expanding broadly.

Verification command:
- pnpm test server/routes/orgTokens.test.ts

Definition of done:
- Admin routes exist for create and revoke operations.
- Token secrets are not exposed beyond the intended response surface.
- Route tests cover success and failure paths.
- The verification command passes.

Output:
- Summarize what changed.
- List the files changed.
- Report whether the verification command passed.
```

## Filled-In Sonnet Example 2

```text
You are implementing one chunk of a larger delegated task in an isolated git worktree.

Task context:
- The overall task is to add a notification preference toggle to user settings.
- This chunk owns the UI that consumes an already-planned backend route.

Specific intent for this chunk:
- Add a settings toggle component that loads and updates the user's notification preference using the backend API.

Files to touch:
- web/src/pages/Settings.tsx - existing settings page wiring belongs here
- web/src/components/NotificationPreferenceToggle.tsx - new toggle UI belongs here
- web/src/components/NotificationPreferenceToggle.test.tsx - component coverage belongs here

Files not to touch:
- server/routes/userPreferences.ts
- server/models
- docs/

Project context:
- Language: TypeScript
- Framework: React
- Test runner: Vitest with Testing Library
- Build or package tool: pnpm

Constraints:
- Match existing settings-page patterns and component style.
- Keep API assumptions aligned with the backend route contract.
- Do not refactor unrelated settings components.
- If the backend contract is missing, report the blocker instead of guessing broadly.

Verification command:
- pnpm test web/src/components/NotificationPreferenceToggle.test.tsx

Definition of done:
- The toggle renders on the settings page.
- The component loads the current preference and can submit an updated value.
- The component test covers fetch, update, and error handling states.
- The verification command passes.

Output:
- Summarize what changed.
- List the files changed.
- Report whether the verification command passed.
```

## Codex Template

Codex prompts should be shorter and more direct. Codex will inspect the repo itself, so you do not need to inline as much context. The prompt should still be bounded.

### Required structure

```text
Directory: <repo path>

Ask:
- <specific implementation or review request>

Constraints:
- <scope boundary>
- <anything to avoid>
- <quality bar or review posture>

Expected output:
- <patch, review notes, risk list, or other exact output shape>
```

### Why this structure works

- `Directory` tells Codex where to operate.
- `Ask` states the actual job without narrative overhead.
- `Constraints` limit scope and prevent broad repo churn.
- `Expected output` prevents ambiguity about whether you want code, a review, or both.

## Filled-In Codex Example 1

```text
Directory: /project

Ask:
- Review the integrated billing refactor for hidden coupling between invoice calculation and payment gateway side effects.

Constraints:
- Focus on src/billing/invoiceEngine.ts, src/billing/paymentGateway.ts, and src/billing/processCharge.ts.
- Do not rewrite the feature unless a minimal patch is clearly needed.
- Prioritize transaction boundaries, error propagation, and missing tests.

Expected output:
- A concise review report with concrete findings, file references, and a minimal patch only if one issue is straightforward to fix.
```

## Filled-In Codex Example 2

```text
Directory: /project

Ask:
- Implement a narrowly scoped fix for token redaction so secret values are never logged from the organization token service.

Constraints:
- Limit changes to the token service and the closest relevant tests.
- Preserve existing logging structure where possible.
- Avoid unrelated refactors.

Expected output:
- A small patch with updated tests and a short note describing what changed and how it was verified.
```

## Main Chunk Template

`main` chunks are not prompts. They are imperative instructions carried out by the orchestrator directly after fan-out returns.

Use a `main` chunk when:
- The work depends on seeing the combined result of earlier chunks.
- The step is too small or too integration-specific to justify another worker.
- The orchestrator should retain direct control of the final action.

### Required structure

```text
Main chunk instructions:
1. <direct action>
2. <direct action>
3. <verification or reporting action>
```

Write these as explicit instructions, not as open-ended goals.

## Filled-In Main Example 1

```text
Main chunk instructions:
1. Merge the completed backend and UI token chunks into the integration branch.
2. Update docs/admin/org-tokens.md so it matches the merged route names and UI labels.
3. Run pnpm build and report whether the integration branch is ready for QA sign-off.
```

## Filled-In Main Example 2

```text
Main chunk instructions:
1. After the Sonnet implementation chunks land, apply the small config wiring change in config/featureFlags.ts.
2. Verify the new notification preference flag is enabled only for the intended environment.
3. Run pnpm test web/src/components/NotificationPreferenceToggle.test.tsx and summarize the final integrated state.
```

## Prompt Quality Checklist

Before sending any chunk prompt, check:
- Does the runner actually match the type of work?
- Is the scope narrow enough to own cleanly?
- Are file boundaries explicit?
- Is the verification command real and relevant?
- For Sonnet, could a fresh worker succeed with only the prompt text and the repo?

If the answer to the last question is no, the prompt is not ready.
