#!/usr/bin/env bash
# Validaciones de contrato e infraestructura. Sale 0 si todo pasa.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== YAML =="
python3 - <<'PY'
import yaml
import glob
for p in sorted(glob.glob("contracts/*.yaml")) + ["infra/docker-compose.yml", ".github/workflows/ci.yml"]:
    yaml.safe_load(open(p))
    print(p, "OK")
try:
    yaml.safe_load("a: [")
except yaml.YAMLError:
    print("control negativo YAML OK")
else:
    raise SystemExit("ERROR: PyYAML acepto YAML invalido")
PY

echo "== OpenAPI =="
OA=/tmp/opencode/oa
if [ ! -x "$OA/bin/openapi-spec-validator" ]; then
  echo "creando venv de validacion en $OA (una sola vez)"
  python3 -m venv "$OA"
  "$OA/bin/pip" -q install --disable-pip-version-check openapi-spec-validator
fi
for spec in contracts/openapi*.yaml; do
  "$OA/bin/openapi-spec-validator" "$spec"
done

echo "== Control negativo de OpenAPI =="
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
# Sin `info`: el validador debe rechazarlo. Un spec 3.0.0 con `paths: {}` e `info`
# es valido, por eso el fixture anterior pasaba y el control no probaba nada.
cat > "$tmp/roto.yaml" <<'YAML'
openapi: 3.0.0
paths: {}
YAML
out=$("$OA/bin/openapi-spec-validator" "$tmp/roto.yaml" 2>&1) || true
if [ -z "$out" ]; then
  echo "ERROR: el validador acepto un OpenAPI invalido"
  exit 1
fi
case "$out" in
  *"'info' is a required property"*) echo "OpenAPI invalido detectado (ok)" ;;
  *) echo "ERROR: fallo por un motivo distinto al esperado:"; echo "$out" | head -3; exit 1 ;;
esac

echo "== Bash =="
bash -n infra/osm/extract.sh && echo "extract.sh OK"
bash -n scripts/validar.sh && echo "validar.sh OK"
bash -n scripts/smoke_infra.sh && echo "smoke_infra.sh OK"
bash -n scripts/test_zonas.sh && echo "test_zonas.sh OK"
bash -n scripts/ci_local.sh && echo "ci_local.sh OK"

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
