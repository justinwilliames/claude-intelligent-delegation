# Delegation Manifest Schema

The manifest is the contract between the orchestrator and the runner. It describes the task, the chunks, their runners, file boundaries, and how each result will be verified. If the orchestrator can't explain the work clearly enough to write the manifest, it isn't ready to fan out.

The manifest is **immutable** once installed into a run (`delegate.sh write-manifest`). To change the plan, init a fresh run.

## Top-level fields

| Field | Type | Required | Notes |
|---|---|---|---|
| `task` | string | yes | Human-readable summary of the overall task. |
| `run_id` | string | yes | Echoes the run-id returned by `delegate.sh init`. Format: `YYYYMMDD-HHMMSS-<4hex>`. |
| `project_verification` | string | yes | Shell command, runs in the project root, after `apply`. The final QA gate. |
| `chunks` | array | yes | One or more chunk objects. |

There is no `integration_branch`. The skill is git-free; integration happens via workspace copy-back.

## Chunk object

| Field | Type | Required | Notes |
|---|---|---|---|
| `id` | string | yes | `^[a-z0-9][a-z0-9-]*$`. Stable, unique within the manifest. |
| `title` | string | yes | Short operator-friendly label. |
| `intent` | string | yes | The outcome the chunk must achieve. Not just a restatement of `title`. |
| `files_touched` | string[] | yes | **Non-empty.** Relative paths from project root. Used for: collision validation, audit (chunk must not produce undeclared files), preflight (target files must not pre-exist). |
| `runner` | enum | yes | One of `sonnet-subagent` \| `codex` \| `main`. |
| `depends_on` | string[] | no | Chunk IDs that must complete before this one starts. Default `[]`. |
| `verification` | string | no | Shell command, runs in project root after `apply`. Skipped if absent. |

### Runner semantics

- `sonnet-subagent` — orchestrator launches a Sonnet `Agent(...)` with the chunk prompt and absolute workspace path. Runs in background; orchestrator collects via `TaskOutput`.
- `codex` — orchestrator runs `codex.sh run ... --dir <workspace> --sandbox workspace-write`. Background.
- `main` — orchestrator implements this chunk itself in-session (after fan-out returns, or before, depending on `depends_on`). Reserve for chunks that genuinely need orchestrator context.

### Files_touched discipline

- Every file the chunk creates or modifies must be listed.
- Paths are **relative to project root**, NOT to the workspace.
- The chunk writes files at `<workspace>/<relative-path>` and the orchestrator copies them back preserving structure.
- Two concurrent chunks (no transitive `depends_on` relationship) listing the same path will fail `validate`.
- A chunk producing a file not in its `files_touched` will fail `audit`.

### Dependency rules

- `depends_on` cycles are rejected at `validate`.
- References to unknown chunk IDs are rejected at `validate`.
- Chunks with overlapping `files_touched` are valid **only** when one transitively depends on the other.

## Example

```json
{
  "task": "Add slugify and truncate utilities with tests",
  "run_id": "20260511-153022-a4b9",
  "project_verification": "npm test",
  "chunks": [
    {
      "id": "slugify",
      "title": "slugify utility",
      "intent": "Export slugify(str) that lowercases, trims, and hyphenates. Tests cover punctuation, whitespace, idempotency.",
      "files_touched": ["src/slugify.js", "src/slugify.test.js"],
      "runner": "sonnet-subagent",
      "depends_on": [],
      "verification": "node --test src/slugify.test.js"
    },
    {
      "id": "truncate",
      "title": "truncate utility",
      "intent": "Export truncate(str, max). Pass-through when len <= max, else slice + ellipsis. Tests cover edge cases.",
      "files_touched": ["src/truncate.js", "src/truncate.test.js"],
      "runner": "codex",
      "depends_on": [],
      "verification": "node --test src/truncate.test.js"
    }
  ]
}
```

## Validation

```bash
delegate.sh validate <run-id>
```

Catches: invalid types, missing required keys, duplicate `id`, unknown `runner`, unknown dep references, dep cycles, concurrent file overlaps, empty `files_touched`. Exits non-zero on first error class with a list of all errors.

## Manifest vs state

The manifest is the plan. `state.tsv` is the progress. The orchestrator updates `state.tsv` mid-flight via `delegate.sh set` — never edits the manifest. The two together let `/delegate resume` re-fan only what's still pending or failed.
