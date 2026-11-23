#!/usr/bin/env bash
# The checks CI runs (.github/workflows/ci.yml), for the components that
# changed. Nothing here touches the deployed server.
#
#   scripts/verify.sh                 # components changed since origin/develop
#   scripts/verify.sh application     # only the components named
#   scripts/verify.sh all             # everything that runs locally
#
# Not here: scripts/e2e.sh, which needs the Supabase CLI and the whole Docker
# stack, and only one run at a time. Use it directly.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

# A new service goes here and in .github/workflows/ci.yml's filters and
# components.
BACKENDS=(
  backend-data-collection
  backend-map-management
  backend-route-management
  backend-user-management
  backend-navigation-management
  backend-ai-training
  backend-positioning
)

usage() {
  cat <<'EOF'
Usage: scripts/verify.sh [component ... | all]

Components:
  application, packages, loadtest, docs
  backend-data-collection, backend-map-management, backend-route-management,
  backend-user-management, backend-navigation-management,
  backend-ai-training, backend-positioning

No arguments checks the components touched since origin/develop (including
untracked files). A change under packages/ checks every backend too, since
CI's filters do the same. Naming components runs exactly those.

Not run here: scripts/e2e.sh (needs the Supabase CLI and the Docker stack).
EOF
}

is_backend() {
  local name
  for name in "${BACKENDS[@]}"; do
    [ "$name" = "$1" ] && return 0
  done
  return 1
}

changed_components() {
  local base changed path component
  local seen=" "
  base="$(git merge-base HEAD origin/develop 2>/dev/null || echo HEAD)"
  changed="$( {
    git diff --name-only "$base"
    git ls-files --others --exclude-standard
  } | sort -u )"

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    case "$path" in
      application/*) component=application ;;
      packages/*) component=packages ;;
      loadtest/*) component=loadtest ;;
      backend-*/*) component="${path%%/*}" ;;
      gateway/*|db_schema/*|docker-compose*|e2e/*) component=stack ;;
      docs/admin-guide/*) component=docs ;;
      *) component="" ;;
    esac
    [ -n "$component" ] || continue
    case "$seen" in
      *" $component "*) ;;
      *)
        seen="$seen$component "
        printf '%s\n' "$component"
        ;;
    esac
  done <<< "$changed"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

auto=0
if [ $# -eq 0 ]; then
  auto=1
  components=()
  while IFS= read -r component; do
    [ -n "$component" ] && components+=("$component")
  done < <(changed_components)
elif [ "$1" = all ]; then
  components=("${BACKENDS[@]}" application packages loadtest docs)
else
  components=("$@")
fi

if [ ${#components[@]} -eq 0 ]; then
  echo "No component changed since origin/develop. Nothing to run."
  echo "Name one to force it, e.g. scripts/verify.sh application"
  exit 0
fi

# CI reruns every backend when the shared library changes. Do the same for an
# automatic run; an explicit list stays exactly what was asked for.
if [ "$auto" -eq 1 ]; then
  for name in "${components[@]}"; do
    if [ "$name" = packages ]; then
      for backend in "${BACKENDS[@]}"; do
        case " ${components[*]} " in
          *" $backend "*) ;;
          *) components+=("$backend") ;;
        esac
      done
      break
    fi
  done
fi

fail=0
ran=()

run_python() {
  local dir="$1"
  ran+=("$dir")
  echo
  echo "== $dir: ruff check"
  if ! ( cd "$dir" && uv run ruff check . ); then fail=1; fi
  echo "== $dir: pytest"
  if ! ( cd "$dir" && uv run pytest -q ); then fail=1; fi
}

run_flutter() {
  ran+=("application")
  echo
  echo "== application: dart format --set-exit-if-changed"
  if ! ( cd application && dart format --output=none --set-exit-if-changed . ); then fail=1; fi
  echo "== application: flutter analyze"
  if ! ( cd application && flutter analyze ); then fail=1; fi
  echo "== application: flutter test"
  if ! ( cd application && flutter test ); then fail=1; fi
}

run_docs() {
  ran+=("docs/admin-guide")
  echo
  echo "== docs/admin-guide: build_site.py --check"
  if ! uv run --no-project --python 3.14 --with markdown==3.11.2 \
    python docs/admin-guide/tools/build_site.py --check; then
    fail=1
  fi
}

note_stack() {
  echo
  echo "== gateway/db_schema/e2e changed: not run here."
  echo "   The behavior suite needs the Supabase CLI and the whole stack:"
  echo "   scripts/e2e.sh -v"
}

for component in "${components[@]}"; do
  case "$component" in
    application) run_flutter ;;
    packages|loadtest) run_python "$component" ;;
    docs) run_docs ;;
    stack) note_stack ;;
    *)
      if is_backend "$component"; then
        run_python "$component"
      else
        echo "Unknown component: $component" >&2
        usage >&2
        exit 2
      fi
      ;;
  esac
done

echo
if [ "$fail" -ne 0 ]; then
  echo "Checks failed. Re-run one at a time to see the full output."
  exit 1
fi
if [ ${#ran[@]} -eq 0 ]; then
  echo "Nothing ran locally. e2e is the check for these changes: scripts/e2e.sh -v"
  exit 0
fi
echo "All checks passed: ${ran[*]}"
