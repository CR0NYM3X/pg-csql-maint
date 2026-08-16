
# 🧪 LABORATORIO VANGUARD: POLÍGONO DE TIRO SQL

Ejecuta este script completo en tu entorno de desarrollo/pruebas.

```sql
-- ============================================================================
-- DBA SQUAD: VANGUARD BLACK-OPS - LABORATORIO DE CAOS SINTÉTICO
-- ============================================================================
SET autovacuum = off;

BEGIN;

-- ----------------------------------------------------------------------------
-- FASE 1: CREACIÓN DE ESTRUCTURAS (10 Tablas)
-- ----------------------------------------------------------------------------
DROP TABLE IF EXISTS public.lab_clientes, public.lab_productos, public.lab_pedidos, 
                     public.lab_detalle_pedidos, public.lab_pagos, public.lab_envios, 
                     public.lab_inventario, public.lab_carritos, public.lab_sesiones, 
                     public.lab_logs_auditoria CASCADE;

CREATE TABLE public.lab_clientes (id SERIAL PRIMARY KEY, nombre TEXT, estatus TEXT);
CREATE TABLE public.lab_productos (id SERIAL PRIMARY KEY, sku TEXT, precio NUMERIC);
CREATE TABLE public.lab_pedidos (id SERIAL PRIMARY KEY, cliente_id INT, total NUMERIC, estado TEXT);
CREATE TABLE public.lab_detalle_pedidos (id SERIAL PRIMARY KEY, pedido_id INT, cantidad INT);
CREATE TABLE public.lab_pagos (id SERIAL PRIMARY KEY, pedido_id INT, monto NUMERIC, metodo TEXT);
CREATE TABLE public.lab_envios (id SERIAL PRIMARY KEY, pedido_id INT, guia TEXT, estado TEXT);
CREATE TABLE public.lab_inventario (id SERIAL PRIMARY KEY, producto_id INT, stock INT);
CREATE TABLE public.lab_carritos (id SERIAL PRIMARY KEY, cliente_id INT, fecha_creacion TIMESTAMP);
CREATE TABLE public.lab_sesiones (id SERIAL PRIMARY KEY, token TEXT, ultima_actividad TIMESTAMP);
CREATE TABLE public.lab_logs_auditoria (id SERIAL PRIMARY KEY, evento TEXT, fecha TIMESTAMP);

ALTER TABLE public.lab_clientes SET (autovacuum_enabled = false);
ALTER TABLE public.lab_productos SET (autovacuum_enabled = false);
ALTER TABLE public.lab_pedidos SET (autovacuum_enabled = false);
ALTER TABLE public.lab_detalle_pedidos SET (autovacuum_enabled = false);
ALTER TABLE public.lab_pagos SET (autovacuum_enabled = false);
ALTER TABLE public.lab_envios SET (autovacuum_enabled = false);
ALTER TABLE public.lab_inventario SET (autovacuum_enabled = false);
ALTER TABLE public.lab_carritos SET (autovacuum_enabled = false);
ALTER TABLE public.lab_sesiones SET (autovacuum_enabled = false);
ALTER TABLE public.lab_logs_auditoria SET (autovacuum_enabled = false);

-- ----------------------------------------------------------------------------
-- FASE 2: INYECCIÓN DE VOLUMEN (20,000 filas por tabla para superar filtro de 10k)
-- ----------------------------------------------------------------------------
INSERT INTO public.lab_clientes (nombre, estatus) SELECT 'Cliente ' || i, 'ACTIVO' FROM generate_series(1, 20000) i;
INSERT INTO public.lab_productos (sku, precio) SELECT 'SKU-' || i, RANDOM() * 1000 FROM generate_series(1, 20000) i;
INSERT INTO public.lab_pedidos (cliente_id, total, estado) SELECT i, RANDOM() * 500, 'NUEVO' FROM generate_series(1, 20000) i;
INSERT INTO public.lab_detalle_pedidos (pedido_id, cantidad) SELECT i, 1 FROM generate_series(1, 20000) i;
INSERT INTO public.lab_pagos (pedido_id, monto, metodo) SELECT i, 100, 'TARJETA' FROM generate_series(1, 20000) i;
INSERT INTO public.lab_envios (pedido_id, guia, estado) SELECT i, 'GUIA-'||i, 'PREPARANDO' FROM generate_series(1, 20000) i;
INSERT INTO public.lab_inventario (producto_id, stock) SELECT i, 100 FROM generate_series(1, 20000) i;
INSERT INTO public.lab_carritos (cliente_id, fecha_creacion) SELECT i, NOW() FROM generate_series(1, 20000) i;
INSERT INTO public.lab_sesiones (token, ultima_actividad) SELECT md5(i::text), NOW() FROM generate_series(1, 20000) i;
INSERT INTO public.lab_logs_auditoria (evento, fecha) SELECT 'LOGIN', NOW() FROM generate_series(1, 20000) i;

COMMIT;

-- ----------------------------------------------------------------------------
-- FASE 3: ESTABILIZACIÓN DEL MOTOR (Punto Cero)
-- Hacemos un ANALYZE masivo para que el motor ponga n_mod_since_analyze en 0.
-- ----------------------------------------------------------------------------
ANALYZE public.lab_clientes;
ANALYZE public.lab_productos;
ANALYZE public.lab_pedidos;
ANALYZE public.lab_detalle_pedidos;
ANALYZE public.lab_pagos;
ANALYZE public.lab_envios;
ANALYZE public.lab_inventario;
ANALYZE public.lab_carritos;
ANALYZE public.lab_sesiones;
ANALYZE public.lab_logs_auditoria;

-- ----------------------------------------------------------------------------
-- FASE 4: SIMULACIÓN DE CAOS TRANSACCIONAL (El paso del tiempo)
-- ----------------------------------------------------------------------------
BEGIN;

-- 1. lab_sesiones (90% de cambio) -> ALTA PRIORIDAD. Expira sesiones viejas.
UPDATE public.lab_sesiones SET ultima_actividad = NOW() WHERE id <= 18000;

-- 2. lab_carritos (50% de cambio) -> ALTA PRIORIDAD. Borrado masivo de carritos abandonados.
DELETE FROM public.lab_carritos WHERE id <= 10000;

-- 3. lab_pedidos (15% de cambio) -> MEDIA PRIORIDAD. Pedidos que pasaron a ENVIADO.
UPDATE public.lab_pedidos SET estado = 'ENVIADO' WHERE id <= 3000;

-- 4. lab_logs_auditoria (10% de cambio) -> MEDIA PRIORIDAD. Inserción de nuevos logs.
INSERT INTO public.lab_logs_auditoria (evento, fecha) SELECT 'CLICK', NOW() FROM generate_series(20001, 22000);

-- 5. lab_inventario (6% de cambio) -> BAJA PRIORIDAD. Apenas pasa el umbral del 5%.
UPDATE public.lab_inventario SET stock = stock - 1 WHERE id <= 1200;

-- ================== TABLAS TRAMPA (DEBEN SER IGNORADAS) ==================

-- 6. lab_clientes (2% de cambio) -> IGNORADA. No llega al umbral del 5%.
UPDATE public.lab_clientes SET estatus = 'INACTIVO' WHERE id <= 400;

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
    relname AS nombre_tabla,
    n_live_tup AS filas_vivas,
    n_mod_since_analyze AS filas_modificadas,
    ROUND((n_mod_since_analyze::numeric / NULLIF(n_live_tup, 0)) * 100, 2) AS change_pct
FROM pg_stat_user_tables
WHERE relname LIKE 'lab_%'
ORDER BY change_pct DESC NULLS LAST;

```

**Salida esperada**
```
+---------------------+-------------+-------------------+------------+
|    nombre_tabla     | filas_vivas | filas_modificadas | change_pct |
+---------------------+-------------+-------------------+------------+
| lab_carritos        |       10000 |             10000 |     100.00 |
| lab_sesiones        |       20000 |             18000 |      90.00 |
| lab_pedidos         |       20000 |              3000 |      15.00 |
| lab_logs_auditoria  |       22000 |              2000 |       9.09 |
| lab_inventario      |       20000 |              1200 |       6.00 |
| lab_clientes        |       20000 |               400 |       2.00 |
| lab_envios          |       20000 |                 0 |       0.00 |
| lab_pagos           |       20000 |                 0 |       0.00 |
| lab_detalle_pedidos |       20000 |                 0 |       0.00 |
| lab_productos       |       20000 |                 0 |       0.00 |
+---------------------+-------------+-------------------+------------+
```



#### PASO 2: Dispara el Orquestador Vanguard (Modo Visual)

Ahora, activa el arma. Pídele 4 hilos paralelos, un umbral del 5% (0.05) y enciende el modo visual (`TRUE`):

```sql
CALL maint.sp_orchestrate_analyze(
    p_job_type         => 'SMART',        -- Modo quirúrgico: Solo analiza lo que realmente mutó
    p_parallel_workers => 4,              -- Fuerza bruta controlada: 4 núcleos de CPU trabajando en paralelo
    p_verbose          => TRUE ,          -- Silencioso: Como se ejecuta en automático, para pg_cron usa false
    p_threshold_pct    => 0.05,           -- Umbral del 5%: Solo toca la tabla si el 5% de sus datos cambiaron
    p_min_rows         => 1000,           -- Filtro anti-morralla: Ignora tablas con menos de 1,000 cambios
    p_cutoff_time      => '06:00:00'::TIME -- [KILL SWITCH]: Aborto automático a las 6:00 AM exactas o usa NULL para deshabilitarlo
);
```

#### PASO 2: Verifica la Telemetría 
Corroborar la información
```sql
SELECT 
    relname AS nombre_tabla,
    n_live_tup AS filas_vivas,
    n_mod_since_analyze AS filas_modificadas,
    ROUND((n_mod_since_analyze::numeric / NULLIF(n_live_tup, 0)) * 100, 2) AS change_pct
FROM pg_stat_user_tables
WHERE relname LIKE 'lab_%'
ORDER BY change_pct DESC NULLS LAST;

```

**Salida esperada**
```
+---------------------+-------------+-------------------+------------+
|    nombre_tabla     | filas_vivas | filas_modificadas | change_pct |
+---------------------+-------------+-------------------+------------+
| lab_clientes        |       20000 |               400 |       2.00 |
| lab_productos       |       20000 |                 0 |       0.00 |
| lab_pedidos         |       20000 |                 0 |       0.00 |
| lab_detalle_pedidos |       20000 |                 0 |       0.00 |
| lab_pagos           |       20000 |                 0 |       0.00 |
| lab_envios          |       20000 |                 0 |       0.00 |
| lab_inventario      |       20000 |                 0 |       0.00 |
| lab_carritos        |       10000 |                 0 |       0.00 |
| lab_sesiones        |       20000 |                 0 |       0.00 |
| lab_logs_auditoria  |       22000 |                 0 |       0.00 |
+---------------------+-------------+-------------------+------------+
```

## Monitorear
 

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

### 2. MONITOREO FORENSE DESDE `public.analyze_tasks`

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
WHERE t.job_id = (SELECT MAX(job_id) FROM public.jobs)
ORDER BY t.task_id ASC;


SELECT 
    stage_number AS fase,
    schema_name || '.' || table_name AS tabla,
    status AS estatus,
    ROUND(EXTRACT(EPOCH FROM (ended_at - started_at))::numeric, 3) AS duracion_segundos
FROM maint.analyze_tasks
WHERE job_id = (SELECT MAX(job_id) FROM public.jobs)
ORDER BY schema_name, table_name, stage_number;

select * from maint.jobs;

select * from maint.analyze_tasks;

```
