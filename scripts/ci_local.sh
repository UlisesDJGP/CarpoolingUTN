#!/usr/bin/env bash
# Equivalente local de .github/workflows/ci.yml, mientras el CI de GitHub no arranque.
# Corre en un clon limpio y su salida se pega en cada PR. Revisión: 13 de noviembre de 2026.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== CI local: revision $(git rev-parse --short HEAD) =="

for d in db routing; do
  if [ -f "$d/pyproject.toml" ]; then
    echo "== $d =="
    (
      cd "$d"
      uv sync --frozen
      uv run ruff check .
      uv run mypy .
      uv run pytest -m "not integration"
    )
  else
    echo "== $d: sin pyproject.toml, se omite (igual que el workflow) =="
  fi
done

echo "CI LOCAL OK"
