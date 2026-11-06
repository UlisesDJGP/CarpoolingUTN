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
bash -n scripts/smoke_infra.sh && echo "smoke_infra.sh OK"
bash -n scripts/test_zonas.sh && echo "test_zonas.sh OK"

echo "== Antiefluxo E4: un solo .pbf en el directorio montado =="
pbf_count=$(find infra/osm/valhalla -maxdepth 1 -name '*.pbf' | wc -l)
if [ "$pbf_count" -gt 1 ]; then
  echo "ERROR E4: $pbf_count .pbf en infra/osm/valhalla/; Valhalla construye con todos y degrada el grafo (auditoria P0 parte 2, E4)."
  find infra/osm/valhalla -maxdepth 1 -name '*.pbf'
  exit 1
fi
echo "pbf en valhalla/: $pbf_count (ok)"

echo "== Compose =="
docker compose -f infra/docker-compose.yml config --quiet && echo "compose OK"

echo "VALIDACION OK"
