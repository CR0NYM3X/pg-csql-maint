 
###   FASE 1: WAR GAMES (GENERACIÓN MASIVA DE TRÁFICO Y BLOAT REAL)

Ejecuta este bloque para destruir el entorno anterior y crear un volumen de datos que realmente despierte a los algoritmos predictivos del Orquestador.

```sql
-- ====================================================================================
-- DBA SQUAD: VANGUARD BLACK-OPS | SIMULADOR DE ESTRÉS TRANSACCIONAL
-- ====================================================================================
-- drop schema lab cascade;
create schema IF NOT EXISTS lab;

-- 1. Limpieza Total del Entorno
DROP TABLE IF EXISTS lab.demo_extreme_bloat CASCADE;
DROP TABLE IF EXISTS lab.demo_heavy_updates CASCADE;
DROP TABLE IF EXISTS lab.demo_vip_facturas CASCADE;
DROP TABLE IF EXISTS lab.demo_escudo_historial CASCADE;


-- 2. Creación de Topología de Tablas
CREATE TABLE lab.demo_extreme_bloat (id SERIAL, payload TEXT, status VARCHAR(20));
CREATE TABLE lab.demo_heavy_updates (id SERIAL, balance NUMERIC, last_tx TIMESTAMPTZ);
CREATE TABLE lab.demo_vip_facturas (id SERIAL, monto NUMERIC, cliente TEXT);
CREATE TABLE lab.demo_escudo_historial (id SERIAL, log_data TEXT);

ALTER TABLE lab.demo_extreme_bloat SET (autovacuum_enabled = false);
ALTER TABLE lab.demo_heavy_updates SET (autovacuum_enabled = false);
ALTER TABLE lab.demo_vip_facturas SET (autovacuum_enabled = false);
ALTER TABLE lab.demo_escudo_historial SET (autovacuum_enabled = false);

-- ====================================================================================
-- 3. INYECCIÓN MASIVA DE TRÁFICO (SIMULACIÓN DE 6 MESES DE PRODUCCIÓN)
-- ====================================================================================

-- [CASO A] TABLA EXTREMA: Objetivo -> SMART_VACUUM_FULL
-- Insertamos 500,000 filas. Borramos el 90%. Ejecutamos VACUUM normal.
-- Esto genera páginas de disco llenas de "Huecos Físicos" (Free Space) que requieren Vacuum Full.
INSERT INTO lab.demo_extreme_bloat(payload, status) 
SELECT md5(g::text), 'PROCESADO' FROM generate_series(1, 500000) g;

DELETE FROM lab.demo_extreme_bloat WHERE id % 10 != 0; -- Borra 450,000 filas
-- VACUUM lab.demo_extreme_bloat; -- Convierte las tuplas muertas en Espacio Libre Físico
-- ANALYZE lab.demo_extreme_bloat;

-- [CASO B] TABLA DE ALTA TRANSACCIONALIDAD: Objetivo -> Mantenimiento AGGRESSIVE
-- Insertamos 200,000 filas y las actualizamos para generar tuplas muertas masivas.
INSERT INTO lab.demo_heavy_updates(balance, last_tx) 
SELECT g * 10.5, clock_timestamp() FROM generate_series(1, 200000) g;

UPDATE lab.demo_heavy_updates SET balance = balance + 1.0; 
UPDATE lab.demo_heavy_updates SET balance = balance + 2.0; -- Doble update = +400k tuplas muertas
ANALYZE lab.demo_heavy_updates;

-- [CASO C] TABLA VIP (Lista Blanca): Objetivo -> CUSTOM_LIST
INSERT INTO lab.demo_vip_facturas(monto, cliente) 
SELECT 100.00, 'Cliente VIP' FROM generate_series(1, 50000) g;
UPDATE lab.demo_vip_facturas SET monto = 150.00 WHERE id < 10000;
ANALYZE lab.demo_vip_facturas;

-- [CASO D] TABLA INMUNE (Lista Negra): Objetivo -> ESCUDO DE IGNORADOS
INSERT INTO lab.demo_escudo_historial(log_data) 
SELECT 'Log de Sistema Crítico' FROM generate_series(1, 100000) g;
DELETE FROM lab.demo_escudo_historial WHERE id < 50000; -- Generamos basura intencional
ANALYZE lab.demo_escudo_historial;

-- ====================================================================================
-- 4. CONFIGURACIÓN DEL PANEL DE SEGURIDAD (FILTROS)
-- ====================================================================================
INSERT INTO maint.filters (schema_name, table_name, is_ignored, force_maintenance, maintenance_action) VALUES 
('lab', 'demo_heavy_updates', TRUE, FALSE, 'VACUUM'),  -- [ESCUDO ACTIVO]: Intocable.
('lab', 'demo_extreme_bloat', FALSE, TRUE, 'VACUUM');      -- [PASE VIP]: Mantenimiento prioritario.

```

---

### Revisamos los filtros aplicados
En este caso se bloqueo el vacuum de la tabla demo_heavy_updates ya que esta en true la columna is_ignored
```
select * from  maint.filters ;
 filter_id | schema_name |     table_name     | maintenance_action | is_ignored | force_maintenance |          created_at           |          updated_at           | updated_by 
-----------+-------------+--------------------+--------------------+------------+-------------------+-------------------------------+-------------------------------+------------
         2 | lab         | demo_extreme_bloat | VACUUM             | f          | t                 | 2026-08-24 23:50:54.445931+00 | 2026-08-24 23:50:54.445931+00 | postgres2
         1 | lab         | demo_heavy_updates | VACUUM             | t          | f                 | 2026-08-24 23:50:54.445692+00 | 2026-08-24 23:50:54.445692+00 | postgres2
```

### Revisar los porcentajes de tuplas muertas
```
SELECT
    schemaname,
    relname AS nombre_tabla,
    n_live_tup AS filas_vivas,
    n_dead_tup AS filas_muertas,
    n_mod_since_analyze AS filas_modificadas,
    ROUND(COALESCE((n_dead_tup::numeric / NULLIF(n_live_tup + n_dead_tup, 0)) * 100, 0.00), 2) as porc_tuplas_muertas_vacuum,
    ROUND((n_mod_since_analyze::numeric / NULLIF(n_live_tup, 0)) * 100, 2) AS change_pct_analyze
FROM pg_stat_user_tables
WHERE     schemaname  = 'lab' and relname in('demo_extreme_bloat','demo_heavy_updates','demo_vip_facturas','demo_escudo_historial')
ORDER BY porc_tuplas_muertas_vacuum DESC NULLS LAST;
```

**Salida esperada**
```
 schemaname |     nombre_tabla      | filas_vivas | filas_muertas | filas_modificadas | porc_tuplas_muertas_vacuum | change_pct_analyze 
------------+-----------------------+-------------+---------------+-------------------+----------------------------+--------------------
 lab        | demo_extreme_bloat    |       50000 |        450000 |            950000 |                      90.00 |            1900.00
 lab        | demo_heavy_updates    |      200000 |        400000 |            400000 |                      66.67 |             200.00
 lab        | demo_escudo_historial |      100002 |         49999 |            149999 |                      33.33 |             150.00
 lab        | demo_vip_facturas     |      100000 |          9999 |             59999 |                       9.09 |              60.00
```




# Escenario 1: Mantenimiento Diario Inteligente
Aqui aunque las tablas lab.demo_extreme_bloat y lab.demo_heavy_updates cumplen con las condiciones.
pero unicamente se procesara la tabla demo_extreme_bloat  esto debido a que la tabla demo_heavy_updates tiene
aplicado el filtro de is_ignored en la tabla maint.filters

```sql
---- Mantenimiento a todas las tablas Forzado
CALL maint.sp_orchestrate_vacuum(
    p_scope          => 'SMART_USER',  -- VARCHAR : Alcance ('SMART_USER', 'ALL_USER', 'CUSTOM_LIST', 'SMART_SYSTEM_USER', 'ALL_SYSTEM_USER', 'ALL_SYSTEM')
    p_profile        => 'BALANCED',    -- VARCHAR : Perfil de vacuum ('LIGHT', 'BALANCED', 'AGGRESSIVE')
    p_parallel_workers => 4,           -- INT     : Cantidad máxima de hilos/workers asíncronos en paralelo
    p_cutoff_time    => NULL,          -- TIME    : Freno de emergencia / Kill-Switch por hora límite (ej. '06:00:00'::TIME; NULL = sin límite)
    p_verbose        => TRUE,          -- BOOLEAN : Diagnóstico visual en tiempo real en consola (TRUE/FALSE)
    p_threshold_pct  => 60,          -- NUMERIC : Umbral de porcentaje mínimo de tuplas muertas (5.00 = 5% de muertas)
    p_min_dead_rows   => 5000,          -- INT     : Cantidad mínima de tuplas muertas para evaluar (Filtro anti-morralla)
    p_force_dead_rows => 50000,         -- INT     : Fuerza la entrada si la tabla supera esta cantidad de tuplas muertas (NULL para desactivar)
    p_keep_history   => TRUE           -- BOOLEAN : Retención de auditoría en vacuum_tasks (FALSE = Purga la cola al finalizar)
);

 
```

**Salida esperada**
```
INFO:  =========================================================
INFO:  [DBA SQUAD] INICIANDO ORQUESTADOR VACUUM VANGUARD
INFO:  ALCANCE: SMART_USER | PERFIL: BALANCED | HILOS: 4 | CUTOFF: SIN LIMITE | HISTORIAL: t
INFO:  =========================================================
INFO:      [>] LANZANDO [BALANCED] PID 765786 -> lab.demo_extreme_bloat
INFO:      [✓] EXITO -> lab.demo_extreme_bloat
INFO:  ---------------------------------------------------------
INFO:  [✓] ORQUESTACION FINALIZADA. Job 5 | Tablas procesadas: 1 / 1
INFO:  Tiempo Total: 00:00:01.018093
INFO:  =========================================================
CALL
```

 

### Revisar los porcentajes de tuplas muertas
```
SELECT
    schemaname,
    relname AS nombre_tabla,
    n_live_tup AS filas_vivas,
    n_dead_tup AS filas_muertas,
    n_mod_since_analyze AS filas_modificadas,
    ROUND(COALESCE((n_dead_tup::numeric / NULLIF(n_live_tup + n_dead_tup, 0)) * 100, 0.00), 2) as porc_tuplas_muertas_vacuum,
    ROUND((n_mod_since_analyze::numeric / NULLIF(n_live_tup, 0)) * 100, 2) AS change_pct_analyze
FROM pg_stat_user_tables
WHERE     schemaname  = 'lab' and relname in('demo_extreme_bloat','demo_heavy_updates','demo_vip_facturas','demo_escudo_historial')
ORDER BY porc_tuplas_muertas_vacuum DESC NULLS LAST;
```

**Salida esperada**
```
 schemaname |     nombre_tabla      | filas_vivas | filas_muertas | filas_modificadas | porc_tuplas_muertas_vacuum | change_pct_analyze 
------------+-----------------------+-------------+---------------+-------------------+----------------------------+--------------------
 lab        | demo_heavy_updates    |      200000 |        400000 |            400000 |                      66.67 |             200.00 -- esta no se aplico ya que tiene aplicado un filtro
 lab        | demo_escudo_historial |      100002 |         49999 |            149999 |                      33.33 |             150.00
 lab        | demo_vip_facturas     |      100000 |          9999 |             59999 |                       9.09 |              60.00
 lab        | demo_extreme_bloat    |       50000 |             0 |            950000 |                       0.00 |            1900.00
(4 rows)
```
 



# Escenario 2 : Mantenimiento modificando el p_force_dead_rows a 40000
aqui lo que vamos hacer es forzar el mantenimiento para las tabla que tengan igual o más de 40,000 filas muertas sin importar el % .
por lo que las tablas que cumplen esta condicion son demo_heavy_updates y demo_escudo_historial, pero la tabla demo_heavy_updates no se va hacer
porque esta ignorada por los mantenimientos en maint.filters, asi que la unica tabla que se va ser es lab.demo_escudo_historial

```sql
---- Mantenimiento a todas las tablas Forzado
CALL maint.sp_orchestrate_vacuum(
    p_scope          => 'SMART_USER',  -- VARCHAR : Alcance ('SMART_USER', 'ALL_USER', 'CUSTOM_LIST', 'SMART_SYSTEM_USER', 'ALL_SYSTEM_USER', 'ALL_SYSTEM')
    p_profile        => 'BALANCED',    -- VARCHAR : Perfil de vacuum ('LIGHT', 'BALANCED', 'AGGRESSIVE')
    p_parallel_workers => 4,           -- INT     : Cantidad máxima de hilos/workers asíncronos en paralelo
    p_cutoff_time    => NULL,          -- TIME    : Freno de emergencia / Kill-Switch por hora límite (ej. '06:00:00'::TIME; NULL = sin límite)
    p_verbose        => TRUE,          -- BOOLEAN : Diagnóstico visual en tiempo real en consola (TRUE/FALSE)
    p_threshold_pct  => 60,          -- NUMERIC : Umbral de porcentaje mínimo de tuplas muertas (5.00 = 5% de muertas)
    p_min_dead_rows   => 5000,          -- INT     : Cantidad mínima de tuplas muertas para evaluar (Filtro anti-morralla)
    p_force_dead_rows => 40000,         -- INT     : Fuerza la entrada si la tabla supera esta cantidad de tuplas muertas (NULL para desactivar)
    p_keep_history   => TRUE           -- BOOLEAN : Retención de auditoría en vacuum_tasks (FALSE = Purga la cola al finalizar)
);

```

**Salida esperada**
```
INFO:  =========================================================
INFO:  [DBA SQUAD] INICIANDO ORQUESTADOR VACUUM VANGUARD
INFO:  ALCANCE: SMART_USER | PERFIL: BALANCED | HILOS: 4 | CUTOFF: SIN LIMITE | HISTORIAL: t
INFO:  =========================================================
INFO:      [>] LANZANDO [BALANCED] PID 858608 -> lab.demo_escudo_historial
INFO:      [✓] EXITO -> lab.demo_escudo_historial
INFO:  ---------------------------------------------------------
INFO:  [✓] ORQUESTACION FINALIZADA. Job 15 | Tablas procesadas: 1 / 1
INFO:  Tiempo Total: 00:00:01.016101
INFO:  =========================================================
CALL
```


### Revisar los porcentajes de tuplas muertas
```
SELECT
    schemaname,
    relname AS nombre_tabla,
    n_live_tup AS filas_vivas,
    n_dead_tup AS filas_muertas,
    n_mod_since_analyze AS filas_modificadas,
    ROUND(COALESCE((n_dead_tup::numeric / NULLIF(n_live_tup + n_dead_tup, 0)) * 100, 0.00), 2) as porc_tuplas_muertas_vacuum,
    ROUND((n_mod_since_analyze::numeric / NULLIF(n_live_tup, 0)) * 100, 2) AS change_pct_analyze
FROM pg_stat_user_tables
WHERE     schemaname  = 'lab' and relname in('demo_extreme_bloat','demo_heavy_updates','demo_vip_facturas','demo_escudo_historial')
ORDER BY porc_tuplas_muertas_vacuum DESC NULLS LAST;
```

**Salida esperada**
```
 schemaname |     nombre_tabla      | filas_vivas | filas_muertas | filas_modificadas | porc_tuplas_muertas_vacuum | change_pct_analyze 
------------+-----------------------+-------------+---------------+-------------------+----------------------------+--------------------
 lab        | demo_heavy_updates    |      200000 |        400000 |            400000 |                      66.67 |             200.00
 lab        | demo_vip_facturas     |      100000 |          9999 |             59999 |                       9.09 |              60.00
 lab        | demo_extreme_bloat    |       50000 |             0 |            950000 |                       0.00 |            1900.00
 lab        | demo_escudo_historial |       50001 |             0 |            149999 |                       0.00 |             299.99
(4 rows)
```

 

# Escenario 3 : Mantenimiento revisando el funcionamiento de p_min_dead_rows
en este escenario colocaremos un porcentaje de 5% y una restriccion de minimo 10,000 filas muertas para que aplique el mantenimiento.
para esto la tabla demo_vip_facturas es buen candidato porque tiene 9.09% pero tiene 9999 tuplas muertas asi que al ejecutar el mantenimiento
no deberia de arrojar nada

```sql
---- Mantenimiento a todas las tablas Forzado
CALL maint.sp_orchestrate_vacuum(
    p_scope          => 'SMART_USER',  -- VARCHAR : Alcance ('SMART_USER', 'ALL_USER', 'CUSTOM_LIST', 'SMART_SYSTEM_USER', 'ALL_SYSTEM_USER', 'ALL_SYSTEM')
    p_profile        => 'BALANCED',    -- VARCHAR : Perfil de vacuum ('LIGHT', 'BALANCED', 'AGGRESSIVE')
    p_parallel_workers => 4,           -- INT     : Cantidad máxima de hilos/workers asíncronos en paralelo
    p_cutoff_time    => NULL,          -- TIME    : Freno de emergencia / Kill-Switch por hora límite (ej. '06:00:00'::TIME; NULL = sin límite)
    p_verbose        => TRUE,          -- BOOLEAN : Diagnóstico visual en tiempo real en consola (TRUE/FALSE)
    p_threshold_pct  => 5,          -- NUMERIC : Umbral de porcentaje mínimo de tuplas muertas (5.00 = 5% de muertas)
    p_min_dead_rows   => 10000,          -- INT     : Cantidad mínima de tuplas muertas para evaluar (Filtro anti-morralla)
    p_force_dead_rows => 40000,         -- INT     : Fuerza la entrada si la tabla supera esta cantidad de tuplas muertas (NULL para desactivar)
    p_keep_history   => TRUE           -- BOOLEAN : Retención de auditoría en vacuum_tasks (FALSE = Purga la cola al finalizar)
);

```

**Salida esperada**
```
INFO:  =========================================================
INFO:  [DBA SQUAD] INICIANDO ORQUESTADOR VACUUM VANGUARD
INFO:  ALCANCE: SMART_USER | PERFIL: BALANCED | HILOS: 4 | CUTOFF: SIN LIMITE | HISTORIAL: t
INFO:  =========================================================
INFO:  ---------------------------------------------------------
INFO:  [✓] ORQUESTACION FINALIZADA. Job 16 | Tablas procesadas: 0 / 0 (Sistema optimo)
INFO:  Tiempo Total: 00:00:00.006706
INFO:  =========================================================
CALL
```



### Revisar los porcentajes de tuplas muertas
```
SELECT
    schemaname,
    relname AS nombre_tabla,
    n_live_tup AS filas_vivas,
    n_dead_tup AS filas_muertas,
    n_mod_since_analyze AS filas_modificadas,
    ROUND(COALESCE((n_dead_tup::numeric / NULLIF(n_live_tup + n_dead_tup, 0)) * 100, 0.00), 2) as porc_tuplas_muertas_vacuum,
    ROUND((n_mod_since_analyze::numeric / NULLIF(n_live_tup, 0)) * 100, 2) AS change_pct_analyze
FROM pg_stat_user_tables
WHERE     schemaname  = 'lab' and relname in('demo_extreme_bloat','demo_heavy_updates','demo_vip_facturas','demo_escudo_historial')
ORDER BY porc_tuplas_muertas_vacuum DESC NULLS LAST;
```

**Salida esperada**
```
 schemaname |     nombre_tabla      | filas_vivas | filas_muertas | filas_modificadas | porc_tuplas_muertas_vacuum | change_pct_analyze 
------------+-----------------------+-------------+---------------+-------------------+----------------------------+--------------------
 lab        | demo_heavy_updates    |      200000 |        400000 |            400000 |                      66.67 |             200.00
 lab        | demo_vip_facturas     |      100000 |          9999 |             59999 |                       9.09 |              60.00
 lab        | demo_extreme_bloat    |       50000 |             0 |            950000 |                       0.00 |            1900.00
 lab        | demo_escudo_historial |       50001 |             0 |            149999 |                       0.00 |             299.99
(4 rows)
```

#### Escenario : Cambiaremos el filtro de vacuum a analyze
al hacer esto ya nos permitira hacer vacuum a esa tabla demo_heavy_updates . 

```SQL
update maint.filters set maintenance_action = 'ANALYZE' where table_name = 'demo_heavy_updates';
-- UPDATE 1
```

**Salida esperada**
```SQL
select * from  maint.filters ;
 filter_id | schema_name |     table_name     | maintenance_action | is_ignored | force_maintenance |          created_at           |          updated_at           | updated_by 
-----------+-------------+--------------------+--------------------+------------+-------------------+-------------------------------+-------------------------------+------------
         1 | lab         | demo_heavy_updates | ANALYZE            | t          | f                 | 2026-08-24 23:50:54.445692+00 | 2026-08-24 23:50:54.445692+00 | postgres2
         2 | lab         | demo_extreme_bloat | VACUUM             | f          | t                 | 2026-08-24 23:50:54.445931+00 | 2026-08-24 23:50:54.445931+00 | postgres2
(2 rows)
```

### Ejecutamos el ultimo mantenimiento 
```SQL
CALL maint.sp_orchestrate_vacuum(
    p_scope          => 'SMART_USER',  -- VARCHAR : Alcance ('SMART_USER', 'ALL_USER', 'CUSTOM_LIST', 'SMART_SYSTEM_USER', 'ALL_SYSTEM_USER', 'ALL_SYSTEM')
    p_profile        => 'BALANCED',    -- VARCHAR : Perfil de vacuum ('LIGHT', 'BALANCED', 'AGGRESSIVE')
    p_parallel_workers => 4,           -- INT     : Cantidad máxima de hilos/workers asíncronos en paralelo
    p_cutoff_time    => NULL,          -- TIME    : Freno de emergencia / Kill-Switch por hora límite (ej. '06:00:00'::TIME; NULL = sin límite)
    p_verbose        => TRUE,          -- BOOLEAN : Diagnóstico visual en tiempo real en consola (TRUE/FALSE)
    p_threshold_pct  => 5,          -- NUMERIC : Umbral de porcentaje mínimo de tuplas muertas (5.00 = 5% de muertas)
    p_min_dead_rows   => 10000,          -- INT     : Cantidad mínima de tuplas muertas para evaluar (Filtro anti-morralla)
    p_force_dead_rows => 40000,         -- INT     : Fuerza la entrada si la tabla supera esta cantidad de tuplas muertas (NULL para desactivar)
    p_keep_history   => TRUE           -- BOOLEAN : Retención de auditoría en vacuum_tasks (FALSE = Purga la cola al finalizar)
);
```
**Salida esperada**
```SQL
INFO:  =========================================================
INFO:  [DBA SQUAD] INICIANDO ORQUESTADOR VACUUM VANGUARD
INFO:  ALCANCE: SMART_USER | PERFIL: BALANCED | HILOS: 4 | CUTOFF: SIN LIMITE | HISTORIAL: t
INFO:  =========================================================
INFO:      [>] LANZANDO [BALANCED] PID 859442 -> lab.demo_heavy_updates
INFO:      [✓] EXITO -> lab.demo_heavy_updates
INFO:  ---------------------------------------------------------
INFO:  [✓] ORQUESTACION FINALIZADA. Job 17 | Tablas procesadas: 1 / 1
INFO:  Tiempo Total: 00:00:01.015611
INFO:  =========================================================
CALL
```

### Validamos las tuplas muertas
```SQL
SELECT
    schemaname,
    relname AS nombre_tabla,
    n_live_tup AS filas_vivas,
    n_dead_tup AS filas_muertas,
    n_mod_since_analyze AS filas_modificadas,
    ROUND(COALESCE((n_dead_tup::numeric / NULLIF(n_live_tup + n_dead_tup, 0)) * 100, 0.00), 2) as porc_tuplas_muertas_vacuum,
    ROUND((n_mod_since_analyze::numeric / NULLIF(n_live_tup, 0)) * 100, 2) AS change_pct_analyze
FROM pg_stat_user_tables
WHERE     schemaname  = 'lab' and relname in('demo_extreme_bloat','demo_heavy_updates','demo_vip_facturas','demo_escudo_historial')
ORDER BY porc_tuplas_muertas_vacuum DESC NULLS LAST;
```

**Salida esperada**
```
 schemaname |     nombre_tabla      | filas_vivas | filas_muertas | filas_modificadas | porc_tuplas_muertas_vacuum | change_pct_analyze 
------------+-----------------------+-------------+---------------+-------------------+----------------------------+--------------------
 lab        | demo_vip_facturas     |      100000 |          9999 |             59999 |                       9.09 |              60.00
 lab        | demo_extreme_bloat    |       50000 |             0 |            950000 |                       0.00 |            1900.00
 lab        | demo_heavy_updates    |      200000 |             0 |            400000 |                       0.00 |             200.00
 lab        | demo_escudo_historial |       50001 |             0 |            149999 |                       0.00 |             299.99
(4 rows)
```




-------




# Escenario 4: Revisamos las tablas de bitacora
```sql
select
 job_id,
 job_type,
 maintenance_action,
 orchestrator_pid,
 status,
 tables_processed,
 started_at,
 ended_at
FROM maint.jobs where started_at::date = current_date order by job_id;
```

**Salida esperada**
```sql
 job_id |      job_type       | maintenance_action | orchestrator_pid |  status   | tables_processed |          started_at           |           ended_at            
--------+---------------------+--------------------+------------------+-----------+------------------+-------------------------------+-------------------------------
     14 | SMART_USER_BALANCED | VACUUM             |           855252 | COMPLETED |                1 | 2026-08-25 16:52:35.453886+00 | 2026-08-25 16:52:36.468628+00
     15 | SMART_USER_BALANCED | VACUUM             |           855252 | COMPLETED |                1 | 2026-08-25 17:13:43.485141+00 | 2026-08-25 17:13:44.498766+00
     16 | SMART_USER_BALANCED | VACUUM             |           855252 | COMPLETED |                0 | 2026-08-25 17:18:54.430487+00 | 2026-08-25 17:18:54.435994+00
     17 | SMART_USER_BALANCED | VACUUM             |           855252 | COMPLETED |                1 | 2026-08-25 17:22:27.681069+00 | 2026-08-25 17:22:28.69433+00
```

# Validaremos el detalle de cada proceso ejecutado 
Aqui revisaremos la tabla que se le aplico mantenimiento, la hora inicio y fin, el estatus y mas.
```
select * FROM maint.vacuum_tasks  where  job_id = 17 
```

**Salida esperada**
```
 task_id | job_id | schema_name |     table_name     | n_live_tup | n_dead_tup | dead_pct | status  | child_pid |          started_at           |           ended_at            | error_log 
---------+--------+-------------+--------------------+------------+------------+----------+---------+-----------+-------------------------------+-------------------------------+-----------
      14 |     17 | lab         | demo_heavy_updates |     200000 |     400000 |    66.67 | SUCCESS |    859442 | 2026-08-25 17:22:27.687482+00 | 2026-08-25 17:22:28.692742+00 | 
```
---

 

---

### 📊 FASE 3: EL TABLERO DE MANDO (DASHBOARD C-LEVEL)

> **Discurso de cierre:** *"Señores, la ingeniería de fondo es compleja, pero la visibilidad directiva debe ser inmediata. Este es el Dashboard que sus gerentes de TI verán cada mañana. Control absoluto, cero cajas negras."*

```sql
SELECT 
    j.job_id AS "ID Job",
    j.job_type AS "Perfil Estratégico",
    j.status AS "Estado Final",
    --j.parallel_workers AS "Hilos",
    j.tables_processed AS "Éxitos",
    COUNT(t.task_id) AS "Total Evaluadas",
    SUM(CASE WHEN t.status = 'FAILED' THEN 1 ELSE 0 END) AS "Errores",
    ROUND(EXTRACT(EPOCH FROM (j.ended_at - j.started_at))::numeric, 2) || ' seg' AS "Duración",
    j.started_at::TIME(0) AS "Hora Inicio"
FROM maint.jobs j
LEFT JOIN maint.vacuum_tasks t ON j.job_id = t.job_id
GROUP BY j.job_id, j.job_type, j.status,   j.tables_processed, j.started_at, j.ended_at
ORDER BY j.job_id DESC;
```
**Salida esperada**
```
  ID Job | Perfil Estratégico  | Estado Final | Éxitos | Total Evaluadas | Errores | Duración | Hora Inicio 
--------+---------------------+--------------+--------+-----------------+---------+----------+-------------
     17 | SMART_USER_BALANCED | COMPLETED    |      1 |               1 |       0 | 1.01 seg | 17:22:28
     16 | SMART_USER_BALANCED | COMPLETED    |      0 |               0 |       0 | 0.01 seg | 17:18:54
     15 | SMART_USER_BALANCED | COMPLETED    |      1 |               1 |       0 | 1.01 seg | 17:13:43
     14 | SMART_USER_BALANCED | COMPLETED    |      1 |               1 |       0 | 1.01 seg | 16:52:35
     13 | SMART_USER_BALANCED | COMPLETED    |      0 |               0 |       0 | 0.00 seg | 16:51:59
     12 | SMART_USER_BALANCED | COMPLETED    |      0 |               0 |       0 | 0.01 seg | 16:49:43
     11 | SMART_USER_BALANCED | COMPLETED    |      1 |               1 |       0 | 1.02 seg | 16:47:40
     10 | SMART_USER_BALANCED | COMPLETED    |      0 |               0 |       0 | 0.01 seg | 01:49:13
      9 | SMART_USER_BALANCED | COMPLETED    |      1 |               1 |       0 | 1.02 seg | 01:28:36
      8 | SMART_USER_BALANCED | COMPLETED    |      1 |               1 |       0 | 1.02 seg | 01:27:58
      7 | SMART_USER_BALANCED | COMPLETED    |      1 |               1 |       0 | 1.02 seg | 01:27:32
      6 | SMART_USER_BALANCED | COMPLETED    |      1 |               1 |       0 | 1.02 seg | 01:21:44
      5 | SMART_USER_BALANCED | COMPLETED    |      1 |               1 |       0 | 1.02 seg | 00:35:51
      4 | SMART_USER_BALANCED | COMPLETED    |      5 |               5 |       0 | 2.04 seg | 23:53:29
      3 | SMART_USER_NORMAL   | COMPLETED    |      1 |               0 |       0 | 1.02 seg | 21:58:35
      2 | SMART_USER_NORMAL   | COMPLETED    |      1 |               0 |       0 | 1.02 seg | 21:57:46
      1 | SMART_USER_NORMAL   | COMPLETED    |      2 |               0 |       0 | 1.02 seg | 21:56:55
```

###   Querys extras:

```sql

select * FROM maint.jobs limit 10 ;
select * FROM maint.vacuum_tasks limit 10 ;


SELECT 
    relname AS tabla, 
    oid, 
    relfilenode 
FROM 
    pg_class 
WHERE 
    relname in( 'demo_clientes_bloat','demo_vip_facturas','demo_escudo_historial');

```

