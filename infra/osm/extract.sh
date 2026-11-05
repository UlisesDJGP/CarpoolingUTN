#!/usr/bin/env bash
# Descarga el extracto OSM de la zona y lo recorta al área de operación.
# Requiere Docker. Uso: infra/osm/extract.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENV_FILE="$ROOT/infra/.env"

if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi

: "${ZONE_BBOX:?Definir ZONE_BBOX en infra/.env}"
: "${OSM_SOURCE_URL:?Definir OSM_SOURCE_URL en infra/.env}"

if [ "$ZONE_BBOX" = "PENDIENTE_D1" ] || [ "$OSM_SOURCE_URL" = "PENDIENTE_D1" ]; then
  echo "Falta confirmar la zona de operación (decisión D1)." >&2
  echo "Completar ZONE_BBOX y OSM_SOURCE_URL en infra/.env." >&2
  exit 2
fi

OUT_DIR="$ROOT/infra/osm/valhalla"
SOURCE_DIR="$ROOT/infra/osm"
mkdir -p "$OUT_DIR"

# El .pbf fuente vive fuera de OUT_DIR: el entrypoint de Valhalla construye
# teselas con todos los *.pbf del directorio montado y con los dos juntos
# tardó 2 h 13 min y generó 1.8 GB (ver auditoría de P0, E4).
SOURCE="$SOURCE_DIR/source.osm.pbf"
CLIPPED="$OUT_DIR/utn.osm.pbf"

if [ ! -f "$SOURCE" ]; then
  echo "Descargando extracto: $OSM_SOURCE_URL"
  curl -fL --retry 3 --progress-bar -o "$SOURCE" "$OSM_SOURCE_URL"
fi

echo "Recortando a $ZONE_BBOX"
docker run --rm -v "$SOURCE_DIR:/data" stefda/osmium-tool:latest \
  osmium extract --bbox "$ZONE_BBOX" -o /data/valhalla/utn.osm.pbf /data/source.osm.pbf

echo "Listo: $CLIPPED"
echo "Levantar el motor con: docker compose -f infra/docker-compose.yml up -d valhalla"
