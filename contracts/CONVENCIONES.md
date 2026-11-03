# Convenciones del proyecto — UTN Carpooling

Estas convenciones aplican a los contratos, la base de datos, el servicio de ruteo y el cliente de mapa. Cualquier cambio requiere aprobación del coordinador y una nueva versión del contrato.

## Nombres

- SQL, JSON y variables de entorno: `snake_case`.
- Clases y modelos Python: `PascalCase`.
- Funciones y variables Python: `snake_case`.
- Archivos Python: `snake_case.py`.
- Ramas: `feat/db`, `feat/ruteo`, `feat/mapa`, `feat/qa`.
- Etiquetas de contrato: `contract-v1`, `contract-v2`.

## Tipos y formatos

- Claves primarias: `uuid` generado con `gen_random_uuid()`.
- Fechas y horas: `timestamptz`, siempre en UTC. La API usa ISO 8601 con zona, por ejemplo `2026-11-03T18:30:00Z`.
- Geometrías: `geography` con SRID 4326. Los GeoJSON usan orden `[longitud, latitud]`.
- Distancias: metros, número entero.
- Duraciones: segundos, número entero.
- Dinero: no aplica en esta etapa.
- Booleanos: `true` y `false` en JSON.

## Estados

- `rutas.estado`: `publicada`, `en_curso`, `finalizada`, `cancelada`.
- `solicitudes.estado`: `pendiente`, `aceptada`, `rechazada`, `cancelada_auto`, `cancelada_usuario`.
- `viajes.estado`: `en_curso`, `finalizado`, `cancelado`.

Los estados se validan con restricciones `CHECK` en la base. No se agregan estados nuevos sin actualizar el contrato.

## Errores

Formato único de error en la API:

```json
{
  "error": "SIN_CUPO",
  "mensaje": "La ruta no tiene asientos disponibles."
}
```

Códigos de negocio:

| Código | Situación | HTTP |
| --- | --- | --- |
| `SIN_CUPO` | La ruta no tiene asientos disponibles | 409 |
| `SOLICITUD_NO_PENDIENTE` | La solicitud ya fue procesada | 409 |
| `SOLICITUD_NO_ENCONTRADA` | No existe la solicitud | 404 |
| `RUTA_NO_ENCONTRADA` | No existe la ruta | 404 |
| `SIN_RUTA_ALTERNATIVA` | Las zonas a evitar cierran todas las salidas | 422 |
| `MOTOR_NO_DISPONIBLE` | Valhalla no responde | 502 |

Los errores de validación de Pydantic usan el formato estándar de FastAPI con HTTP 422.

## API

- Prefijo de versión: `/v1`.
- Content-Type: `application/json`.
- Operaciones idempotentes solo las de lectura.
- Los endpoints no calculan reglas de negocio que ya impone la base.
- La API no recibe contraseñas ni hashes en esta etapa.

## Base de datos

- Migraciones con Alembic. La carpeta `contracts/schema.sql` es referencia; la fuente ejecutable es `db/migrations`.
- Toda tabla tiene clave primaria.
- Toda clave foránea declara acción de borrado explícita.
- Las reglas de negocio se imponen con `CHECK`, `UNIQUE`, índices únicos parciales y bloqueos `FOR UPDATE`.
- Los hashes de contraseña llegan calculados desde el backend. No se calculan en SQL.
- Los datos sintéticos se marcan en el encabezado del archivo y usan prefijos `SINTETICO-` y `SYN-`.

## Geometría y privacidad

- `zona_aprox` es una clave de cuadrícula de 500 m, no una coordenada exacta.
- El prototipo guarda `punto_recogida` como `geography` para permitir el emparejamiento. El cifrado en la aplicación queda pendiente y documentado como desvío consciente.

## Entorno

- Variables en `infra/.env`; nunca se versiona.
- `infra/.env.example` documenta todas las variables.
- Puertos locales: PostgreSQL `5432`, Valhalla `8002`, FastAPI `8000`.
- Versión de Python: 3.12, fijada con `uv`.
- Versión de PostgreSQL: 17 con PostGIS 3.5.

## Cambios de contrato

1. Abrir una propuesta con el caso que falla.
2. Describir el cambio mínimo.
3. Indicar impacto en base de datos, ruteo y mapa.
4. El coordinador aprueba y sube la versión.
5. Los agentes se sincronizan antes de continuar.
