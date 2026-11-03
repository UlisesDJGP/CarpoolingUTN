-- ============================================================================
-- UTN Carpooling — esquema de referencia
-- Fuente ejecutable: db/migrations (Alembic)
-- Este archivo documenta el contrato de datos. No reemplaza a las migraciones.
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ----------------------------------------------------------------------------
-- usuarios
-- ----------------------------------------------------------------------------
CREATE TABLE usuarios (
    id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    correo_institucional text NOT NULL UNIQUE,
    matricula            text NOT NULL,
    nombre               text NOT NULL,
    password_hash        text NOT NULL,
    verificado_en        timestamptz,
    CONSTRAINT usuarios_correo_institucional_check
        CHECK (correo_institucional ~* '^[A-Za-z0-9._%+-]+@([A-Za-z0-9-]+\.)*utnay\.edu\.mx$')
);

-- ----------------------------------------------------------------------------
-- vehiculos
-- ----------------------------------------------------------------------------
CREATE TABLE vehiculos (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    usuario_id uuid NOT NULL REFERENCES usuarios (id) ON DELETE CASCADE,
    placas     text NOT NULL,
    modelo     text,
    color      text,
    capacidad  integer NOT NULL,
    CONSTRAINT vehiculos_capacidad_check CHECK (capacidad BETWEEN 1 AND 6)
);

-- ----------------------------------------------------------------------------
-- rutas
-- ----------------------------------------------------------------------------
CREATE TABLE rutas (
    id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    conductor_id         uuid NOT NULL REFERENCES usuarios (id) ON DELETE CASCADE,
    vehiculo_id          uuid NOT NULL REFERENCES vehiculos (id) ON DELETE RESTRICT,
    origen               geography(Point, 4326) NOT NULL,
    destino              geography(Point, 4326) NOT NULL,
    geometria            geography(LineString, 4326) NOT NULL,
    hora_salida          timestamptz NOT NULL,
    asientos_totales     integer NOT NULL,
    asientos_disponibles integer NOT NULL,
    estado               text NOT NULL DEFAULT 'publicada',
    CONSTRAINT rutas_estado_check
        CHECK (estado IN ('publicada', 'en_curso', 'finalizada', 'cancelada')),
    CONSTRAINT rutas_asientos_totales_check
        CHECK (asientos_totales BETWEEN 1 AND 6),
    CONSTRAINT rutas_asientos_disponibles_check
        CHECK (asientos_disponibles BETWEEN 0 AND asientos_totales)
);

CREATE INDEX rutas_geometria_gist ON rutas USING GIST (geometria);
CREATE INDEX rutas_estado_hora_idx ON rutas (estado, hora_salida);

-- ----------------------------------------------------------------------------
-- solicitudes
-- ----------------------------------------------------------------------------
CREATE TABLE solicitudes (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    ruta_id         uuid NOT NULL REFERENCES rutas (id) ON DELETE CASCADE,
    pasajero_id     uuid NOT NULL REFERENCES usuarios (id) ON DELETE CASCADE,
    punto_recogida  geography(Point, 4326) NOT NULL,
    zona_aprox      text NOT NULL,
    estado          text NOT NULL DEFAULT 'pendiente',
    CONSTRAINT solicitudes_estado_check
        CHECK (estado IN ('pendiente', 'aceptada', 'rechazada', 'cancelada_auto', 'cancelada_usuario'))
);

-- Una sola solicitud activa por pasajero y ruta.
CREATE UNIQUE INDEX solicitudes_activa_uq
    ON solicitudes (ruta_id, pasajero_id)
    WHERE estado IN ('pendiente', 'aceptada');

CREATE INDEX solicitudes_ruta_estado_idx ON solicitudes (ruta_id, estado);

-- ----------------------------------------------------------------------------
-- viajes
-- ----------------------------------------------------------------------------
CREATE TABLE viajes (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    ruta_id      uuid NOT NULL REFERENCES rutas (id) ON DELETE CASCADE,
    iniciado_en  timestamptz,
    finalizado_en timestamptz,
    estado       text NOT NULL DEFAULT 'en_curso',
    CONSTRAINT viajes_estado_check
        CHECK (estado IN ('en_curso', 'finalizado', 'cancelado')),
    CONSTRAINT viajes_fechas_check
        CHECK (finalizado_en IS NULL OR iniciado_en IS NULL OR finalizado_en >= iniciado_en)
);

-- ----------------------------------------------------------------------------
-- calificaciones
-- ----------------------------------------------------------------------------
CREATE TABLE calificaciones (
    viaje_id     uuid NOT NULL REFERENCES viajes (id) ON DELETE CASCADE,
    evaluador_id uuid NOT NULL REFERENCES usuarios (id) ON DELETE CASCADE,
    evaluado_id  uuid NOT NULL REFERENCES usuarios (id) ON DELETE CASCADE,
    puntuacion   integer NOT NULL,
    comentario   text,
    PRIMARY KEY (viaje_id, evaluador_id, evaluado_id),
    CONSTRAINT calificaciones_puntuacion_check CHECK (puntuacion BETWEEN 1 AND 5),
    CONSTRAINT calificaciones_partes_check CHECK (evaluador_id <> evaluado_id)
);

-- ----------------------------------------------------------------------------
-- notificaciones
-- ----------------------------------------------------------------------------
CREATE TABLE notificaciones (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    usuario_id uuid NOT NULL REFERENCES usuarios (id) ON DELETE CASCADE,
    tipo       text NOT NULL,
    payload    jsonb NOT NULL DEFAULT '{}'::jsonb,
    leida_en   timestamptz
);

CREATE INDEX notificaciones_usuario_idx ON notificaciones (usuario_id, leida_en);

-- ----------------------------------------------------------------------------
-- zonas_evitar
-- ----------------------------------------------------------------------------
CREATE TABLE zonas_evitar (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    reportado_por uuid NOT NULL REFERENCES usuarios (id) ON DELETE CASCADE,
    geometria     geography(Polygon, 4326) NOT NULL,
    motivo        text NOT NULL,
    vigente_hasta timestamptz NOT NULL
);

CREATE INDEX zonas_evitar_geometria_gist ON zonas_evitar USING GIST (geometria);
CREATE INDEX zonas_evitar_vigencia_idx ON zonas_evitar (vigente_hasta);

-- ----------------------------------------------------------------------------
-- eta_registros
-- ----------------------------------------------------------------------------
CREATE TABLE eta_registros (
    viaje_id   uuid PRIMARY KEY REFERENCES viajes (id) ON DELETE CASCADE,
    estimado_s integer NOT NULL,
    real_s     integer,
    features   jsonb NOT NULL DEFAULT '{}'::jsonb,
    creado_en  timestamptz NOT NULL DEFAULT now()
);

-- ============================================================================
-- Funciones de negocio
-- ============================================================================

-- Acepta una solicitud de forma atómica.
-- Errores: SOLICITUD_NO_ENCONTRADA, SOLICITUD_NO_PENDIENTE, RUTA_NO_ENCONTRADA, SIN_CUPO.
CREATE OR REPLACE FUNCTION aceptar_solicitud(p_solicitud uuid)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
    v_solicitud     solicitudes%ROWTYPE;
    v_ruta          rutas%ROWTYPE;
    v_notificaciones integer := 0;
BEGIN
    -- El bloqueo de la solicitud impide aceptar dos veces la misma solicitud.
    SELECT * INTO v_solicitud
    FROM solicitudes
    WHERE id = p_solicitud
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'SOLICITUD_NO_ENCONTRADA' USING ERRCODE = 'P0001';
    END IF;

    IF v_solicitud.estado <> 'pendiente' THEN
        RAISE EXCEPTION 'SOLICITUD_NO_PENDIENTE' USING ERRCODE = 'P0001';
    END IF;

    -- El bloqueo de la ruta serializa la competencia por el último asiento.
    SELECT * INTO v_ruta
    FROM rutas
    WHERE id = v_solicitud.ruta_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'RUTA_NO_ENCONTRADA' USING ERRCODE = 'P0001';
    END IF;

    IF v_ruta.asientos_disponibles <= 0 THEN
        RAISE EXCEPTION 'SIN_CUPO' USING ERRCODE = 'P0001';
    END IF;

    UPDATE solicitudes
    SET estado = 'aceptada'
    WHERE id = p_solicitud;

    UPDATE rutas
    SET asientos_disponibles = asientos_disponibles - 1
    WHERE id = v_ruta.id
    RETURNING * INTO v_ruta;

    IF v_ruta.asientos_disponibles = 0 THEN
        WITH canceladas AS (
            UPDATE solicitudes
            SET estado = 'cancelada_auto'
            WHERE ruta_id = v_ruta.id
              AND estado = 'pendiente'
            RETURNING id, pasajero_id
        ), creadas AS (
            INSERT INTO notificaciones (usuario_id, tipo, payload)
            SELECT
                c.pasajero_id,
                'solicitud_cancelada_auto',
                jsonb_build_object(
                    'solicitud_id', c.id,
                    'ruta_id', v_ruta.id,
                    'motivo', 'SIN_CUPO'
                )
            FROM canceladas c
            RETURNING 1
        )
        SELECT count(*) INTO v_notificaciones FROM creadas;
    END IF;

    RETURN jsonb_build_object(
        'solicitud_id', p_solicitud,
        'ruta_id', v_ruta.id,
        'asientos_disponibles', v_ruta.asientos_disponibles,
        'notificaciones_creadas', v_notificaciones
    );
END;
$$;

-- Rutas publicadas que pasan a menos de p_radio_m del punto, dentro de la ventana horaria.
CREATE OR REPLACE FUNCTION buscar_rutas_cercanas(
    p_punto   geography,
    p_desde   timestamptz,
    p_hasta   timestamptz,
    p_radio_m integer DEFAULT 800
)
RETURNS SETOF uuid
LANGUAGE sql
STABLE
AS $$
    SELECT r.id
    FROM rutas r
    WHERE r.estado = 'publicada'
      AND r.hora_salida BETWEEN p_desde AND p_hasta
      AND ST_DWithin(r.geometria, p_punto, p_radio_m)
    ORDER BY r.hora_salida;
$$;

-- Desvío consciente: el prototipo guarda la ubicación exacta como geography para
-- permitir índices GiST y ST_DWithin. El cifrado en la aplicación queda pendiente.
-- shortcut: ubicación exacta sin cifrar, revisar antes de producción.
