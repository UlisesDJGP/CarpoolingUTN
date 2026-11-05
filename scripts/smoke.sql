\set ON_ERROR_STOP on

INSERT INTO usuarios (id, correo_institucional, matricula, nombre, password_hash) VALUES
  ('00000000-0000-0000-0000-000000000001', 'conductor@utnay.edu.mx', 'SYN-1', 'SINTETICO Conductor', 'hash'),
  ('00000000-0000-0000-0000-000000000002', 'pasajero1@utnay.edu.mx', 'SYN-2', 'SINTETICO Pasajero 1', 'hash'),
  ('00000000-0000-0000-0000-000000000003', 'pasajero2@utnay.edu.mx', 'SYN-3', 'SINTETICO Pasajero 2', 'hash');

INSERT INTO vehiculos (id, usuario_id, placas, modelo, color, capacidad) VALUES
  ('00000000-0000-0000-0000-000000000010', '00000000-0000-0000-0000-000000000001', 'SYN-AAA', 'SINTETICO', 'gris', 3);

INSERT INTO rutas (id, conductor_id, vehiculo_id, origen, destino, geometria, hora_salida, asientos_totales, asientos_disponibles) VALUES
  (
    '00000000-0000-0000-0000-000000000100',
    '00000000-0000-0000-0000-000000000001',
    '00000000-0000-0000-0000-000000000010',
    ST_SetSRID(ST_MakePoint(-104.8955129, 21.4247499), 4326)::geography,
    ST_SetSRID(ST_MakePoint(-104.895, 21.503), 4326)::geography,
    ST_SetSRID(ST_MakeLine(ST_MakePoint(-104.8955129, 21.4247499), ST_MakePoint(-104.895, 21.503)), 4326)::geography,
    now() + interval '1 hour',
    2,
    1
  );

INSERT INTO solicitudes (id, ruta_id, pasajero_id, punto_recogida, zona_aprox) VALUES
  (
    '00000000-0000-0000-0000-000000000201',
    '00000000-0000-0000-0000-000000000100',
    '00000000-0000-0000-0000-000000000002',
    ST_SetSRID(ST_MakePoint(-104.8954, 21.43), 4326)::geography,
    '21.43_-104.89_500'
  ),
  (
    '00000000-0000-0000-0000-000000000202',
    '00000000-0000-0000-0000-000000000100',
    '00000000-0000-0000-0000-000000000003',
    ST_SetSRID(ST_MakePoint(-104.8953, 21.44), 4326)::geography,
    '21.44_-104.89_500'
  );

SELECT aceptar_solicitud('00000000-0000-0000-0000-000000000201') AS aceptada;

SELECT r.asientos_disponibles,
       (SELECT estado FROM solicitudes WHERE id = '00000000-0000-0000-0000-000000000201') AS s1,
       (SELECT estado FROM solicitudes WHERE id = '00000000-0000-0000-0000-000000000202') AS s2,
       (SELECT count(*) FROM notificaciones) AS notificaciones
FROM rutas r
WHERE r.id = '00000000-0000-0000-0000-000000000100';

SELECT count(*) AS rutas_cercanas
FROM buscar_rutas_cercanas(
  ST_SetSRID(ST_MakePoint(-104.8955129, 21.4247499), 4326)::geography,
  now(),
  now() + interval '2 hours',
  800
);
