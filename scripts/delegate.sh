#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  delegate.sh validate-manifest <file>
  delegate.sh merge-worktrees <integration-branch> <branch1> [branch2 ...] [--repo <path>]
  delegate.sh qa <integration-branch> <manifest-file> [--repo <path>]

Sub-commands:
  validate-manifest  Validate a delegation manifest JSON file.
  merge-worktrees    Create/reset an integration branch and merge worktree branches into it.
  qa                 Run chunk verification commands and project-level verification.
EOF
}

print_error() {
  printf 'ERROR: %s\n' "$*" >&2
}

require_command() {
  local command_name=$1
  if ! command -v "$command_name" >/dev/null 2>&1; then
    print_error "missing required command: $command_name"
    exit 1
  fi
}

resolve_path() {
  local repo_path=$1
  local candidate=$2

  if [[ $candidate = /* ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  if [[ -e $candidate ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  printf '%s/%s\n' "$repo_path" "$candidate"
}

parse_repo_flag() {
  REPO_PATH="."
  POSITIONAL_ARGS=()

  while (($# > 0)); do
    case "$1" in
      --repo)
        if (($# < 2)); then
          print_error "--repo requires a path"
          exit 1
        fi
        REPO_PATH=$2
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        POSITIONAL_ARGS[${#POSITIONAL_ARGS[@]}]=$1
        shift
        ;;
    esac
  done
}

ensure_git_repo() {
  local repo_path=$1
  if ! git -C "$repo_path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    print_error "not a git repository: $repo_path"
    exit 1
  fi
}

validate_manifest() {
  local manifest_file=$1
  local error_line
  local has_errors=0

  if [[ ! -f $manifest_file ]]; then
    print_error "manifest file not found: $manifest_file"
    return 1
  fi

  if ! jq empty "$manifest_file" >/dev/null 2>&1; then
    print_error "invalid JSON: $manifest_file"
    return 1
  fi

  while IFS= read -r error_line; do
    [[ -z $error_line ]] && continue
    has_errors=1
    print_error "$error_line"
  done < <(
    jq -r '
      def chunks_array:
        if (.chunks? | type) == "array" then .chunks else [] end;

      def ids:
        [chunks_array[] | select(type == "object" and (.id? | type == "string")) | .id];

      def chunk_by_id($id):
        ([chunks_array[] | select(type == "object" and (.id? | type == "string") and .id == $id)][0]);

      def dep_ids($id):
        [chunk_by_id($id).depends_on[]? | select(type == "string")];

      def files_for($id):
        [chunk_by_id($id).files_touched[]? | select(type == "string")];

      def reaches($from; $to; $seen):
        if ($seen | index($from)) != null then
          false
        else
          [dep_ids($from)[] | select(. == $to or reaches(.; $to; $seen + [$from]))] | length > 0
        end;

      def has_cycle_from($id; $stack):
        if ($stack | index($id)) != null then
          true
        else
          [dep_ids($id)[] | select(has_cycle_from(.; $stack + [$id]))] | length > 0
        end;

      if type != "object" then
        "manifest root must be an object"
      else
        [
          (["task", "integration_branch", "chunks"] - (keys_unsorted))[]? | "missing top-level key: \(.)",
          (if has("task") and (.task | type != "string") then "task must be a string" else empty end),
          (if has("integration_branch") and (.integration_branch | type != "string") then "integration_branch must be a string" else empty end),
          (if has("project_verification") and (.project_verification | type != "string") then "project_verification must be a string" else empty end),
          (if has("chunks") and (.chunks | type != "array") then "chunks must be an array" else empty end),
          (
            if (.chunks? | type) == "array" then
              .chunks
              | to_entries[]
              | .key as $index
              | .value as $chunk
              | if ($chunk | type) != "object" then
                  "chunk[\($index)] must be an object"
                else
                  (
                    (["id", "title", "intent", "runner", "depends_on", "verification"] - ($chunk | keys_unsorted))[]?
                    | "chunk[\($index)] missing key: \(.)"
                  ),
                  (
                    if ($chunk | has("runner")) and ($chunk.runner != "sonnet-subagent" and $chunk.runner != "codex" and $chunk.runner != "main") then
                      "chunk[\($index)] has invalid runner: \($chunk.runner)"
                    else
                      empty
                    end
                  ),
                  (
                    if ($chunk | has("depends_on")) and ($chunk.depends_on | type != "array") then
                      "chunk[\($index)] depends_on must be an array"
                    else
                      empty
                    end
                  ),
                  (
                    if ($chunk | has("verification")) and ($chunk.verification | type != "string") then
                      "chunk[\($index)] verification must be a string"
                    else
                      empty
                    end
                  ),
                  (
                    if ($chunk | has("files_touched")) and ($chunk.files_touched | type != "array") then
                      "chunk[\($index)] files_touched must be an array"
                    else
                      empty
                    end
                  ),
                  (
                    if ($chunk | has("files_touched")) and ($chunk.files_touched | type == "array") and any($chunk.files_touched[]?; type != "string") then
                      "chunk[\($index)] files_touched entries must be strings"
                    else
                      empty
                    end
                  )
                end
            else
              empty
            end
          ),
          (
            ids
            | group_by(.)
            | .[]
            | select(length > 1)
            | "duplicate chunk id: \(.[0])"
          ),
          (
            .chunks[]?
            | select(type == "object" and (.id? | type == "string") and (.depends_on? | type == "array"))
            | .id as $id
            | .depends_on[]?
            | select(type != "string")
            | "chunk \($id) has a non-string dependency entry: \(tostring)"
          ),
          (
            ids as $ids
            | .chunks[]?
            | select(type == "object" and (.id? | type == "string") and (.depends_on? | type == "array"))
            | .id as $id
            | .depends_on[]?
            | select(type == "string" and ($ids | index(.) == null))
            | "chunk \($id) depends on unknown chunk: \(.)"
          ),
          (
            ids[]
            | select(has_cycle_from(.; []))
            | "dependency cycle detected at chunk: \(.)"
          ),
          (
            ids as $ids
            | range(0; ($ids | length)) as $left_index
            | range($left_index + 1; ($ids | length)) as $right_index
            | $ids[$left_index] as $left_id
            | $ids[$right_index] as $right_id
            | select((reaches($left_id; $right_id; []) or reaches($right_id; $left_id; [])) | not)
            | [
                files_for($left_id)[] as $file
                | select(files_for($right_id) | index($file) != null)
                | $file
              ] | unique as $overlap
            | select(($overlap | length) > 0)
            | "concurrent chunks \($left_id) and \($right_id) share files_touched entries: \($overlap | join(", "))"
          )
        ]
        | .[]
      end
    ' "$manifest_file"
  )

  if ((has_errors == 1)); then
    return 1
  fi

  printf 'PASS\n'
}

detect_default_branch() {
  local repo_path=$1
  local candidate

  for candidate in main master; do
    if git -C "$repo_path" show-ref --verify --quiet "refs/heads/$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  for candidate in main master; do
    if git -C "$repo_path" show-ref --verify --quiet "refs/remotes/origin/$candidate"; then
      printf 'origin/%s\n' "$candidate"
      return 0
    fi
  done

  return 1
}

merge_worktrees() {
  local integration_branch
  local default_branch
  local branch_name
  local conflict_file

  parse_repo_flag "$@"
  set -- "${POSITIONAL_ARGS[@]}"

  if (($# < 2)); then
    print_error "merge-worktrees requires <integration-branch> and at least one branch"
    usage
    exit 1
  fi

  integration_branch=$1
  shift

  ensure_git_repo "$REPO_PATH"

  if ! default_branch=$(detect_default_branch "$REPO_PATH"); then
    print_error "could not find default branch (main or master)"
    exit 1
  fi

  git -C "$REPO_PATH" checkout -B "$integration_branch" "$default_branch" >/dev/null

  for branch_name in "$@"; do
    if git -C "$REPO_PATH" merge --no-ff --no-edit "$branch_name"; then
      printf 'MERGED %s\n' "$branch_name"
      continue
    fi

    printf 'CONFLICT: merge failed for %s\n' "$branch_name" >&2
    while IFS= read -r conflict_file; do
      [[ -n $conflict_file ]] && printf 'CONFLICT_FILE: %s\n' "$conflict_file" >&2
    done < <(git -C "$REPO_PATH" diff --name-only --diff-filter=U)
    exit 2
  done

  printf 'INTEGRATION_BRANCH: %s\n' "$integration_branch"
}

run_command_in_repo() {
  local repo_path=$1
  local command_string=$2

  (
    cd "$repo_path"
    bash -lc "$command_string"
  )
}

qa() {
  local integration_branch
  local manifest_arg
  local manifest_file
  local chunk_id
  local verification_command
  local project_command
  local total_checks=0
  local failed_checks=0

  parse_repo_flag "$@"
  set -- "${POSITIONAL_ARGS[@]}"

  if (($# != 2)); then
    print_error "qa requires <integration-branch> <manifest-file>"
    usage
    exit 1
  fi

  integration_branch=$1
  manifest_arg=$2

  ensure_git_repo "$REPO_PATH"

  manifest_file=$(resolve_path "$REPO_PATH" "$manifest_arg")

  if ! validate_manifest "$manifest_file" >/dev/null; then
    exit 1
  fi

  if ! jq -e 'has("project_verification") and (.project_verification | type == "string") and (.project_verification | gsub("^\\s+|\\s+$"; "") | length > 0)' "$manifest_file" >/dev/null 2>&1; then
    print_error "manifest is missing a non-empty project_verification command"
    exit 1
  fi

  git -C "$REPO_PATH" checkout "$integration_branch" >/dev/null

  while IFS=$'\t' read -r chunk_id verification_command; do
    [[ -z $chunk_id || -z $verification_command ]] && continue
    total_checks=$((total_checks + 1))

    if run_command_in_repo "$REPO_PATH" "$verification_command"; then
      printf 'PASS %s\n' "$chunk_id"
    else
      printf 'FAIL %s\n' "$chunk_id"
      failed_checks=$((failed_checks + 1))
    fi
  done < <(
    jq -r '
      .chunks[]?
      | select(type == "object" and (.id? | type == "string") and (.verification? | type == "string"))
      | .verification as $verification
      | select($verification | gsub("^\\s+|\\s+$"; "") | length > 0)
      | [.id, $verification]
      | @tsv
    ' "$manifest_file"
  )

  project_command=$(jq -r '.project_verification' "$manifest_file")
  total_checks=$((total_checks + 1))
  if run_command_in_repo "$REPO_PATH" "$project_command"; then
    printf 'PASS project_verification\n'
  else
    printf 'FAIL project_verification\n'
    failed_checks=$((failed_checks + 1))
  fi

  if ((failed_checks == 0)); then
    printf 'PASS: %d/%d checks passed\n' "$total_checks" "$total_checks"
    return 0
  fi

  printf 'FAIL: %d/%d checks failed\n' "$failed_checks" "$total_checks"
  return 1
}

main() {
  require_command jq
  require_command git

  if (($# == 0)); then
    usage
    exit 1
  fi

  case "$1" in
    validate-manifest)
      if (($# != 2)); then
        usage
        exit 1
      fi
      validate_manifest "$2"
      ;;
    merge-worktrees)
      shift
      merge_worktrees "$@"
      ;;
    qa)
      shift
      qa "$@"
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      print_error "unknown sub-command: $1"
      usage
      exit 1
      ;;
  esac
}

main "$@"
