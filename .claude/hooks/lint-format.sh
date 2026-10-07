#!/usr/bin/env bash
# PostToolUse hook (Edit|MultiEdit|Write): auto-format the edited file and
# surface any remaining lint errors back to Claude.
set -uo pipefail

input="$(cat)"
file_path="$(echo "$input" | jq -r '.tool_input.file_path // empty')"

[ -z "$file_path" ] && exit 0
[ -f "$file_path" ] || exit 0

output=""
status=0

case "$file_path" in
  *.py)
    dir="$(dirname "$file_path")"
    project_dir=""
    while [ "$dir" != "/" ]; do
      if [ -f "$dir/pyproject.toml" ]; then
        project_dir="$dir"
        break
      fi
      dir="$(dirname "$dir")"
    done
    [ -z "$project_dir" ] && exit 0

    format_out="$(cd "$project_dir" && uv run ruff format "$file_path" 2>&1)"
    check_out="$(cd "$project_dir" && uv run ruff check "$file_path" 2>&1)"
    check_status=$?
    output="$format_out"$'\n'"$check_out"
    status=$check_status
    ;;
  *.dart)
    app_dir="$(dirname "$file_path")"
    while [ "$app_dir" != "/" ]; do
      if [ -f "$app_dir/pubspec.yaml" ]; then
        break
      fi
      app_dir="$(dirname "$app_dir")"
    done
    [ "$app_dir" = "/" ] && exit 0

    format_out="$(dart format "$file_path" 2>&1)"
    check_out="$(cd "$app_dir" && dart analyze "$file_path" 2>&1)"
    check_status=$?
    output="$format_out"$'\n'"$check_out"
    status=$check_status
    ;;
  *)
    exit 0
    ;;
esac

if [ "$status" -ne 0 ]; then
  echo "$output" >&2
  exit 2
fi

exit 0
