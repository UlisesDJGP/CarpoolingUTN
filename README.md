# UTN Carpooling

Prototipo de carpooling universitario con PostgreSQL + PostGIS y un servicio de ruteo sobre Valhalla. El brief de orquestación es la fuente de verdad del proyecto.

## Estado

Fase 0 cerrada: contratos, infraestructura base y convenciones. Base PostGIS y motor Valhalla funcionando. Zona de operación confirmada: Universidad Tecnológica de Nayarit, con los municipios de Xalisco y Tepic, Nayarit, México. P0 en curso; detalle en `PLAN_EJECUCION_FASES.md`.

## Requisitos

- Docker y Docker Compose.
- uv y Python 3.12 (uv instala Python).
- 16 GB de RAM recomendados para construir las teselas de Valhalla.
- Una conexión a internet para descargar el extracto de OpenStreetMap la primera vez.

## Arranque rápido

```bash
# 1. Dependencias del sistema (Arch/CachyOS)
sudo pacman -S --needed docker docker-compose uv
sudo systemctl enable --now docker
sudo usermod -aG docker "$USER"   # cerrar sesión y volver a entrar

# 2. Configuración
cp infra/.env.example infra/.env
# La zona ya está cargada: Xalisco y Tepic, Nayarit.
# Solo falta TILE_STYLE_URL para el mapa.

# 3. Extracto OSM recortado
infra/osm/extract.sh

# 4. Base y motor
docker compose -f infra/docker-compose.yml up -d

# 5. Verificación
docker compose -f infra/docker-compose.yml ps
curl -fsS http://localhost:8002/status
```

La primera vez, Valhalla construye las teselas al arrancar. Coste normal con el extracto actual: unos 20 segundos y 8.3 MB de `valhalla_tiles.tar` sobre un `utn.osm.pbf` de 2.7 MB. Anomalía corregida el 5 de noviembre: si el `source.osm.pbf` de 619 MB queda dentro de `infra/osm/valhalla/`, el entrypoint construye con todos los `.pbf` del directorio y tarda 2 h 13 min, genera 1.8 GB y deja `exclude_polygons` sin efecto. `infra/osm/extract.sh` guarda ya el `.pbf` fuente en `infra/osm/`, fuera del directorio montado. La imagen está fijada por digesto en `infra/docker-compose.yml` para que un `pull` no dispare una reconstrucción.

## Estructura

```text
contracts/   Contrato de datos y contrato de la API. Solo los modifica el coordinador.
db/          Migraciones, seeds, funciones SQL y pruebas.
routing/     Servicio FastAPI, emparejamiento, paradas y ETA.
map-client/  Cliente MapLibre.
infra/       docker-compose, variables y scripts del extracto OSM.
tests-e2e/   Escenarios de punta a punta.
docs/        Diccionario de datos, guía de ruteo y guía del mapa.
```

## Contratos

- `contracts/schema.sql`: DDL de referencia. La fuente ejecutable son las migraciones de `db/`.
- `contracts/openapi.yaml`: contrato del servicio de ruteo, versión 1.
- `contracts/CONVENCIONES.md`: nombres, tipos, estados, errores y proceso de cambio.

Después de la etiqueta `contract-v1`, ningún agente modifica `contracts/` sin aprobación del coordinador.

## Datos y atribución

Los datos de calles y el grafo de ruteo provienen de OpenStreetMap. © contribuidores de OpenStreetMap, licencia [ODbL](https://opendatacommons.org/licenses/odbl/1-0/).

- Fuente del extracto: descarga de Geofabrik (`infra/.env`, `OSM_SOURCE_URL`).
- Recorte y teselas: `infra/osm/extract.sh` con la herramienta `osmium` y el motor Valhalla.
- La atribución de OpenStreetMap también debe ser visible en el cliente de mapa (RF-33) y en `docs/ruteo.md` (Fase 1B).

## Reglas del proyecto

1. Las reglas de negocio se imponen en la base: `CHECK`, `UNIQUE`, índices parciales y `FOR UPDATE`.
2. El modelo de lenguaje no calcula rutas. La ruta la calcula Valhalla.
3. Todo dato sintético se marca como sintético.
4. Ninguna métrica se reporta sin evidencia ni viajes reales.
5. Cada PR incluye la salida de las pruebas ejecutadas.

## Documentación

- `PLAN_IMPLEMENTACION.md`: plan completo, fases, puertas y riesgos.
- `docs/db.md`: diccionario de datos (Fase 1A).
- `docs/ruteo.md`: zona cubierta, parámetros y limitaciones (Fase 1B).
- `docs/mapa.md`: cliente de mapa (Fase 1C).
