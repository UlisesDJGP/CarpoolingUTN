# UTN Carpooling

Prototipo de carpooling universitario con PostgreSQL + PostGIS y un servicio de ruteo sobre Valhalla. El brief de orquestación es la fuente de verdad del proyecto.

## Estado

Fase 0 completa: contratos, infraestructura base y convenciones. Zona de operación confirmada: Universidad Tecnológica de Nayarit, con los municipios de Xalisco y Tepic, Nayarit, México.

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

La primera vez, Valhalla construye las teselas al arrancar. Puede tardar varios minutos según el tamaño del extracto.

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
