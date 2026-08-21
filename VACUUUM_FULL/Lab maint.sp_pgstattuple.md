# Laboratorio 

### 🧪 Preparación del Entorno

Ejecuta esto una sola vez para preparar la zona de aterrizaje de las pruebas:

```sql
CREATE SCHEMA IF NOT EXISTS lab;

```

---

### 🎯 Laboratorio 1: Probar `p_free_pct_threshold` (% de Espacio Libre Interno)

*Simularemos una tabla de historial de pagos donde se hace un purgado masivo de registros antiguos, dejando la tabla llena de "aire" en sus páginas de memoria.*

```sql
-- 1. Crear tabla realista en esquema lab
-- =========================================================================
-- LABORATORIO 1: PROBAR p_free_pct_threshold EN ESQUEMA LAB (SIN AUTOVACUUM)
-- =========================================================================

-- 1. Preparar esquema y recrear tabla
CREATE SCHEMA IF NOT EXISTS lab;
DROP TABLE IF EXISTS lab.historial_pagos;

CREATE TABLE lab.historial_pagos (
    id SERIAL PRIMARY KEY,
    payload_transaccion TEXT
);

-- Desactivar Autovacuum para que el motor no limpie de forma autogestionada
ALTER TABLE lab.historial_pagos SET (autovacuum_enabled = false);

-- 2. Carga inicial de datos (50,000 registros ~25 MB)
INSERT INTO lab.historial_pagos (payload_transaccion) 
SELECT repeat('A', 500) FROM generate_series(1, 50000);

-- -------------------------------------------------------------------------
-- INSPECCIÓN 1: ESTADO INICIAL (Tabla limpia sin tuplas muertas)
-- -------------------------------------------------------------------------
SELECT 'ESTADO INICIAL' AS etapa, schemaname, relname, n_live_tup, n_dead_tup, n_mod_since_analyze
FROM pg_stat_user_tables WHERE relname = 'historial_pagos';

SELECT * FROM pgstattuple_approx('lab.historial_pagos'::regclass);


-- 3. Generar fragmentación y espacio libre interno (UPDATE masivo del 80% de las filas)
UPDATE lab.historial_pagos SET payload_transaccion = 'X' WHERE id > 10000;


-- -------------------------------------------------------------------------
-- INSPECCIÓN 2: ESTADO POST-DEGRADACIÓN (Tuplas muertas y basura generada)
-- -------------------------------------------------------------------------
SELECT 'POST-DEGRADACIÓN' AS etapa, schemaname, relname, n_live_tup, n_dead_tup, n_mod_since_analyze
FROM pg_stat_user_tables WHERE relname = 'historial_pagos';

SELECT * FROM pgstattuple_approx('lab.historial_pagos'::regclass);

vacuum lab.historial_pagos;

SELECT * FROM pgstattuple_approx('lab.historial_pagos'::regclass);

-- 4. Ejecutar el radar de Triage (Fase 1) evaluando únicamente p_free_pct_threshold
CALL maint.sp_pgstattuple(
    p_scope                => 'ALL_USER', 
    p_bloat_pct_threshold => 50.00,      -- 25% de Bloat Total (Aire + Muertos)
    p_bloat_mb_threshold  => 20.00,      -- 50 MB de basura absoluta
    p_threshold_operator  => 'AND',       --  Operador para  p_bloat_pct_threshold , p_bloat_mb_threshold: 'OR' (cumplir cualquiera) o 'AND' (cumplir ambas) siempre con mayor o igual.
    p_min_table_mb        => 0.00,       -- Evalúa el 100% de las tablas (sin filtro de tamaño)
    p_enable_deep_scan    => TRUE,      -- Fase 2 (Deep Scan) APAGADA, PARA poder ser escaneada debe ser true y cumplir con la condicion de p_bloat_pct_threshold y p_bloat_mb_threshold
    p_verbose             => TRUE        -- Reporte activo en consola
);


-- 5. Validar el resultado final estampado en la telemetría
select * from maint.pgstattuple    where table_name = 'historial_pagos'  /* and requiere_vf = true   order by approx_free_percent desc limit 100*/ ;


truncate table maint.pgstattuple restart identity ;

```

---

### 🎯 Laboratorio 2: Probar `p_free_mb_threshold` (Megabytes Absolutos Libres)

*Simularemos una tabla de auditoría masiva. A veces el porcentaje de aire es bajo, pero el volumen en Gigabytes o Megabytes justifica recuperar ese disco.*

```sql
-- 1. Limpiar y recrear tabla
DROP TABLE IF EXISTS lab.logs_auditoria;
CREATE TABLE lab.logs_auditoria (id SERIAL PRIMARY KEY, detalle_evento TEXT);

-- 2. Insertar 100,000 registros pesados (~50 MB)
INSERT INTO lab.logs_auditoria (detalle_evento) 
SELECT repeat('B', 500) FROM generate_series(1, 100000);

-- 3. Borrar el 80% y aplicar VACUUM normal para liberar ~40 MB físicos
DELETE FROM lab.logs_auditoria WHERE id > 20000;
VACUUM lab.logs_auditoria;

-- 4. Ejecutar activando ÚNICAMENTE el umbral de Megabytes absolutos
CALL maint.sp_pgstattuple(
    p_scope              => 'ALL_USER',
    p_free_pct_threshold => 99.00,    -- Desactivado
    p_free_mb_threshold  => 10.00,    -- <--- UMBRAL A PRUEBA (Exige al menos 10 MB libres en disco)
    p_dead_pct_threshold => 99.00,    -- Desactivado
    p_min_table_mb       => 0.00,
    p_enable_deep_scan   => FALSE,
    p_verbose            => TRUE
);

-- 5. Validar resultado (El semáforo debe estar en TRUE)
SELECT schema_name, table_name, (approx_table_len / 1024 / 1024) AS tamanio_mb, approx_free_percent, requiere_vf 
FROM maint.pgstattuple 
WHERE schema_name = 'lab' AND table_name = 'logs_auditoria';

```

---

### 🎯 Laboratorio 3: Probar `p_dead_pct_threshold` (% de Tuplas Muertas)

*Simularemos una tabla de control de sesiones activas. Esta tabla sufre constantes `UPDATE`s que generan tuplas muertas masivas antes de que el Autovacuum tenga tiempo de reaccionar.*

```sql
-- 1. Limpiar y recrear tabla
DROP TABLE IF EXISTS lab.sesiones_activas;
CREATE TABLE lab.sesiones_activas (id SERIAL PRIMARY KEY, token_acceso TEXT);

-- 2. Insertar 50,000 registros
INSERT INTO lab.sesiones_activas (token_acceso) 
SELECT repeat('C', 500) FROM generate_series(1, 50000);

-- 3. Generar tuplas muertas SIN correr VACUUM (Actualización masiva)
-- Un UPDATE en PostgreSQL crea una nueva fila y marca la anterior como muerta.
UPDATE lab.sesiones_activas SET token_acceso = repeat('Z', 500);
ANALYZE lab.sesiones_activas;

-- 4. Ejecutar activando ÚNICAMENTE el umbral de porcentaje de tuplas muertas
CALL maint.sp_pgstattuple(
    p_scope              => 'ALL_USER',
    p_free_pct_threshold => 99.00,    -- Desactivado
    p_free_mb_threshold  => 99999.00, -- Desactivado
    p_dead_pct_threshold => 20.00,    -- <--- UMBRAL A PRUEBA (Exige 20% de tuplas muertas)
    p_min_table_mb       => 0.00,
    p_enable_deep_scan   => FALSE,
    p_verbose            => TRUE
);

-- 5. Validar resultado (El semáforo debe estar en TRUE)
SELECT schema_name, table_name, approx_dead_tuple_percent, requiere_vf 
FROM maint.pgstattuple 
WHERE schema_name = 'lab' AND table_name = 'sesiones_activas';

```

 
