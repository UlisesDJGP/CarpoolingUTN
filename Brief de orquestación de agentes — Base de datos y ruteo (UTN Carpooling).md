# Brief de orquestación de agentes — Base de datos y ruteo (UTN Carpooling)

*Documento para coordinar a los agentes de desarrollo · 30 de octubre de 2026*

## 1. Objetivo y reglas de juego

Construir en paralelo dos frentes que se encuentran en un contrato común:

- **Frente A, base de datos:** esquema, reglas de negocio, datos de prueba y consultas geoespaciales.
- **Frente B, ruteo y mapa:** motor de ruteo, emparejamiento por desvío, estimación de tiempo y capa de mapa.

Reglas que todos los agentes deben respetar:

1. **Contrato primero.** El esquema SQL y el contrato de la API de ruteo se definen antes de programar. Ningún agente cambia `/contracts` sin aprobación del coordinador (tú).
2. **Cada agente es dueño de sus carpetas** y no edita las de otro.
3. **Nada se da por terminado sin evidencia:** pruebas ejecutadas y salida pegada en el PR.
4. **No inventar datos ni métricas.** Todo dato sintético se marca como tal, y ninguna métrica de IA se reporta sin viajes reales detrás.
5. **El modelo de lenguaje no calcula rutas.** La ruta la calcula un motor de ruteo sobre el grafo de calles real.

## 2. Stack y herramientas

| Herramienta | Para qué | Por qué esta |
| --- | --- | --- |
| PostgreSQL + PostGIS | Base de datos y consultas geoespaciales | Estándar para ubicaciones, índices GiST y `ST_DWithin` |
| Alembic o dbmate | Migraciones versionadas | Esquema reproducible desde cero; Alembic si el backend es Python |
| pgTAP y pytest + testcontainers | Pruebas de BD | Prueban restricciones y concurrencia contra un Postgres real y desechable |
| Valhalla (Docker) + extracto de OpenStreetMap | Motor de ruteo | Acepta zonas a evitar (`exclude_polygons`) en cada petición y matrices de tiempos |
| osmium-tool | Recortar el mapa a la zona de operación | Un extracto pequeño arranca rápido y ocupa poco |
| FastAPI + Pydantic | Servicio de ruteo | Contrato tipado y documentación OpenAPI automática |
| Shapely | Verificar geometrías en pruebas | Comprobar que una ruta no cruza una zona vetada |
| MapLibre (cliente móvil) | Mostrar mapa, ruta y marcadores | Código abierto, sin atarse a un proveedor |
| k6 o Locust | Pruebas de carga | Medir tiempos de respuesta |
| Docker Compose | Entorno único para todos | Mismo Postgres y mismo Valhalla en todas las máquinas |
| GitHub Actions | Integración continua | Corre las pruebas rápidas en cada PR |
| Mermaid o dbdiagram | Diagrama E-R | Entregable del cronograma |
| ruff y mypy | Calidad de código Python | Revisión automática |

Como Valhalla y su extracto pesan, las pruebas de integración con el motor se etiquetan aparte: corren en local o de noche, no en cada PR.

## 3. Estructura del repositorio y reparto de agentes

```
/contracts   schema.sql (referencia), openapi.yaml  -> solo el coordinador
/db          migraciones, seeds, funciones SQL, pruebas   -> Agente DB
/routing     servicio FastAPI, algoritmo de emparejamiento -> Agente Ruteo
/map-client  capa de mapa para la app                       -> Agente Mapa
/infra       docker-compose.yml, scripts del extracto OSM   -> Agente Ruteo + coordinador
/tests-e2e   escenarios de punta a punta                    -> Agente QA
/docs        diccionario de datos, guía de ejecución        -> cada agente en lo suyo
```

| Agente | Responsabilidad | Depende de |
| --- | --- | --- |
| Coordinador (tú) | Contratos, merges, decisiones | Nadie |
| Agente DB | Frente A completo | Contrato de datos |
| Agente Ruteo | Motor, servicio, emparejamiento, estimación | Contrato de la API |
| Agente Mapa | Capa de mapa en la app | Contrato de la API y quién programe la app |
| Agente QA | Pruebas de integración y de punta a punta | A y B mergeados |

**Orden de trabajo.** (0) El coordinador deja `docker-compose.yml` con PostGIS y Valhalla, el `openapi.yaml` y las convenciones de nombres. (1) Los agentes DB y Ruteo trabajan en paralelo, cada uno en su rama o worktree; Ruteo usa datos de ejemplo fijos hasta que la BD esté lista. (2) Se integra BD con ruteo. (3) QA corre los escenarios completos.

## 4. Frente A — Base de datos

### Modelo de datos

| Tabla | Campos clave |
| --- | --- |
| `usuarios` | id (uuid), correo\_institucional (único, dominio validado), matricula, nombre, password\_hash, verificado\_en |
| `vehiculos` | id, usuario\_id, placas, modelo, color, capacidad (entre 1 y 6) |
| `rutas` | id, conductor\_id, vehiculo\_id, origen y destino (`geography Point`), geometria (`geography LineString`), hora\_salida, asientos\_totales, asientos\_disponibles, estado |
| `solicitudes` | id, ruta\_id, pasajero\_id, punto\_recogida, zona\_aprox, estado (pendiente, aceptada, rechazada, cancelada\_auto, cancelada\_usuario) |
| `viajes` | id, ruta\_id, iniciado\_en, finalizado\_en, estado |
| `calificaciones` | viaje\_id, evaluador\_id, evaluado\_id, puntuacion (1 a 5), comentario; único por viaje, evaluador y evaluado |
| `notificaciones` | id, usuario\_id, tipo, payload, leida\_en |
| `zonas_evitar` | id, reportado\_por, geometria, motivo, vigente\_hasta |
| `eta_registros` | viaje\_id, estimado\_s, real\_s, features (jsonb), creado\_en |

### Reglas de negocio que debe imponer la propia base

- Correo con dominio institucional (restricción `CHECK`) y único.
- `asientos_disponibles` entre 0 y `asientos_totales`.
- Una sola solicitud activa por pasajero y ruta.
- **Aceptar una solicitud es atómico.** Dos conductores o dos peticiones simultáneas no pueden tomar el último asiento:

```sql
-- aceptar_solicitud(p_solicitud uuid)
-- 1. SELECT ... FROM rutas WHERE id = <ruta de la solicitud> FOR UPDATE;
-- 2. si asientos_disponibles = 0 -> error 'SIN_CUPO'
-- 3. UPDATE solicitudes SET estado = 'aceptada';
--    UPDATE rutas SET asientos_disponibles = asientos_disponibles - 1;
-- 4. si asientos_disponibles queda en 0 -> las solicitudes pendientes
--    de esa ruta pasan a 'cancelada_auto' y se crean sus notificaciones
```

- Búsqueda de rutas cercanas con índice GiST:

```sql
SELECT r.id
FROM rutas r
WHERE r.estado = 'publicada'
  AND r.hora_salida BETWEEN :t1 AND :t2
  AND ST_DWithin(r.geometria, :punto::geography, 800);
```

### Seguridad y privacidad

- Las contraseñas se guardan con hash (argon2 o bcrypt) calculado por el backend, nunca por funciones SQL.
- El cifrado choca con los índices espaciales, así que se separan dos datos: `zona_aprox` (cuadrícula de unos 500 m, usada para buscar) y la ubicación exacta (cifrada en la aplicación con la llave en variables de entorno, visible solo cuando la solicitud está aceptada).

### Entregables del Frente A

1. Diagrama E-R (Mermaid o dbdiagram), exportado como imagen.
2. Migraciones versionadas que levantan la BD desde cero.
3. Funciones SQL (`aceptar_solicitud`, `buscar_rutas_cercanas`) y sus pruebas.
4. Script de datos de prueba en la zona de operación: usuarios, rutas y solicitudes de ejemplo, marcados como sintéticos.
5. `docs/db.md` con diccionario de datos y guía de ejecución.

### Cómo se prueba el Frente A

| Prueba | Qué comprueba | Criterio de éxito |
| --- | --- | --- |
| Migraciones de cero | `up` en una BD vacía, y `down` y `up` otra vez | Sin errores y esquema idéntico |
| Restricciones | Correo ajeno a la universidad, asientos negativos, calificación 6, solicitud duplicada | Todas rechazadas por la BD |
| Concurrencia | 20 aceptaciones en paralelo con 1 solo asiento | Exactamente 1 aceptada; las demás fallan o quedan en `cancelada_auto` |
| Cancelación automática | Ruta que se llena | Pendientes en `cancelada_auto` y notificación creada |
| Rendimiento | Búsqueda cercana con 10 000 rutas de prueba | `EXPLAIN ANALYZE` usa el índice GiST; p95 propuesto menor a 50 ms |

## 5. Frente B — Ruteo y mapa

### Componentes

| Componente | Qué hace |
| --- | --- |
| B1. Motor | Valhalla en Docker con el extracto OSM recortado a la zona de operación |
| B2. Servicio de ruteo | API FastAPI que habla con Valhalla y con la BD |
| B3. Estimación de tiempo | Tiempo base del motor, corregido por franja horaria; guarda estimado y real de cada viaje |
| B4. Cliente de mapa | MapLibre: ruta dibujada, marcadores, elegir recogida con un pin |

Para elegir puntos basta un pin en el mapa. Evita el geocodificador por ahora: el servicio público de Nominatim tiene límites de uso, y el prototipo no lo necesita.

### Contrato de la API

| Endpoint | Entrada | Salida |
| --- | --- | --- |
| `POST /v1/ruta/calcular` | origen, destino, salida\_en, evitar\_zonas | polilínea, distancia\_m, duracion\_s, zonas\_aplicadas |
| `POST /v1/ruta/emparejar` | ruta\_id, candidatos (solicitud\_id, punto), desvio\_max\_s | por candidato: desvio\_s, caminata\_m, aceptable |
| `POST /v1/ruta/paradas` | origen, destino, paradas | orden óptimo, polilínea, ETA por parada |
| `POST /v1/viajes/{id}/posicion` | lat, lon, marca de tiempo | 204 |
| `GET /v1/viajes/{id}/eta` | n/a | eta\_s, base\_s, factor |
| `GET /v1/salud` | n/a | estado del servicio y del motor |

### Algoritmo de emparejamiento

1. **Prefiltro en la BD:** candidatos a menos de 500 a 800 m de la ruta del conductor (`ST_DWithin`), para no llamar al motor por cada alumno.
2. **Desvío:** `desvio = t(origen → recogida → destino) − t(origen → destino)`, con tiempos del motor.
3. **Aceptación:** el desvío no excede el máximo (propuesto: 10 minutos o 15 % del trayecto) y hay asientos.
4. **Orden de paradas:** como el destino es siempre la universidad y hay pocos pasajeros por auto, se prueban todas las permutaciones y se elige la de menor tiempo total usando la matriz de tiempos del motor.

### Obstáculos

- Los usuarios reportan una zona a evitar (tabla `zonas_evitar`) con vigencia limitada, por ejemplo 2 horas.
- El servicio lee las zonas vigentes y las pasa al motor como `exclude_polygons`.
- Si no existe ruta alternativa, devuelve un error claro (422) en lugar de una ruta que atraviese la zona.
- No hay tráfico en vivo en esta etapa; es una limitación declarada del prototipo.

### Estimación de tiempo

El baseline es el tiempo del motor multiplicado por un factor por franja horaria. Cada viaje guarda estimado y real en `eta_registros`. Un modelo de ML (por ejemplo gradient boosting) solo se entrena cuando haya viajes reales suficientes, y se evalúa con MAE y MAPE frente al baseline. Con pocos viajes, lo correcto es reportar el baseline y la limitación.

### Entregables del Frente B

1. Motor levantado con un comando (`docker compose up`) y script que descarga y recorta el extracto.
2. Servicio FastAPI con el contrato anterior y su `openapi.yaml`.
3. Módulo de emparejamiento con pruebas.
4. Registro de estimado frente a real y reporte del baseline.
5. Capa de mapa con ruta, marcadores y selección de recogida.
6. `docs/ruteo.md` con la zona cubierta, parámetros y limitaciones.

### Cómo se prueba el Frente B

| Prueba | Qué comprueba | Criterio de éxito |
| --- | --- | --- |
| Unitarias del desvío | Cálculo de desvío con el motor simulado | Desvío nunca negativo; casos conocidos correctos |
| Orden de paradas | 2 a 4 paradas con matriz fija | Visita todas las paradas y su tiempo es el mínimo entre las permutaciones |
| Rutas de referencia | 10 pares de puntos de la zona, guardados como fixtures | Ruta existe y tiempo dentro de ±10 % del valor de referencia |
| Zona a evitar | Polígono sobre la vía principal de la ruta base | La nueva ruta no cruza el polígono (Shapely) y dura igual o más |
| Sin alternativa | Zonas que cierran todas las salidas | Error 422 con mensaje claro |
| Emparejamiento | Escenario con pasajeros conocidos dentro y fuera de la ruta | Aceptados y rechazados exactamente los esperados |
| Comparación manual | 5 rutas contra otra app de mapas | Se documenta la diferencia de tiempos |
| Carga | 20 candidatos por petición con k6 o Locust | p95 propuesto: calcular menos de 1 s, emparejar menos de 2 s |

## 6. Cómo asegurar que todo sirve

**Lista de aceptación de integración (Agente QA):**

- [ ] `docker compose up` deja BD y motor funcionando en una máquina limpia
- [ ] Migraciones y datos de prueba se aplican sin intervención manual
- [ ] Todas las pruebas rápidas pasan en CI
- [ ] Pruebas de integración del motor pasan en local
- [ ] Los tiempos de carga cumplen los umbrales propuestos
- [ ] Cada entregable tiene su documento en `/docs`

**Demo de punta a punta (guion de pruebas):**

1. Un conductor se registra con correo institucional y publica una ruta con 3 asientos.
2. Cuatro pasajeros piden lugar, uno de ellos fuera de la ruta.
3. El servicio devuelve los aceptables ordenados por desvío y rechaza al que está fuera.
4. El conductor acepta a tres: el cuarto lugar ya no existe y la solicitud pendiente se cancela sola con su notificación.
5. Se reporta una zona a evitar sobre la ruta y se recalcula: el trazo cambia y evita la zona.
6. Se registra la posición durante el viaje y, al terminar, se guarda estimado frente a real.

## 7. Prompts listos para los agentes

**Agente DB**

```
Eres el Agente DB del proyecto UTN Carpooling. Trabajas solo en /db y /docs/db.md.
Objetivo: PostgreSQL + PostGIS con el esquema de la sección 4 del brief.
Entregables: migraciones (Alembic o dbmate), funciones aceptar_solicitud y
buscar_rutas_cercanas, seeds sintéticos marcados como tales, diagrama E-R, diccionario de datos.
Reglas: no edites /contracts; las reglas de negocio las impone la BD (CHECK, UNIQUE, FOR UPDATE);
las contraseñas llegan ya con hash.
Pruebas obligatorias: migración de cero, restricciones, concurrencia (20 aceptaciones en paralelo,
1 asiento), cancelación automática, EXPLAIN ANALYZE con índice GiST.
No declares terminado sin pegar la salida de las pruebas en el PR.
```

**Agente Ruteo**

```
Eres el Agente Ruteo del proyecto UTN Carpooling. Trabajas en /routing e /infra.
Objetivo: servicio FastAPI sobre Valhalla (Docker) con el contrato de la sección 5.
Entregables: script del extracto OSM de la zona, docker-compose, endpoints del contrato,
emparejamiento por desvío, orden de paradas por permutaciones, zonas a evitar con exclude_polygons,
registro de estimado frente a real.
Reglas: no uses un LLM para calcular rutas; no inventes métricas; sin tráfico en vivo, y
docúmentalo; usa datos de ejemplo fijos hasta que la BD esté integrada.
Pruebas obligatorias: las de la sección 5. Pega la salida en el PR.
```

**Agente QA**

```
Eres el Agente QA del proyecto UTN Carpooling. Trabajas en /tests-e2e y en el CI.
Objetivo: verificar la integración BD + ruteo con el guion de la sección 6.
Entregables: escenarios automatizados, workflow de GitHub Actions, reporte de resultados
con los umbrales cumplidos o fallados, y lista de bugs encontrados.
Reglas: reporta fallos tal como ocurren; no ajustes umbrales para que pasen.
```

## 8. Decisiones pendientes

- **Lenguaje del backend de Jocelyn.** Con el contrato primero no bloquea, pero afecta cómo se consume el servicio de ruteo.
- **Quién programa la app móvil.** El cronograma no lo asigna, y el Agente Mapa depende de eso.
- **Zona de operación.** Define el tamaño del extracto y los datos de prueba.
- **Proveedor de teselas del mapa.** El servidor público de OpenStreetMap no está pensado para uso intensivo; hay que elegir un proveedor o alojar las teselas.
- **Umbrales.** Desvío máximo, radio de prefiltro y tiempos de carga están propuestos y se ajustan con las primeras pruebas.
