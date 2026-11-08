#!/usr/bin/env bash
# Batería de verificación de infraestructura para auditorías.
# Requiere el grupo docker activo y los servicios levantados.
set -uo pipefail
cd "$(dirname "$0")/.."
DC="docker compose -f infra/docker-compose.yml"
VH=$($DC ps -q valhalla 2>/dev/null || true)
if [ -z "$VH" ]; then echo "ERROR: el servicio valhalla no esta levantado"; exit 1; fi

echo "== compose ps =="
$DC ps --format 'table {{.Name}}\t{{.Status}}'

echo "== PostGIS =="
$DC exec -T db psql -U carpooling -d carpooling -tAc "SELECT version();" | cut -c1-60
$DC exec -T db psql -U carpooling -d carpooling -tAc "SELECT PostGIS_Version();"

echo "== Esquema desde cero =="
$DC exec -T db psql -U carpooling -d carpooling -c "DROP DATABASE IF EXISTS schema_check;" -c "CREATE DATABASE schema_check;"
$DC cp contracts/schema.sql db:/tmp/schema.sql
$DC exec -T db psql -U carpooling -d schema_check -q -v ON_ERROR_STOP=1 -f /tmp/schema.sql && echo "schema OK"
echo -n "tablas: "
$DC exec -T db psql -U carpooling -d schema_check -tAc "SELECT count(*) FROM pg_tables WHERE schemaname='public' AND tablename NOT LIKE 'spatial_ref%';"

echo "== Humo de funciones =="
$DC cp scripts/smoke.sql db:/tmp/smoke.sql
$DC exec -T db psql -U carpooling -d schema_check -v ON_ERROR_STOP=1 -f /tmp/smoke.sql
$DC exec -T db psql -U carpooling -d carpooling -c "DROP DATABASE schema_check;" >/dev/null

echo "== Valhalla /status =="
curl -fsS http://localhost:8002/status | jq -c '{version, acciones: (.available_actions|length)}'

echo "== Antiefluxo E4: el build uso un solo .pbf =="
last_parse=$(docker logs "$VH" 2>&1 | grep '^.*Parsing files:' | tail -1)
if [ -z "$last_parse" ]; then
  echo "sin linea Parsing files en este arranque: teselas reutilizadas, sin rebuild (ok)"
else
  echo "$last_parse"
  if echo "$last_parse" | grep -q 'source\.osm\.pbf'; then
    echo "ERROR E4: el build listo el .pbf fuente de 619 MB; teselas degradadas (2 h 13 min, 1.8 GB, exclude_polygons roto)."
    exit 1
  fi
  pbf_in_build=$(echo "$last_parse" | grep -o '\.pbf' | wc -l)
  if [ "$pbf_in_build" -ne 1 ]; then
    echo "ERROR E4: el build listo $pbf_in_build archivos .pbf; debe ser 1 (utn.osm.pbf)."
    exit 1
  fi
  echo "build con un solo .pbf OK"
fi

echo "== Tamano de teselas (refuerzo D4) =="
tar_mb=$(docker exec "$VH" du -m /custom_files/valhalla_tiles.tar 2>/dev/null | cut -f1)
if [ -n "$tar_mb" ]; then
  echo "valhalla_tiles.tar: ${tar_mb} MB"
  if [ "$tar_mb" -ge 100 ]; then
    echo "ERROR E4: teselas de ${tar_mb} MB; una construccion sana pesa ~8 MB (la anomalia E4 dio 1.8 GB)."
    exit 1
  fi
else
  echo "AVISO: no se pudo medir valhalla_tiles.tar; revisar el contenedor."
fi

echo "== Ruta base =="
curl -s -X POST http://localhost:8002/route -H 'Content-Type: application/json' -d '{"locations":[{"lat":21.4247499,"lon":-104.8955129},{"lat":21.5041,"lon":-104.8946}],"costing":"auto"}' | jq -c '{t: .trip.summary.time, km: .trip.summary.length}'

echo "== H-EX1: poligono efectivo / punto efectivo =="
curl -s -X POST http://localhost:8002/route -H 'Content-Type: application/json' -d '{"locations":[{"lat":21.4247499,"lon":-104.8955129},{"lat":21.5041,"lon":-104.8946}],"costing":"auto","exclude_polygons":[[[-104.90,21.45],[-104.89,21.45],[-104.89,21.46],[-104.90,21.46],[-104.90,21.45]]]}' | jq -c '{polygon_t: (.trip.summary.time // .error)}'
curl -s -X POST http://localhost:8002/route -H 'Content-Type: application/json' -d '{"locations":[{"lat":21.4247499,"lon":-104.8955129},{"lat":21.5041,"lon":-104.8946}],"costing":"auto","exclude_locations":[{"lat":21.455388,"lon":-104.896110}]}' | jq -c '{point_t: (.trip.summary.time // .error)}'
