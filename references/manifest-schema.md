# Delegation Manifest Schema

`delegation-manifest.json` is the contract between the orchestrator and the runner. It describes what the overall task is, which chunks exist, who should execute each chunk, what file boundaries matter, and how each result will be verified.

The manifest is intentionally explicit. If the orchestrator cannot explain the work clearly enough to write the manifest, it is not ready to fan out.

## Full JSON Schema

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://example.com/schemas/delegation-manifest.schema.json",
  "title": "Delegation Manifest",
  "description": "Schema for delegation-manifest.json used by the intelligent-delegation orchestrator.",
  "type": "object",
  "additionalProperties": false,
  "required": [
    "task",
    "integration_branch",
    "project_verification",
    "chunks"
  ],
  "properties": {
    "task": {
      "type": "string",
      "minLength": 1,
      "description": "Human-readable summary of the overall delegated task. This is what the integration branch is trying to accomplish."
    },
    "integration_branch": {
      "type": "string",
      "pattern": "^delegation\\/[0-9]{8}-[0-9]{6}$",
      "description": "Name of the branch where completed chunk outputs will be merged together. Format: delegation/YYYYMMDD-HHMMSS."
    },
    "project_verification": {
      "type": "string",
      "minLength": 1,
      "description": "Top-level verification command that runs against the integrated branch after all chunk work lands. This is the final QA gate for the combined change."
    },
    "chunks": {
      "type": "array",
      "minItems": 1,
      "description": "Ordered list of execution chunks. Parallelism is allowed only where depends_on does not create an ordering constraint and files_touched do not overlap.",
      "items": {
        "type": "object",
        "additionalProperties": false,
        "required": [
          "id",
          "title",
          "intent",
          "files_touched",
          "runner",
          "depends_on",
          "verification"
        ],
        "properties": {
          "id": {
            "type": "string",
            "pattern": "^[a-z0-9][a-z0-9-]*$",
            "description": "Stable chunk identifier used for logs, dependency references, and reporting. It must be unique within the manifest."
          },
          "title": {
            "type": "string",
            "minLength": 1,
            "description": "Short operator-friendly label for the chunk. This appears in review and QA output."
          },
          "intent": {
            "type": "string",
            "minLength": 1,
            "description": "The exact outcome the chunk must achieve. This should state the purpose and boundary of the chunk, not just restate the title."
          },
          "files_touched": {
            "type": "array",
            "minItems": 1,
            "uniqueItems": true,
            "description": "Best-guess list of files the chunk is expected to edit, create, or materially depend on. Used primarily for conflict detection and chunk-boundary review before execution.",
            "items": {
              "type": "string",
              "minLength": 1
            }
          },
          "runner": {
            "type": "string",
            "enum": [
              "sonnet-subagent",
              "codex",
              "main"
            ],
            "description": "Execution engine for the chunk. sonnet-subagent means a Sonnet worktree build chunk, codex means a Codex precision or review chunk, and main means the orchestrator performs the work directly after fan-out returns."
          },
          "depends_on": {
            "type": "array",
            "uniqueItems": true,
            "description": "List of chunk IDs that must complete before this chunk may start. Use this to enforce sequential execution when one chunk consumes another's output or when file ownership would otherwise overlap.",
            "items": {
              "type": "string",
              "pattern": "^[a-z0-9][a-z0-9-]*$"
            }
          },
          "verification": {
            "type": "string",
            "minLength": 1,
            "description": "Per-chunk verification command to run after this chunk lands. This should be narrow when possible: a targeted test, typecheck, lint scope, or build step relevant to the chunk."
          }
        }
      }
    }
  }
}
```

## Field Semantics

### `task`

Use a plain-English sentence that states the integrated outcome. This is not a copy of the user's full prompt. It should be specific enough that a reviewer can tell whether the manifest is on target.

Good:
- `Add API key management to the admin console with backend, UI, and audit logging.`

Bad:
- `Do the work Sir asked for.`

### `integration_branch`

This is the merge target for all completed chunks. The naming convention is operational, not cosmetic:

- Format: `delegation/YYYYMMDD-HHMMSS`
- Example: `delegation/20260511-141530`

Why it matters:
- It keeps delegated work easy to identify.
- It makes cleanup and rollback straightforward.
- It separates temporary integration state from feature branches and the user's working branch.

### `project_verification`

This is the final integrated QA command. It runs after chunk-level work has been merged.

Use it for:
- The full project test suite
- The canonical build
- An end-to-end test command
- Any composite QA gate the project treats as release-worthy

Do not use it for:
- A narrow unit test that only covers one chunk
- A command that only validates a single file

### `chunks`

The manifest must express real chunk boundaries. Every chunk should have:
- A clear purpose
- Exclusive or carefully sequenced file ownership
- A runner choice that matches the work
- A verification command that proves the chunk did what it claimed

## Runner Enum

### `sonnet-subagent`

Pick this when:
- The chunk is implementation-heavy.
- The chunk spans multiple files.
- The repo has conventions that matter.
- The chunk should return as a mergeable worktree diff.

Avoid it when:
- The change is so small it belongs in the main session.
- The only value you need is an outside opinion rather than implementation throughput.

### `codex`

Pick this when:
- You want a different model family to inspect or implement a narrow area.
- The task is precision work, deep algorithmic work, or adversarial review.
- The prompt can be short and direct because Codex will read the files itself.

Avoid it when:
- You need a broad, conventional multi-file build chunk that cleanly mirrors repo patterns.

### `main`

Pick this when:
- The orchestrator should apply a final integration step after worker results come back.
- The work is tightly coupled to merge results or QA output.
- The step is too small to justify another worker but should still be represented explicitly in the plan.

Typical `main` chunks:
- Update a changelog after implementation chunks land
- Resolve a small integration-only rename after a reviewed merge
- Apply a final config tweak once generated outputs are present

## `depends_on` Semantics

`depends_on` is an array of chunk IDs that must complete before the current chunk may start.

Use it when:
- A chunk needs code created by another chunk.
- Two chunks would otherwise touch the same files.
- A review chunk should wait for a stable integration snapshot.

Do not use it as a vague hint. It is an execution barrier.

Examples:
- `[]` means the chunk can start immediately.
- `["backend-api"]` means this chunk must wait for `backend-api`.
- `["repo-interfaces", "service-migration"]` means the chunk depends on both earlier chunks finishing.

Practical rule:
- If two chunks cannot safely run at the same time, express that with `depends_on`.

## `files_touched`

This is a best-guess list, not a legal contract, but it still matters.

Why it exists:
- The orchestrator uses it to spot parallel conflicts before they happen.
- It makes chunk boundaries reviewable during the confirmation checkpoint.
- It helps the operator explain who owns which part of the codebase.

How specific to be:
- List concrete files whenever you know them.
- Use the files most likely to change, plus tests.
- Do not dump an entire directory tree unless the chunk truly ranges that broadly.

Good:
- `["src/auth/service.ts", "src/auth/service.test.ts"]`

Bad:
- `["src"]`

## `verification`

This is the per-chunk validation command. Run it after the chunk lands.

Goals:
- Confirm the chunk's own claim.
- Fail fast before the entire integration branch proceeds too far.
- Narrow blame when something breaks.

Good commands:
- `pnpm test src/auth/service.test.ts`
- `go test ./internal/auth/...`
- `cargo test session_manager`
- `npm run lint -- web/src/pages/AdminKeys.tsx`

Weak commands:
- `echo done`
- A full repo test suite when a targeted check is available

## `project_verification` vs `verification`

Use both, but for different scopes:

- `verification` is per chunk and runs after that chunk lands.
- `project_verification` is top-level and runs against the integration branch after all planned work is in place.

Think of it this way:
- Chunk verification proves the local unit is sane.
- Project verification proves the combined change is sane.

## Worked Example 1: Small 2-Chunk Feature

Both chunks use Sonnet subagents and run sequentially because the UI depends on the backend contract.

```json
{
  "task": "Add a user notification preference toggle with backend persistence and a settings UI.",
  "integration_branch": "delegation/20260511-141530",
  "project_verification": "pnpm test && pnpm build",
  "chunks": [
    {
      "id": "prefs-backend",
      "title": "Add notification preference persistence",
      "intent": "Create the backend model, route, and tests for storing a user's notification preference.",
      "files_touched": [
        "server/models/userPreferences.ts",
        "server/routes/userPreferences.ts",
        "server/routes/userPreferences.test.ts"
      ],
      "runner": "sonnet-subagent",
      "depends_on": [],
      "verification": "pnpm test server/routes/userPreferences.test.ts"
    },
    {
      "id": "prefs-ui",
      "title": "Expose preference toggle in settings",
      "intent": "Add a settings toggle that reads and updates the notification preference using the new backend route.",
      "files_touched": [
        "web/src/pages/Settings.tsx",
        "web/src/components/NotificationPreferenceToggle.tsx",
        "web/src/components/NotificationPreferenceToggle.test.tsx"
      ],
      "runner": "sonnet-subagent",
      "depends_on": [
        "prefs-backend"
      ],
      "verification": "pnpm test web/src/components/NotificationPreferenceToggle.test.tsx"
    }
  ]
}
```

Why this shape is correct:
- The backend must exist before the UI can safely wire against it.
- The file boundaries are clear.
- The project verification is broader than each chunk's verification.

## Worked Example 2: Medium 3-Chunk Refactor

Two Sonnet chunks run in parallel. A Codex review chunk waits for both to finish.

```json
{
  "task": "Refactor billing code to separate invoice calculation from payment gateway side effects.",
  "integration_branch": "delegation/20260511-150945",
  "project_verification": "npm test && npm run typecheck",
  "chunks": [
    {
      "id": "invoice-engine",
      "title": "Extract invoice calculation module",
      "intent": "Move pricing and discount calculation into a dedicated invoice engine with focused unit tests.",
      "files_touched": [
        "src/billing/invoiceEngine.ts",
        "src/billing/invoiceEngine.test.ts",
        "src/billing/calculateInvoice.ts"
      ],
      "runner": "sonnet-subagent",
      "depends_on": [],
      "verification": "npm test -- invoiceEngine"
    },
    {
      "id": "gateway-boundary",
      "title": "Isolate payment gateway adapter",
      "intent": "Pull payment processor calls behind a gateway adapter so billing orchestration no longer mixes API calls with price calculation.",
      "files_touched": [
        "src/billing/paymentGateway.ts",
        "src/billing/processCharge.ts",
        "src/billing/processCharge.test.ts"
      ],
      "runner": "sonnet-subagent",
      "depends_on": [],
      "verification": "npm test -- processCharge"
    },
    {
      "id": "billing-review",
      "title": "Adversarial review of billing boundaries",
      "intent": "Inspect the refactor for hidden coupling, missing error-path tests, and places where calculation and gateway concerns are still mixed.",
      "files_touched": [
        "src/billing/invoiceEngine.ts",
        "src/billing/paymentGateway.ts",
        "src/billing/processCharge.ts"
      ],
      "runner": "codex",
      "depends_on": [
        "invoice-engine",
        "gateway-boundary"
      ],
      "verification": "npm run typecheck"
    }
  ]
}
```

Why this shape is correct:
- The two implementation chunks do not share files.
- Codex is used for independent skeptical review, not for the main implementation throughput.
- The review waits for a stable combined state.

## Worked Example 3: Large 4-Chunk Build

This example mixes Sonnet parallel build chunks, a Codex adversarial pass, and a final main-session integration chunk.

```json
{
  "task": "Add organization-scoped API tokens with admin UI, backend issuance, audit events, and final documentation updates.",
  "integration_branch": "delegation/20260511-163210",
  "project_verification": "pnpm test && pnpm build && pnpm lint",
  "chunks": [
    {
      "id": "token-backend",
      "title": "Build token issuance backend",
      "intent": "Implement organization token creation, revocation, storage, and server-side tests.",
      "files_touched": [
        "server/services/orgTokenService.ts",
        "server/routes/orgTokens.ts",
        "server/routes/orgTokens.test.ts"
      ],
      "runner": "sonnet-subagent",
      "depends_on": [],
      "verification": "pnpm test server/routes/orgTokens.test.ts"
    },
    {
      "id": "token-ui",
      "title": "Build admin token management UI",
      "intent": "Add the admin page and components for creating, listing, and revoking organization tokens.",
      "files_touched": [
        "web/src/pages/OrgTokens.tsx",
        "web/src/components/OrgTokenTable.tsx",
        "web/src/components/OrgTokenDialog.tsx"
      ],
      "runner": "sonnet-subagent",
      "depends_on": [],
      "verification": "pnpm test web/src/pages/OrgTokens.test.tsx"
    },
    {
      "id": "token-review",
      "title": "Adversarial security review",
      "intent": "Review token handling for secret exposure, revocation edge cases, audit coverage, and missing validation across the backend and UI integration.",
      "files_touched": [
        "server/services/orgTokenService.ts",
        "server/routes/orgTokens.ts",
        "web/src/pages/OrgTokens.tsx"
      ],
      "runner": "codex",
      "depends_on": [
        "token-backend",
        "token-ui"
      ],
      "verification": "pnpm lint"
    },
    {
      "id": "docs-and-wireup",
      "title": "Finalize docs and integration notes",
      "intent": "Update operator-facing docs and any final config wiring once the implementation and review chunks have landed.",
      "files_touched": [
        "README.md",
        "docs/admin/org-tokens.md",
        "config/featureFlags.ts"
      ],
      "runner": "main",
      "depends_on": [
        "token-backend",
        "token-ui",
        "token-review"
      ],
      "verification": "pnpm build"
    }
  ]
}
```

Why this shape is correct:
- The main chunk is reserved for final integration work that benefits from seeing all prior outputs together.
- Codex reviews the risky security-sensitive area after implementation stabilizes.
- Sonnet owns the two broad build chunks in parallel.
