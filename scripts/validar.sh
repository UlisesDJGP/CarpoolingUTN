#!/usr/bin/env bash
# Validaciones de contrato e infraestructura. Sale 0 si todo pasa.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== YAML =="
python3 - <<'PY'
import yaml
for p in ["contracts/openapi.yaml", "infra/docker-compose.yml", ".github/workflows/ci.yml"]:
    yaml.safe_load(open(p))
    print(p, "OK")
PY

echo "== OpenAPI =="
if [ -x /tmp/opencode/oa/bin/openapi-spec-validator ]; then
  /tmp/opencode/oa/bin/openapi-spec-validator contracts/openapi.yaml
else
  venv=$(mktemp -d)
  python3 -m venv "$venv"
  "$venv/bin/pip" -q install openapi-spec-validator
  "$venv/bin/openapi-spec-validator" contracts/openapi.yaml
  rm -rf "$venv"
fi

echo "== Bash =="
bash -n infra/osm/extract.sh && echo "extract.sh OK"
bash -n scripts/validar.sh && echo "validar.sh OK"

echo "== Compose =="
docker compose -f infra/docker-compose.yml config --quiet && echo "compose OK"

echo "VALIDACION OK"
