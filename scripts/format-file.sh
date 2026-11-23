#!/usr/bin/env bash
# Format one Python file the way the project pins it.
#
# OpenCode runs this after an edit (opencode.json's "formatter"). Claude Code
# reaches the same result through .claude/hooks/lint-format.sh; both find the
# nearest pyproject.toml and run that project's own ruff.
#
# Usage: scripts/format-file.sh /absolute/path/to/file.py
set -uo pipefail

file="${1:-}"
[ -n "$file" ] && [ -f "$file" ] || exit 0

case "$file" in
  *.py) ;;
  *) exit 0 ;;
esac

dir="$(cd "$(dirname "$file")" && pwd)"

while [ "$dir" != "/" ]; do
  if [ -f "$dir/pyproject.toml" ]; then
    ( cd "$dir" && uv run ruff format "$file" >/dev/null ) || exit 1
    exit 0
  fi
  dir="$(dirname "$dir")"
done

# Outside a uv project: leave the file alone rather than reformatting it with a
# different ruff version.
exit 0
