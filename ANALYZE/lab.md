
# 🧪 LABORATORIO VANGUARD: POLÍGONO DE TIRO SQL

Ejecuta este script completo en tu entorno de desarrollo/pruebas.

```sql
-- ============================================================================
-- DBA SQUAD: VANGUARD BLACK-OPS - LABORATORIO DE CAOS SINTÉTICO
-- ============================================================================


BEGIN;
CREATE SCHEMA IF NOT EXISTS lab;

-- ----------------------------------------------------------------------------
-- FASE 1: CREACIÓN DE ESTRUCTURAS (10 Tablas)
-- ----------------------------------------------------------------------------
DROP TABLE IF EXISTS lab.clientes, lab.productos, lab.pedidos, 
                     lab.detalle_pedidos, lab.pagos, lab.envios, 
                     lab.inventario, lab.carritos, lab.sesiones, 
                     lab.logs_auditoria CASCADE;

CREATE TABLE lab.clientes (id SERIAL PRIMARY KEY, nombre TEXT, estatus TEXT);
CREATE TABLE lab.productos (id SERIAL PRIMARY KEY, sku TEXT, precio NUMERIC);
CREATE TABLE lab.pedidos (id SERIAL PRIMARY KEY, cliente_id INT, total NUMERIC, estado TEXT);
CREATE TABLE lab.detalle_pedidos (id SERIAL PRIMARY KEY, pedido_id INT, cantidad INT);
CREATE TABLE lab.pagos (id SERIAL PRIMARY KEY, pedido_id INT, monto NUMERIC, metodo TEXT);
CREATE TABLE lab.envios (id SERIAL PRIMARY KEY, pedido_id INT, guia TEXT, estado TEXT);
CREATE TABLE lab.inventario (id SERIAL PRIMARY KEY, producto_id INT, stock INT);
CREATE TABLE lab.carritos (id SERIAL PRIMARY KEY, cliente_id INT, fecha_creacion TIMESTAMP);
CREATE TABLE lab.sesiones (id SERIAL PRIMARY KEY, token TEXT, ultima_actividad TIMESTAMP);
CREATE TABLE lab.logs_auditoria (id SERIAL PRIMARY KEY, evento TEXT, fecha TIMESTAMP);

-- Deshabilitamos el autovacuum para que no nos gane hacer el analyze, esto solo es para este laboratorio en produccion no se recomienda desactivar
ALTER TABLE lab.clientes SET (autovacuum_enabled = false);
ALTER TABLE lab.productos SET (autovacuum_enabled = false);
ALTER TABLE lab.pedidos SET (autovacuum_enabled = false);
ALTER TABLE lab.detalle_pedidos SET (autovacuum_enabled = false);
ALTER TABLE lab.pagos SET (autovacuum_enabled = false);
ALTER TABLE lab.envios SET (autovacuum_enabled = false);
ALTER TABLE lab.inventario SET (autovacuum_enabled = false);
ALTER TABLE lab.carritos SET (autovacuum_enabled = false);
ALTER TABLE lab.sesiones SET (autovacuum_enabled = false);
ALTER TABLE lab.logs_auditoria SET (autovacuum_enabled = false);

-- ----------------------------------------------------------------------------
-- FASE 2: INYECCIÓN DE VOLUMEN (20,000 filas por tabla para superar filtro de 10k)
-- ----------------------------------------------------------------------------
INSERT INTO lab.clientes (nombre, estatus) SELECT 'Cliente ' || i, 'ACTIVO' FROM generate_series(1, 20000) i;
INSERT INTO lab.productos (sku, precio) SELECT 'SKU-' || i, RANDOM() * 1000 FROM generate_series(1, 20000) i;
INSERT INTO lab.pedidos (cliente_id, total, estado) SELECT i, RANDOM() * 500, 'NUEVO' FROM generate_series(1, 20000) i;
INSERT INTO lab.detalle_pedidos (pedido_id, cantidad) SELECT i, 1 FROM generate_series(1, 20000) i;
INSERT INTO lab.pagos (pedido_id, monto, metodo) SELECT i, 100, 'TARJETA' FROM generate_series(1, 20000) i;
INSERT INTO lab.envios (pedido_id, guia, estado) SELECT i, 'GUIA-'||i, 'PREPARANDO' FROM generate_series(1, 20000) i;
INSERT INTO lab.inventario (producto_id, stock) SELECT i, 100 FROM generate_series(1, 20000) i;
INSERT INTO lab.carritos (cliente_id, fecha_creacion) SELECT i, NOW() FROM generate_series(1, 20000) i;
INSERT INTO lab.sesiones (token, ultima_actividad) SELECT md5(i::text), NOW() FROM generate_series(1, 20000) i;
INSERT INTO lab.logs_auditoria (evento, fecha) SELECT 'LOGIN', NOW() FROM generate_series(1, 20000) i;

COMMIT;

-- ----------------------------------------------------------------------------
-- FASE 3: ESTABILIZACIÓN DEL MOTOR (Punto Cero)
-- Hacemos un ANALYZE masivo para que el motor ponga n_mod_since_analyze en 0.
-- ----------------------------------------------------------------------------
ANALYZE lab.clientes;
ANALYZE lab.productos;
ANALYZE lab.pedidos;
ANALYZE lab.detalle_pedidos;
ANALYZE lab.pagos;
ANALYZE lab.envios;
ANALYZE lab.inventario;
ANALYZE lab.carritos;
ANALYZE lab.sesiones;
ANALYZE lab.logs_auditoria;

-- ----------------------------------------------------------------------------
-- FASE 4: SIMULACIÓN DE CAOS TRANSACCIONAL (El paso del tiempo)
-- ----------------------------------------------------------------------------
BEGIN;

-- 1. lab_sesiones (90% de cambio) -> ALTA PRIORIDAD. Expira sesiones viejas.
UPDATE lab.sesiones SET ultima_actividad = NOW() WHERE id <= 18000;

-- 2. lab_carritos (50% de cambio) -> ALTA PRIORIDAD. Borrado masivo de carritos abandonados.
DELETE FROM lab.carritos WHERE id <= 10000;

-- 3. lab_pedidos (15% de cambio) -> MEDIA PRIORIDAD. Pedidos que pasaron a ENVIADO.
UPDATE lab.pedidos SET estado = 'ENVIADO' WHERE id <= 3000;

-- 4. lab_logs_auditoria (10% de cambio) -> MEDIA PRIORIDAD. Inserción de nuevos logs.
INSERT INTO lab.logs_auditoria (evento, fecha) SELECT 'CLICK', NOW() FROM generate_series(20001, 22000);

-- 5. lab_inventario (6% de cambio) -> BAJA PRIORIDAD. Apenas pasa el umbral del 5%.
UPDATE lab.inventario SET stock = stock - 1 WHERE id <= 1200;

-- ================== TABLAS TRAMPA (DEBEN SER IGNORADAS) ==================

-- 6. lab_clientes (2% de cambio) -> IGNORADA. No llega al umbral del 5%.
UPDATE lab.clientes SET estatus = 'INACTIVO' WHERE id <= 400;

-- 7. lab_productos (0% de cambio) -> IGNORADA. El catálogo no mutó hoy.
-- (Sin operaciones DML)

COMMIT;

```

---

### 🔍 CÓMO EJECUTAR LA PRUEBA TÁCTICA

#### PASO 1: Verifica la Telemetría (El Radar)

Antes de disparar el orquestador, corre esta consulta para ver qué es lo que el motor de PostgreSQL está detectando. Aquí verás exactamente las matemáticas que usará nuestro orquestador:

```sql
  SELECT
    schemaname,
    relname AS nombre_tabla,
    n_live_tup AS filas_vivas,
    n_mod_since_analyze AS filas_modificadas,
    ROUND((n_mod_since_analyze::numeric / NULLIF(n_live_tup, 0)) * 100, 2) AS change_pct
FROM pg_stat_user_tables
WHERE     schemaname  = 'lab'
ORDER BY change_pct DESC NULLS LAST;
```

**Salida esperada**
```
 schemaname |  nombre_tabla   | filas_vivas | filas_modificadas | change_pct 
------------+-----------------+-------------+-------------------+------------
 lab        | carritos        |       10000 |             10000 |     100.00
 lab        | sesiones        |       20000 |             18000 |      90.00
 lab        | pedidos         |       20000 |              3000 |      15.00
 lab        | logs_auditoria  |       22000 |              2000 |       9.09
 lab        | inventario      |       20000 |              1200 |       6.00
 lab        | clientes        |       20000 |               400 |       2.00
 lab        | envios          |       20000 |                 0 |       0.00
 lab        | pagos           |       20000 |                 0 |       0.00
 lab        | detalle_pedidos |       20000 |                 0 |       0.00
 lab        | productos       |       20000 |                 0 |       0.00
(10 rows)
```



#### PASO 2: Dispara el Orquestador Vanguard (Modo Visual)

Ahora, activa el arma. Pídele 4 hilos paralelos, un umbral del 5% (0.05) y enciende el modo visual (`TRUE`):

```sql
  CALL maint.sp_orchestrate_analyze(
      p_scope            => 'SMART_USER',       -- VARCHAR : Alcance ('SMART_USER', 'ALL_USER', 'CUSTOM_LIST', 'SMART_SYSTEM_USER', 'ALL_SYSTEM_USER', 'ALL_SYSTEM')
      p_profile          => 'NORMAL',           -- VARCHAR : Perfil de ejecución ('NORMAL' o 'PRELOAD')
      p_parallel_workers => 4,                  -- INT     : Cantidad de hilos/workers en paralelo (Max concurrencia)
      p_verbose          => TRUE,               -- BOOLEAN : Diagnóstico visual en tiempo real en consola (TRUE/FALSE)
      p_threshold_pct    => 51,                 -- NUMERIC : Umbral de cambios minimo para realizar un analyze (5.00 = 5% de cambio)
      p_min_chg_rows         => 1000,               -- INT     : Mínima cantidad de cambios realizar un analyze (Filtro anti-morralla) 
      p_force_chg_rows       => 50000,              -- INT     : Realiza analyze si tiene esta cantidad de cambios de filas (NULL para desactivar)
      p_cutoff_time      => NULL,               -- TIME    : Freno de emergencia (Kill Switch) por hora límite (NULL para sin límite)
      p_keep_history     => TRUE                -- BOOLEAN : Retención de auditoría en analyze_tasks (FALSE = Purga efímera al finalizar)
  );
```
**Salida esperada**
```
INFO:  =========================================================
INFO:  [DBA SQUAD] INICIANDO ORQUESTADOR ANALYZE VANGUARD
INFO:  ALCANCE: SMART_USER | PERFIL: NORMAL | HILOS: 4 | FASES: 1 | CUTOFF: SIN LIMITE | HISTORIAL: t
INFO:  =========================================================
INFO:  ---------------------------------------------------------
INFO:  >>> INICIANDO FASE 1 DE 1 <<<
INFO:  ---------------------------------------------------------
INFO:      [>] LANZANDO (Fase 1) PID 750576 -> lab.sesiones
INFO:      [>] LANZANDO (Fase 1) PID 750577 -> lab.carritos
INFO:      [✓] EXITO (Fase 1) -> lab.sesiones
INFO:      [✓] EXITO (Fase 1) -> lab.carritos
INFO:  ---------------------------------------------------------
INFO:  [✓] ORQUESTACION FINALIZADA. Job 1 | Tablas procesadas: 2 / 2
INFO:  Tiempo Total: 00:00:01.029435
INFO:  =========================================================
CALL

```


#### PASO 2: Verifica la Telemetría 
Corroborar la información
```sql
 SELECT
    schemaname,
    relname AS nombre_tabla,
    n_live_tup AS filas_vivas,
    n_mod_since_analyze AS filas_modificadas,
    ROUND((n_mod_since_analyze::numeric / NULLIF(n_live_tup, 0)) * 100, 2) AS change_pct
FROM pg_stat_user_tables
WHERE     schemaname  = 'lab'
ORDER BY change_pct DESC NULLS LAST;
```

**Salida esperada**
```
 schemaname |  nombre_tabla   | filas_vivas | filas_modificadas | change_pct 
------------+-----------------+-------------+-------------------+------------
 lab        | pedidos         |       20000 |              3000 |      15.00
 lab        | logs_auditoria  |       22000 |              2000 |       9.09
 lab        | inventario      |       20000 |              1200 |       6.00
 lab        | clientes        |       20000 |               400 |       2.00
 lab        | pagos           |       20000 |                 0 |       0.00
 lab        | envios          |       20000 |                 0 |       0.00
 lab        | detalle_pedidos |       20000 |                 0 |       0.00
 lab        | carritos        |       10000 |                 0 |       0.00
 lab        | sesiones        |       20000 |                 0 |       0.00
 lab        | productos       |       20000 |                 0 |       0.00
(10 rows)
```


## Forzando las tablas que tengan igual o mas de 3000 filas modificadas
```
  CALL maint.sp_orchestrate_analyze(
      p_scope            => 'SMART_USER',       -- VARCHAR : Alcance ('SMART_USER', 'ALL_USER', 'CUSTOM_LIST', 'SMART_SYSTEM_USER', 'ALL_SYSTEM_USER', 'ALL_SYSTEM')
      p_profile          => 'NORMAL',           -- VARCHAR : Perfil de ejecución ('NORMAL' o 'PRELOAD')
      p_parallel_workers => 4,                  -- INT     : Cantidad de hilos/workers en paralelo (Max concurrencia)
      p_verbose          => TRUE,               -- BOOLEAN : Diagnóstico visual en tiempo real en consola (TRUE/FALSE)
      p_threshold_pct    => 51,                 -- NUMERIC : Umbral de cambios minimo para realizar un analyze (5.00 = 5% de cambio)
      p_min_chg_rows         => 1000,               -- INT     : Mínima cantidad de cambios realizar un analyze (Filtro anti-morralla) 
      p_force_chg_rows       => 3000,              -- INT     : Realiza analyze si tiene esta cantidad de cambios de filas (NULL para desactivar)
      p_cutoff_time      => NULL,               -- TIME    : Freno de emergencia (Kill Switch) por hora límite (NULL para sin límite)
      p_keep_history     => TRUE                -- BOOLEAN : Retención de auditoría en analyze_tasks (FALSE = Purga efímera al finalizar)
  );

```

**Salida esperada**
```
INFO:  =========================================================
INFO:  [DBA SQUAD] INICIANDO ORQUESTADOR ANALYZE VANGUARD
INFO:  ALCANCE: SMART_USER | PERFIL: NORMAL | HILOS: 4 | FASES: 1 | CUTOFF: SIN LIMITE | HISTORIAL: t
INFO:  =========================================================
INFO:  ---------------------------------------------------------
INFO:  >>> INICIANDO FASE 1 DE 1 <<<
INFO:  ---------------------------------------------------------
INFO:      [>] LANZANDO (Fase 1) PID 750656 -> lab.pedidos
INFO:      [✓] EXITO (Fase 1) -> lab.pedidos
INFO:  ---------------------------------------------------------
INFO:  [✓] ORQUESTACION FINALIZADA. Job 2 | Tablas procesadas: 1 / 1
INFO:  Tiempo Total: 00:00:01.019255
INFO:  =========================================================
CALL
```

####  Verifica la Telemetría 
Corroborar la información
```sql
 SELECT
    schemaname,
    relname AS nombre_tabla,
    n_live_tup AS filas_vivas,
    n_mod_since_analyze AS filas_modificadas,
    ROUND((n_mod_since_analyze::numeric / NULLIF(n_live_tup, 0)) * 100, 2) AS change_pct
FROM pg_stat_user_tables
WHERE     schemaname  = 'lab'
ORDER BY change_pct DESC NULLS LAST;
```

**Salida esperada**
```
 schemaname |  nombre_tabla   | filas_vivas | filas_modificadas | change_pct 
------------+-----------------+-------------+-------------------+------------
 lab        | logs_auditoria  |       22000 |              2000 |       9.09
 lab        | inventario      |       20000 |              1200 |       6.00
 lab        | clientes        |       20000 |               400 |       2.00
 lab        | detalle_pedidos |       20000 |                 0 |       0.00
 lab        | pagos           |       20000 |                 0 |       0.00
 lab        | envios          |       20000 |                 0 |       0.00
 lab        | pedidos         |       20000 |                 0 |       0.00
 lab        | carritos        |       10000 |                 0 |       0.00
 lab        | sesiones        |       20000 |                 0 |       0.00
 lab        | productos       |       20000 |                 0 |       0.00
(10 rows)
```

## Ejecutar ahora los que tengan 5% y minimo 1500 filas modificadas
```
  CALL maint.sp_orchestrate_analyze(
      p_scope            => 'SMART_USER',       -- VARCHAR : Alcance ('SMART_USER', 'ALL_USER', 'CUSTOM_LIST', 'SMART_SYSTEM_USER', 'ALL_SYSTEM_USER', 'ALL_SYSTEM')
      p_profile          => 'NORMAL',           -- VARCHAR : Perfil de ejecución ('NORMAL' o 'PRELOAD')
      p_parallel_workers => 4,                  -- INT     : Cantidad de hilos/workers en paralelo (Max concurrencia)
      p_verbose          => TRUE,               -- BOOLEAN : Diagnóstico visual en tiempo real en consola (TRUE/FALSE)
      p_threshold_pct    => 5,                 -- NUMERIC : Umbral de cambios minimo para realizar un analyze (5.00 = 5% de cambio)
      p_min_chg_rows         => 1500,               -- INT     : Mínima cantidad de cambios realizar un analyze (Filtro anti-morralla) 
      p_force_chg_rows       => 3000,              -- INT     : Realiza analyze si tiene esta cantidad de cambios de filas (NULL para desactivar)
      p_cutoff_time      => NULL,               -- TIME    : Freno de emergencia (Kill Switch) por hora límite (NULL para sin límite)
      p_keep_history     => TRUE                -- BOOLEAN : Retención de auditoría en analyze_tasks (FALSE = Purga efímera al finalizar)
  );
```


**Salida esperada**
```
INFO:  =========================================================
INFO:  [DBA SQUAD] INICIANDO ORQUESTADOR ANALYZE VANGUARD
INFO:  ALCANCE: SMART_USER | PERFIL: NORMAL | HILOS: 4 | FASES: 1 | CUTOFF: SIN LIMITE | HISTORIAL: t
INFO:  =========================================================
INFO:  ---------------------------------------------------------
INFO:  >>> INICIANDO FASE 1 DE 1 <<<
INFO:  ---------------------------------------------------------
INFO:      [>] LANZANDO (Fase 1) PID 750733 -> lab.logs_auditoria
INFO:      [✓] EXITO (Fase 1) -> lab.logs_auditoria
INFO:  ---------------------------------------------------------
INFO:  [✓] ORQUESTACION FINALIZADA. Job 3 | Tablas procesadas: 1 / 1
INFO:  Tiempo Total: 00:00:01.019036
INFO:  =========================================================
CALL
```

####  Verifica la Telemetría 
Corroborar la información
```sql
 SELECT
    schemaname,
    relname AS nombre_tabla,
    n_live_tup AS filas_vivas,
    n_mod_since_analyze AS filas_modificadas,
    ROUND((n_mod_since_analyze::numeric / NULLIF(n_live_tup, 0)) * 100, 2) AS change_pct
FROM pg_stat_user_tables
WHERE     schemaname  = 'lab'
ORDER BY change_pct DESC NULLS LAST;
```

**Salida esperada**
```
 schemaname |  nombre_tabla   | filas_vivas | filas_modificadas | change_pct 
------------+-----------------+-------------+-------------------+------------
 lab        | inventario      |       20000 |              1200 |       6.00
 lab        | clientes        |       20000 |               400 |       2.00
 lab        | pedidos         |       20000 |                 0 |       0.00
 lab        | detalle_pedidos |       20000 |                 0 |       0.00
 lab        | pagos           |       20000 |                 0 |       0.00
 lab        | envios          |       20000 |                 0 |       0.00
 lab        | carritos        |       10000 |                 0 |       0.00
 lab        | sesiones        |       20000 |                 0 |       0.00
 lab        | logs_auditoria  |       22000 |                 0 |       0.00
 lab        | productos       |       20000 |                 0 |       0.00
(10 rows)
```


---
# Monitorear
 

### 1. MONITOREO EN VIVO DESDE `pg_stat_activity`

*(Monitorea la actividad del sistema operativo, el proceso Padre y los procesos Hijos en la memoria RAM del servidor)*

```sql
SELECT 
    pid,
    backend_type,
    usename,
    client_addr,
    state,
    clock_timestamp() - query_start AS duracion_actual,
    query
FROM pg_catalog.pg_stat_activity
WHERE (backend_type = 'pg_background' OR query ILIKE '%sp_orchestrate_analyze%')
  AND pid <> pg_backend_pid()
ORDER BY query_start ASC;

```

 
---

### 2. MONITOREO FORENSE DESDE `maint.analyze_tasks`

*(Monitorea el progreso de la cola, qué tabla está corriendo, cuál terminó, cuál falló y el porcentaje de cambio/desfase)*

```sql
SELECT 
    t.task_id,
    j.job_type,
    j.maintenance_action AS accion,
    t.schema_name || '.' || t.table_name AS tabla_objetivo,
    t.total_filas,
    t.filas_afectadas,
    t.drift_pct AS porcentaje_desfase,
    t.status AS estatus_tarea,
    t.child_pid,
    COALESCE(t.ended_at, clock_timestamp()) - t.started_at AS duracion,
    COALESCE(t.error_log, 'Ninguno') AS detalle_error
FROM maint.analyze_tasks t
JOIN maint.jobs j ON t.job_id = j.job_id
WHERE t.job_id = (SELECT MAX(job_id) FROM maint.jobs)
ORDER BY t.task_id ASC;


SELECT 
    stage_number AS fase,
    schema_name || '.' || table_name AS tabla,
    status AS estatus,
    ROUND(EXTRACT(EPOCH FROM (ended_at - started_at))::numeric, 3) AS duracion_segundos
FROM maint.analyze_tasks
WHERE job_id = (SELECT MAX(job_id) FROM maint.jobs)
ORDER BY schema_name, table_name, stage_number;

select * from maint.jobs;
select * from maint.analyze_tasks;

```
