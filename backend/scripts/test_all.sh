#!/usr/bin/env bash
# Run pytest for shared/ and every service, each in its own venv.
# Deliberately NOT one pytest invocation across the repo: every service's
# app/ package is named "app", so a single shared run would risk pytest
# caching the wrong service's module under sys.modules["app"].
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILED=()

run_pytest() {
    local dir="$1"
    echo "=== pytest: $dir ==="
    if ! (cd "$dir" && uv sync --quiet && uv run pytest -q); then
        FAILED+=("$dir")
    fi
}

run_pytest "$ROOT/shared"
for svc in "$ROOT"/services/*/; do
    run_pytest "${svc%/}"
done

echo
if [ ${#FAILED[@]} -eq 0 ]; then
    echo "All packages passed."
else
    echo "Failed: ${FAILED[*]}"
    exit 1
fi
