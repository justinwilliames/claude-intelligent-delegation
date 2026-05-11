#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  detect-verification.sh [project-directory]
EOF
}

print_line() {
  local kind=$1
  local command_string=$2
  printf '%s: %s\n' "$kind" "$command_string"
}

trim_whitespace() {
  local value=$1
  value=${value#"${value%%[![:space:]]*}"}
  value=${value%"${value##*[![:space:]]}"}
  printf '%s' "$value"
}

pyproject_has_pytest_dev_dep() {
  local pyproject_file=$1
  local line
  local trimmed
  local section=""
  local collecting_dev_array=0

  while IFS= read -r line || [[ -n $line ]]; do
    trimmed=${line%%#*}
    trimmed=$(trim_whitespace "$trimmed")

    [[ -z $trimmed ]] && continue

    if ((collecting_dev_array == 1)); then
      [[ $trimmed == *pytest* ]] && return 0
      [[ $trimmed == *"]"* ]] && collecting_dev_array=0
      continue
    fi

    if [[ $trimmed =~ ^\[(.+)\]$ ]]; then
      section=${BASH_REMATCH[1]}
      continue
    fi

    case "$section" in
      tool.poetry.dev-dependencies|tool.poetry.group.dev.dependencies)
        if [[ $trimmed == pytest* ]]; then
          return 0
        fi
        ;;
      project.optional-dependencies|dependency-groups)
        if [[ $trimmed =~ ^dev[[:space:]]*= ]]; then
          [[ $trimmed == *pytest* ]] && return 0
          if [[ $trimmed == *"["* && $trimmed != *"]"* ]]; then
            collecting_dev_array=1
          fi
        fi
        ;;
    esac

    if [[ $trimmed =~ ^dev-dependencies[[:space:]]*= ]]; then
      [[ $trimmed == *pytest* ]] && return 0
      if [[ $trimmed == *"["* && $trimmed != *"]"* ]]; then
        collecting_dev_array=1
      fi
    fi
  done < "$pyproject_file"

  return 1
}

has_make_test_target() {
  local makefile_path=$1
  local line
  local trimmed

  while IFS= read -r line || [[ -n $line ]]; do
    trimmed=$(trim_whitespace "$line")
    [[ -z $trimmed ]] && continue
    [[ $trimmed == \#* ]] && continue

    if [[ $trimmed =~ ^test[[:space:]]*::? ]]; then
      return 0
    fi
  done < "$makefile_path"

  return 1
}

main() {
  local project_dir=${1:-.}
  local found=0

  if (($# > 1)); then
    usage
    exit 1
  fi

  if [[ ! -d $project_dir ]]; then
    printf 'NO_VERIFICATION_DETECTED\n'
    exit 1
  fi

  if [[ -f $project_dir/package.json ]]; then
    if jq -e '.scripts.test | type == "string"' "$project_dir/package.json" >/dev/null 2>&1; then
      print_line "TEST" "npm test"
      found=1
    fi

    if jq -e '.scripts.typecheck | type == "string"' "$project_dir/package.json" >/dev/null 2>&1; then
      print_line "TYPECHECK" "npm run typecheck"
      found=1
    fi

    if ((found == 1)); then
      exit 0
    fi
  fi

  if [[ -f $project_dir/Cargo.toml ]]; then
    print_line "TEST" "cargo test && cargo check"
    exit 0
  fi

  if [[ -f $project_dir/pyproject.toml ]] && pyproject_has_pytest_dev_dep "$project_dir/pyproject.toml"; then
    print_line "TEST" "pytest"
    exit 0
  fi

  if [[ -f $project_dir/requirements.txt && ( -d $project_dir/test || -d $project_dir/tests ) ]]; then
    print_line "TEST" "python -m pytest"
    exit 0
  fi

  if [[ -f $project_dir/go.mod ]]; then
    print_line "TEST" "go test ./..."
    exit 0
  fi

  if [[ -f $project_dir/Makefile ]] && has_make_test_target "$project_dir/Makefile"; then
    print_line "TEST" "make test"
    exit 0
  fi

  printf 'NO_VERIFICATION_DETECTED\n'
  exit 1
}

main "$@"
