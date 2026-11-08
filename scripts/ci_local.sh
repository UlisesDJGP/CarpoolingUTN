#!/usr/bin/env bash
# Equivalente local de .github/workflows/ci.yml, mientras el CI de GitHub no arranque.
# Los pasos se derivan del workflow: si el workflow cambia, este script cambia con él.
# Uso: bash scripts/ci_local.sh [--self-test]
# Revisión: 13 de noviembre de 2026.
set -euo pipefail
cd "$(dirname "$0")/.."

WF="${CI_LOCAL_WORKFLOW:-.github/workflows/ci.yml}"

run_workflow() {
  python3 - "$1" <<'PY'
import glob
import os
import re
import subprocess
import sys
import yaml

wf_path = sys.argv[1]
wf = yaml.safe_load(open(wf_path))
ran = []

for job in (wf.get("jobs") or {}).values():
    for step in job.get("steps", []):
        if "run" not in step:
            continue  # acciones (uses:) no se replican en local
        cond = step.get("if")
        if cond:
            # Soporte mínimo igual al workflow: hashFiles('ruta') vacío omite el paso.
            m = re.search(r"hashFiles\('([^']+)'\)", cond)
            if m and not glob.glob(m.group(1)):
                continue
        cwd = step.get("working-directory", ".")
        print("== " + cwd + " ==", flush=True)
        subprocess.run(step["run"], shell=True, cwd=cwd, check=True)
        ran.append(cwd)

# Un proyecto con pyproject.toml que el workflow no ejecuta es un error, no un pase.
for pyproject in glob.glob("*/pyproject.toml"):
    d = os.path.dirname(pyproject)
    if d not in ran:
        sys.exit("ERROR: %s tiene pyproject.toml y el workflow no lo ejecuta" % d)

print("CI LOCAL OK")
PY
}

# Control negativo del armazón: un paso que falla debe abortar.
self_test() {
  tmp=$(mktemp -d)
  cat > "$tmp/wf.yml" <<'YML'
name: selftest
on: push
jobs:
  selftest:
    runs-on: ubuntu-latest
    steps:
      - run: "exit 1"
YML
  if ( CI_LOCAL_WORKFLOW="$tmp/wf.yml"; run_workflow "$tmp/wf.yml" ) >/dev/null 2>&1; then
    echo "FAIL: el armazón no detectó un paso fallido"
    rm -rf "$tmp"
    exit 1
  fi
  rm -rf "$tmp"
  echo "PASS: el armazón aborta con un paso fallido"
}

if [ "${1:-}" = "--self-test" ]; then
  self_test
  exit 0
fi

echo "== CI local: revision $(git rev-parse --short HEAD) =="
run_workflow "$WF"
