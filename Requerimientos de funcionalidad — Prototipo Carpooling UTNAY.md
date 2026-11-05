# Requerimientos de funcionalidad — Prototipo Carpooling UTNAY

*Borrador para aprobación del coordinador · 4 de noviembre de 2026 · Base: brief de orquestación (30 de octubre de 2026) y auditoría de Fase 0 (commit `8bf16a8`, etiqueta `g0`)*

## 1. Alcance del prototipo

El prototipo debe demostrar el flujo completo del brief: un conductor publica una ruta, los pasajeros piden lugar, el servicio empareja por desvío, el conductor acepta con control atómico de asientos, se reporta una zona a evitar y el viaje queda registrado con el tiempo estimado frente al real. Ese flujo es el guion de seis pasos de la sección 6 del brief, y es el criterio de «funcionalidad completa o casi completa» para el parcial.

**Fuera de alcance, por decisión del brief:** tráfico en vivo, geocodificador y modelo de ML entrenado (solo baseline, con su limitación declarada).

**Fuera de alcance, propuesto (el brief no los menciona):** pagos, chat entre usuarios y app móvil de producción.

## 2. Punto de partida

| Componente | Estado según la auditoría de Fase 0 |
| --- | --- |
| PostgreSQL 17.5 + PostGIS 3.5 | Operativo |
| Valhalla 3.9.1 con extracto de la zona | Operativo; ruta campus a centro de Tepic: 9.858 km, 1230 s |
| `/contracts` (schema.sql, openapi.yaml con 6 endpoints, CONVENCIONES.md) | Etiquetas `contract-v1`, `contract-v2`, `g0` |
| Funciones `aceptar_solicitud` y `buscar_rutas_cercanas` | Probadas solo en el caso feliz, con prueba de humo manual |
| Migraciones, seeds, pruebas automatizadas, servicio de ruteo, mapa | No existen todavía |

## 3. Actores

- **Conductor:** usuario verificado con un vehículo registrado.
- **Pasajero:** usuario verificado que solicita lugar en una ruta.
- **Servicio de ruteo:** FastAPI sobre Valhalla; calcula rutas, desvíos, orden de paradas y ETA.

El esquema no tiene columna de rol: un mismo usuario puede ser conductor en una ruta y pasajero en otra.

## 4. Requerimientos funcionales

Prioridad: **D** = Debe (necesario para el guion de demo), **S** = Debería, **P** = Podría. Fase: la del plan en que se implementa. Los umbrales marcados como propuestos vienen del brief y se ajustan con las primeras pruebas.

### 4.1 Cuentas

| ID | Requerimiento | Criterio de aceptación | Prior. | Fase |
| --- | --- | --- | --- | --- |
| RF-01 | Registro con correo institucional único | Un correo de otro dominio o duplicado lo rechaza la BD (CHECK y UNIQUE) | D | 1A |
| RF-02 | Contraseña guardada con hash argon2 o bcrypt calculado por el backend | Ninguna función SQL calcula ni recibe contraseñas en claro | D | 1A y 2 |
| RF-03 | Verificación de correo (`verificado_en`) | Solo usuarios verificados publican o solicitan. El mecanismo no está definido (ver sección 7); en el prototipo puede simularse | S | 2 |

### 4.2 Vehículos y rutas

| ID | Requerimiento | Criterio de aceptación | Prior. | Fase |
| --- | --- | --- | --- | --- |
| RF-04 | Registrar vehículo (placas, modelo, color, capacidad) | Capacidad fuera de 1 a 6 rechazada por la BD | D | 1A |
| RF-05 | Publicar ruta con origen, destino, hora de salida, vehículo y asientos | Se guarda con `geometria` calculada por el servicio, `estado = publicada` y `asientos_disponibles` entre 0 y `asientos_totales` | D | 1A y 2 |
| RF-06 | Calcular ruta base | `POST /v1/ruta/calcular` devuelve polilínea, `distancia_m`, `duracion_s` y `zonas_aplicadas`; en 10 pares de referencia el tiempo queda a ±10 % del valor fijo | D | 1B |
| RF-07 | Cancelar ruta propia | La ruta sale de las búsquedas y sus solicitudes pendientes se cancelan con notificación. Regla no definida en el brief | P | Por definir |

### 4.3 Búsqueda y solicitud

| ID | Requerimiento | Criterio de aceptación | Prior. | Fase |
| --- | --- | --- | --- | --- |
| RF-08 | Elegir el punto de recogida con un pin en el mapa | Sin geocodificador; el punto llega como latitud y longitud | D | 1C |
| RF-09 | Buscar rutas cercanas | Solo rutas `publicada`, dentro de la ventana horaria y a 800 m o menos del punto (radio propuesto). `EXPLAIN ANALYZE` usa el índice GiST; p95 menor a 50 ms con 10 000 rutas (propuesto) | D | 1A |
| RF-10 | Crear solicitud de lugar | Estado `pendiente`; una sola solicitud activa por pasajero y ruta, la segunda la rechaza la BD | D | 1A y 2 |
| RF-11 | Proteger la ubicación del pasajero | Se guarda `zona_aprox` (cuadrícula de unos 500 m) para buscar; la ubicación exacta se cifra en la aplicación y solo se ve con la solicitud aceptada | D | 1A y 2 |
| RF-12 | Cancelar solicitud propia | Estado `cancelada_usuario`. Si estaba aceptada, falta definir si se devuelve el asiento | S | Por definir |

### 4.4 Emparejamiento y aceptación

| ID | Requerimiento | Criterio de aceptación | Prior. | Fase |
| --- | --- | --- | --- | --- |
| RF-13 | Calcular el desvío de cada candidato | `desvio_s = t(origen → recogida → destino) − t(origen → destino)` con tiempos del motor; devuelve `desvio_s`, `caminata_m` y `aceptable`; nunca negativo | D | 1B |
| RF-14 | Decidir si el candidato es aceptable | `aceptable` solo si el desvío no excede el máximo (propuesto: 10 minutos o 15 % del trayecto) y hay asientos | D | 1B |
| RF-15 | Listar candidatos ordenados por desvío | El pasajero fuera de ruta se descarta con motivo; en el escenario conocido, aceptados y rechazados son exactamente los esperados | D | 1B y 2 |
| RF-16 | Aceptar una solicitud de forma atómica | `aceptar_solicitud` bloquea la ruta (`FOR UPDATE`), falla con `SIN_CUPO` si no hay lugar y descuenta el asiento. Con 20 aceptaciones en paralelo y 1 asiento, exactamente 1 queda aceptada | D | 1A |
| RF-17 | Cancelación automática al llenarse la ruta | Al llegar a 0 asientos, las pendientes pasan a `cancelada_auto` y se crea una notificación por cada una | D | 1A |
| RF-18 | Rechazar una solicitud | Estado `rechazada` con notificación al pasajero. El brief no define la función | S | 1A |
| RF-19 | Notificaciones en la app | Listar las propias y marcar `leida_en`; eventos: aceptada, rechazada, `cancelada_auto` | S | 1A y 2 |

### 4.5 Orden de paradas

| ID | Requerimiento | Criterio de aceptación | Prior. | Fase |
| --- | --- | --- | --- | --- |
| RF-20 | Calcular el orden óptimo de recogida | `POST /v1/ruta/paradas` prueba todas las permutaciones con la matriz de tiempos del motor y devuelve orden, polilínea y ETA por parada. Con matriz fija de 2 a 4 paradas, visita todas y su tiempo es el mínimo | D | 1B |
| RF-21 | Limitar el número de paradas | Rechaza peticiones por encima de la capacidad del vehículo. Con 6 paradas son 720 permutaciones, todavía manejable. Propuesta | S | 1B |

### 4.6 Obstáculos y zonas a evitar

| ID | Requerimiento | Criterio de aceptación | Prior. | Fase |
| --- | --- | --- | --- | --- |
| RF-22 | Reportar una zona a evitar | Se guarda en `zonas_evitar` con polígono, motivo y `vigente_hasta` (por ejemplo 2 horas). Puede reportar cualquier usuario verificado | D | 1A y 1C |
| RF-23 | Recalcular evitando las zonas vigentes | El servicio las pasa al motor como `exclude_polygons`; la nueva ruta no cruza el polígono (Shapely) y dura igual o más | D | 1B |
| RF-24 | Ignorar zonas vencidas | Una zona con `vigente_hasta` pasado no afecta ningún cálculo | D | 1B |
| RF-25 | Error claro cuando no hay alternativa | Si las zonas cierran todas las salidas, responde 422 con mensaje; nunca devuelve una ruta que cruce la zona | D | 1B |
| RF-26 | Declarar que no hay tráfico en vivo | La documentación y la app lo indican como limitación del prototipo | D | 1B y 1C |

### 4.7 Viaje y estimación de tiempo

| ID | Requerimiento | Criterio de aceptación | Prior. | Fase |
| --- | --- | --- | --- | --- |
| RF-27 | Iniciar y finalizar un viaje | `viajes` guarda `iniciado_en`, `finalizado_en` y estado | D | 1A y 3 |
| RF-28 | Registrar la posición durante el viaje | `POST /v1/viajes/{id}/posicion` con latitud, longitud y marca de tiempo responde 204. El esquema actual no tiene dónde guardarla (ver sección 7) | D | 3 |
| RF-29 | Consultar el ETA | `GET /v1/viajes/{id}/eta` devuelve `eta_s`, `base_s` y `factor` (tiempo del motor por factor de franja horaria) | D | 1B |
| RF-30 | Guardar estimado frente a real | Al finalizar se inserta en `eta_registros` el `estimado_s`, el `real_s` y `features` | D | 3 |
| RF-31 | Reportar el baseline | MAE y MAPE del baseline solo con viajes reales; con pocos viajes se reporta el baseline y la limitación. Ninguna métrica de ML sin viajes reales detrás | S | 3 |

### 4.8 Calificaciones

| ID | Requerimiento | Criterio de aceptación | Prior. | Fase |
| --- | --- | --- | --- | --- |
| RF-32 | Calificar después de un viaje | Puntuación de 1 a 5 y comentario, única por viaje, evaluador y evaluado; una calificación de 6 la rechaza la BD | S | 1A (BD) y 3 (flujo) |

### 4.9 Mapa

| ID | Requerimiento | Criterio de aceptación | Prior. | Fase |
| --- | --- | --- | --- | --- |
| RF-33 | Mostrar el mapa de la zona | MapLibre con teselas del proveedor elegido (D4) y atribución de OpenStreetMap visible | D | 1C |
| RF-34 | Dibujar ruta y marcadores | Polilínea de la ruta, origen, destino y puntos de recogida | D | 1C |
| RF-35 | Mostrar zonas a evitar y la ruta recalculada | El polígono es visible y el trazo cambia al recalcular | D | 1C |
| RF-36 | Reportar una zona desde el mapa | Pin con radio que genera el polígono (simplificación propuesta para el prototipo) | S | 1C |

### 4.10 Operación

| ID | Requerimiento | Criterio de aceptación | Prior. | Fase |
| --- | --- | --- | --- | --- |
| RF-37 | Salud del servicio | `GET /v1/salud` informa el estado del servicio y del motor | D | 1B |
| RF-38 | Entorno reproducible | `docker compose up` deja BD y motor funcionando; migraciones y seeds se aplican sin intervención manual | D | 1A y 2 |
| RF-39 | Datos sintéticos marcados | Todo seed se identifica como sintético. El mecanismo no está definido (ver sección 7) | D | 1A |

## 5. Requerimientos no funcionales

| ID | Requerimiento | Medida |
| --- | --- | --- |
| RNF-01 | Rendimiento (umbrales propuestos) | Calcular p95 menor a 1 s y emparejar p95 menor a 2 s con 20 candidatos (k6 o Locust); búsqueda cercana p95 menor a 50 ms con 10 000 rutas |
| RNF-02 | Integridad en la base | Las reglas las imponen CHECK, UNIQUE y `FOR UPDATE`, no la aplicación |
| RNF-03 | Seguridad | Hash fuera de SQL; llave de cifrado en variables de entorno; contraseña por defecto solo en local |
| RNF-04 | Licencia de datos | Atribución de OpenStreetMap en `README.md`, `docs/ruteo.md` y el mapa |
| RNF-05 | Reproducibilidad | Imágenes Docker con versión fija; tiempo del primer arranque documentado; `scripts/validar.sh` en el repositorio |
| RNF-06 | Honestidad de datos | El modelo de lenguaje no calcula rutas; datos sintéticos marcados; sin métricas sin viajes reales |
| RNF-07 | Evidencia | Ningún entregable se da por terminado sin la salida de sus pruebas en el PR; pruebas rápidas en cada PR y las del motor en local o de noche |
| RNF-08 | Calidad de código | ruff y mypy en CI en cuanto exista código Python |

## 6. Qué implementar ahora, por fase

La Fase 0 está cerrada. Según la auditoría, las fases 1A y 1B pueden arrancar en paralelo, y Ruteo trabaja con datos de ejemplo fijos hasta que la BD esté lista.

**Preparación previa a 1A (de la auditoría):** activar el grupo `docker` en la sesión, crear el remoto Git y abrir el primer PR para que corra el CI, añadir `scripts/validar.sh` y la atribución de OpenStreetMap, y definir la identidad Git real.

| Fase | Dueño | Requerimientos | Compuerta | Condición actual |
| --- | --- | --- | --- | --- |
| 1A | Agente DB | RF-01, 02, 04, 05 (BD), 09, 10 (BD), 11 (BD), 16, 17, 18, 19 (BD), 22 (BD), 27 (BD), 32 (BD), 38, 39 | G1A: migraciones, seeds y pruebas en verde | Entorno listo. Decidir antes Alembic o dbmate |
| 1B | Agente Ruteo | RF-06, 13, 14, 15, 20, 21, 23, 24, 25, 26, 29, 37 | G1B: seis endpoints con Valhalla real | Sin bloqueo. RF-28 y RF-30 esperan la decisión sobre posiciones |
| 1C | Agente Mapa | RF-08, 22 (mapa), 26, 33, 34, 35, 36 | G1C: la demo de mapa completa el flujo manual | Bloqueada por D4 (teselas) y por quién programa la app |
| 2 | Coordinador y QA | RF-03, 05, 10, 11, 15, 16, 17, 19 integrados; RF-38 | G2: guion hasta el paso 4 sin intervención | Requiere 1A y 1B |
| 3 | QA | RF-27, 28, 30, 31, 32 (flujo); escenarios de punta a punta; carga | G3: lista de aceptación completa | Requiere la Fase 2 |

## 7. Brechas del plan que hay que decidir

1. **API de aplicación sin especificar.** Los seis endpoints del contrato son de ruteo. Registrar, publicar ruta, solicitar, aceptar, rechazar, calificar y reportar zona necesitan un backend. El brief menciona el backend de Jocelyn, pero su contrato no existe; sin él, los pasos 1, 2 y 4 del guion no se pueden automatizar en la Fase 2.
2. **Dónde se guardan las posiciones (RF-28).** Las nueve tablas no incluyen una de posiciones. Opciones: tabla nueva (requiere `contract-v3` y aprobación del coordinador), último punto en memoria del servicio, o resumen en `eta_registros.features`.
3. **Verificación de correo (RF-03).** El esquema tiene `verificado_en`, pero no se define cómo se verifica.
4. **Marca de datos sintéticos (RF-39).** Columna nueva (contract-v3) o convención de correo.
5. **Reglas de negocio no definidas.** Si `asientos_totales` puede superar la capacidad del vehículo; si cancelar una solicitud aceptada devuelve el asiento (RF-12); qué estados tiene `rutas` además de `publicada`; si «10 minutos o 15 %» significa el menor o el mayor de los dos.
6. **Herramienta de migraciones.** El brief dice Alembic si el backend es Python y dbmate en otro caso; la auditoría asume Alembic aunque el lenguaje del backend sigue pendiente.
7. **Quién programa la app móvil y proveedor de teselas (D4).** Bloquean la Fase 1C.

## 8. Trazabilidad con el guion de demo

| Paso del guion | Requerimientos |
| --- | --- |
| 1. El conductor se registra y publica una ruta con 3 asientos | RF-01, 04, 05, 06 |
| 2. Cuatro pasajeros piden lugar, uno fuera de la ruta | RF-08, 09, 10, 11 |
| 3. El servicio devuelve los aceptables ordenados por desvío y rechaza al de fuera | RF-13, 14, 15 |
| 4. El conductor acepta a tres y la solicitud pendiente se cancela sola con su notificación | RF-16, 17, 19 |
| 5. Se reporta una zona a evitar y se recalcula | RF-22, 23, 25, 35 |
| 6. Se registra la posición y, al terminar, estimado frente a real | RF-27, 28, 29, 30 |

*Nota sobre el paso 4:* para que haya una solicitud pendiente que cancelar, el paso 3 debe ser solo un veredicto del servicio de emparejamiento (`aceptable: false`) y no cambiar el estado de la solicitud fuera de ruta. Es una interpretación del guion; conviene confirmarla.
