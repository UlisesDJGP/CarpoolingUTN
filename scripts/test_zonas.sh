#!/usr/bin/env bash
# Batería de zonas a evitar contra Valhalla en marcha (RF-23, RF-24, RF-25)
# más la verificación de cruce con Shapely y los límites del motor.
# Evidencia reproducible de P0.9 / H-EX1 (auditoria P0 parte 2).
# Requiere: curl, jq, python3, Valhalla en localhost:8002. Sale 0 si todo pasa.
set -uo pipefail

URL="${VALHALLA_URL:-http://localhost:8002/route}"
REQ=$(mktemp)
trap 'rm -f "$REQ"' EXIT
FAILS=0
TOTAL=0

BASE='{"locations":[{"lat":21.4247499,"lon":-104.8955129},{"lat":21.5041,"lon":-104.8946}],"costing":"auto"}'
# Punto medio de la traza base y cuadrado de ~700 m de lado (perimetro ~2.8 km)
MLAT=21.455388
MLON=-104.896110
SQ='[[[-104.899310,21.452188],[-104.892910,21.452188],[-104.892910,21.458588],[-104.899310,21.458588],[-104.899310,21.452188]]]'

route() { # $1 = JSON extra a mergear; imprime {t, km, err}
  jq -c --argjson e "$1" '. + $e' <<< "$BASE" > "$REQ"
  curl -s -X POST "$URL" -H 'Content-Type: application/json' -d @"$REQ" \
    | jq -c '{t: (.trip.summary.time // null), km: (.trip.summary.length // null), err: .error}'
}

check() { # $1 = etiqueta, $2 = expr true/false
  TOTAL=$((TOTAL + 1))
  if eval "$2"; then
    echo "PASS: $1"
  else
    echo "FAIL: $1"
    FAILS=$((FAILS + 1))
  fi
}

echo "== 0: base =="
T0=$(route '{}' | jq -r .t)
check "base con tiempo" '[ "$T0" != "null" ] && [ -n "$T0" ]'
echo "base: $T0 s"

echo "== 1: poligono sobre la traza (RF-23) =="
R1=$(route "{\"exclude_polygons\": $SQ}")
T1=$(echo "$R1" | jq -r .t)
check "el poligono desvia la ruta ($T1 > $T0)" '[ "$T1" != "null" ] && awk "BEGIN{exit !($T1 > $T0)}"'

echo "== 2: anillo en sentido horario =="
R2=$(route '{"exclude_polygons": [[[-104.899310,21.458588],[-104.892910,21.458588],[-104.892910,21.452188],[-104.899310,21.452188],[-104.899310,21.458588]]]}')
T2=$(echo "$R2" | jq -r .t)
check "sentido horario tambien desvia ($T2)" '[ "$T2" != "null" ] && awk "BEGIN{exit !($T2 > $T0)}"'

echo "== 3: anillo sin cerrar =="
R3=$(route '{"exclude_polygons": [[[-104.899310,21.452188],[-104.892910,21.452188],[-104.892910,21.458588],[-104.899310,21.458588]]]}')
T3=$(echo "$R3" | jq -r .t)
check "anillo sin cerrar desvia ($T3)" '[ "$T3" != "null" ] && awk "BEGIN{exit !($T3 > $T0)}"'

echo "== 4: ubicacion correcta del parametro =="
R4=$(jq -c --argjson p "$SQ" '. + {costing_options: {auto: {exclude_polygons: $p}}}' <<< "$BASE" \
  | curl -s -X POST "$URL" -H 'Content-Type: application/json' -d @- | jq -c '{t: (.trip.summary.time // null)}')
check "costing_options.auto no aplica (top-level si): t igual a base" '[ "$(echo "$R4" | jq -r .t)" = "$T0" ]'

echo "== 5: perimetro mayor a 10000 m (limite) =="
R5=$(route '{"exclude_polygons": [[[-105.16,21.30],[-104.59,21.30],[-104.59,21.86],[-105.16,21.86],[-105.16,21.30]]]}')
check "rechazo explicito del limite" '[ "$(echo "$R5" | jq -r .err)" = "Exceeded maximum circumference for exclude_polygons: 10000 meters" ]'

echo "== 6: origen encerrado, perimetro bajo el limite (RF-25) =="
R6=$(route '{"exclude_polygons": [[[-104.9065,21.4137],[-104.8845,21.4137],[-104.8845,21.4357],[-104.9065,21.4357],[-104.9065,21.4137]]]}')
check "sin ruta: No path could be found for input" '[ "$(echo "$R6" | jq -r .err)" = "No path could be found for input" ]'

echo "== 7: exclude_locations sobre la traza =="
R7=$(route "{\"exclude_locations\": [{\"lat\": $MLAT, \"lon\": $MLON}]}")
T7=$(echo "$R7" | jq -r .t)
check "el punto cambia la ruta ($T7 != $T0)" '[ "$T7" != "null" ] && [ "$T7" != "$T0" ]'

echo "== 8: cruce real con Shapely (RF-23) =="
venv=/tmp/opencode/shp
if ! "$venv/bin/python3" -c "import shapely" 2>/dev/null; then
  echo "creando venv de Shapely en $venv (una sola vez)"
  python3 -m venv "$venv"
  "$venv/bin/pip" -q install --disable-pip-version-check shapely
fi
"$venv/bin/python3" - <<PY
import json, urllib.request, sys
from shapely.geometry import Polygon, LineString

def route(extra):
    body = {"locations":[{"lat":21.4247499,"lon":-104.8955129},{"lat":21.5041,"lon":-104.8946}],"costing":"auto"}
    body.update(extra)
    req = urllib.request.Request("$URL", data=json.dumps(body).encode(), headers={"Content-Type":"application/json"})
    return json.load(urllib.request.urlopen(req))

def decode(s):
    coords, i, lat, lon = [], 0, 0, 0
    def dec(i):
        d = sh = 0
        while True:
            b = ord(s[i]) - 63; i += 1
            d |= (b & 0x1f) << sh; sh += 5
            if not b & 0x20: break
        return (d >> 1) ^ -(d & 1), i
    while i < len(s):
        v, i = dec(i); lat += v
        v, i = dec(i); lon += v
        coords.append((lon/1e6, lat/1e6))
    return coords

poly = Polygon($SQ[0])
base = route({})
excl = route({"exclude_polygons": $SQ})
lb = LineString(decode(base["trip"]["legs"][0]["shape"]))
le = LineString(decode(excl["trip"]["legs"][0]["shape"]))
lejos = LineString([(0.0, 0.0), (0.001, 0.001)])
ok = (lb.intersects(poly) and not le.intersects(poly)
      and not lejos.intersects(poly)
      and excl["trip"]["summary"]["time"] >= base["trip"]["summary"]["time"])
print("base cruza=%s, excluida cruza=%s, lejos cruza=%s, desvio=+%.3f s" % (
    lb.intersects(poly), le.intersects(poly), lejos.intersects(poly),
    excl["trip"]["summary"]["time"] - base["trip"]["summary"]["time"]))
sys.exit(0 if ok else 1)
PY
py_ok=$?
check "base cruza el cuadrado, excluida no, lejos no, desvio no negativo" '[ "$py_ok" -eq 0 ]'

echo "== 9: limites del motor se SUMAN entre poligonos =="
R9a=$(route "{\"exclude_polygons\": $(python3 -c "
import json
def sq(lat, lon, d):
    return [[[lon-d, lat-d],[lon+d, lat-d],[lon+d, lat+d],[lon-d, lat+d],[lon-d, lat-d]]]
print(json.dumps(sq(21.455388, -104.896110, 0.00675)))")}")
check "un cuadrado de ~6 km pasa (desvia)" '[ "$(echo "$R9a" | jq -r .err)" = "null" ]'
R9b=$(route "{\"exclude_polygons\": $(python3 -c "
import json
def sq(lat, lon, d):
    return [[[lon-d, lat-d],[lon+d, lat-d],[lon+d, lat+d],[lon-d, lat+d],[lon-d, lat-d]]]
print(json.dumps(sq(21.455388, -104.896110, 0.00675) + sq(21.435, -104.895, 0.00675)))")}")
check "dos de ~6 km (11.6 km juntos) rechazados: el limite suma" '[ "$(echo "$R9b" | jq -r .err)" = "Exceeded maximum circumference for exclude_polygons: 10000 meters" ]'
R9c=$(route "{\"exclude_polygons\": $(python3 -c "
import json, math
def circ(lat0, lon0, r, n):
    ring = [[lon0 + r*math.cos(2*math.pi*i/n), lat0 + r*math.sin(2*math.pi*i/n)] for i in range(n)]
    ring.append(ring[0])
    return [ring]
print(json.dumps(circ(21.455388, -104.896110, 0.003, 60) + circ(21.435, -104.895, 0.003, 60)))")}")
check "dos anillos de 60 vertices (120 juntos) rechazados: vertices suman" '[ "$(echo "$R9c" | jq -r .err)" = "Exceeded maximum number of vertices for exclude_polygons: 100" ]'
R9d=$(jq -c '. + {exclude_locations: [range(0;51) | {lat: 21.42 + (. * 0.001), lon: -104.90}]}' <<< "$BASE" \
  | curl -s -X POST "$URL" -H 'Content-Type: application/json' -d @- | jq -c '{err: .error}')
check "51 exclude_locations rechazados (limite 50)" '[ "$(echo "$R9d" | jq -r .err)" = "Exceeded max avoid locations: 50" ]'

echo "== 10: control negativo del verificador =="
# Una condicion falsa debe contar como fallo; si no, el resto de PASS no vale.
if ( FAILS=0; check "control" 'false' >/dev/null; [ "$FAILS" -eq 1 ] ); then
  echo "PASS: el verificador marca fallo en una condicion falsa"
  TOTAL=$((TOTAL + 1))
else
  echo "FAIL: el verificador no detecta una condicion falsa"
  FAILS=$((FAILS + 1))
fi

echo
if [ "$FAILS" -eq 0 ]; then
  echo "ZONAS OK: $TOTAL comprobaciones en verde"
else
  echo "ZONAS FAIL: $FAILS comprobaciones en rojo"
  exit 1
fi
