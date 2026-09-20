
### FASE 1: WAR GAMES (GENERACIÓN MASIVA DE TRÁFICO Y BLOAT REAL)

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
-- 4. CONFIGURACIÓN DEL PANEL DE SEGURIDAD V4.1.0 (FILTROS CON TRES TIPOS DE REGLA)
-- ====================================================================================
INSERT INTO maint.filters (
    schema_name, 
    table_name, 
    maintenance_action, 
    filter_type, 
    action_params
) VALUES 
-- 1. [ESCUDO ACTIVO (Regla 1)]: Exclusión Absoluta. Ignora la tabla totalmente en TODOS los scopes.
('lab', 'demo_heavy_updates', 'VACUUM', 'EXCLUDE', NULL),

-- 2. [PASE VIP / LISTA BLANCA (Regla 2)]: Fuerza Bruta. Mantenimiento prioritario inmediato.
('lab', 'demo_extreme_bloat', 'VACUUM', 'FORCE', NULL),

-- 3. [PARÁMETROS PERSONALIZADOS JSONB (Regla 3)]: Evaluación Dinámica por Umbral y Fuerza Bruta JSONB.
-- Sobrescribe umbrales globales e incluye parámetros de fuerza bruta dentro del mismo objeto JSONB.
('lab', 'demo_custom_table', 'VACUUM', 'CUSTOM', '{"threshold_pct": 70.00, "min_dead_tuples": 5000, "force_dead_tuples": 9999}'::jsonb);

```

---

### Revisamos los filtros aplicados

En este caso se bloqueo el vacuum de la tabla demo_heavy_updates ya que esta en true la columna is_ignored

```text
select schema_name,table_name,maintenance_action,filter_type ,action_params from  maint.filters ;
 schema_name |     table_name     | maintenance_action | filter_type |                                action_params                                 
-------------+--------------------+--------------------+-------------+------------------------------------------------------------------------------
 lab         | demo_heavy_updates | VACUUM             | EXCLUDE     | 
 lab         | demo_extreme_bloat | VACUUM             | FORCE       | 
 lab         | demo_vip_facturas  | VACUUM             | CUSTOM      | {"threshold_pct": 70.00, "min_dead_tuples": 5000, "force_dead_tuples": 9999}
(3 rows)
```

### Revisar los porcentajes de tuplas muertas

```sql
SELECT
    schemaname,
    relname AS nombre_tabla,
    n_live_tup AS filas_vivas,
    n_dead_tup AS filas_muertas,
    n_mod_since_analyze AS filas_modificadas,
    ROUND(COALESCE((n_dead_tup::numeric / NULLIF(n_live_tup + n_dead_tup, 0)) * 100, 0.00), 2) as porc_tuplas_muertas_vacuum,
    ROUND((n_mod_since_analyze::numeric / NULLIF(n_live_tup, 0)) * 100, 2) AS change_pct_analyze
FROM pg_stat_user_tables
WHERE      schemaname  = 'lab' and relname in('demo_extreme_bloat','demo_heavy_updates','demo_vip_facturas','demo_escudo_historial')
ORDER BY porc_tuplas_muertas_vacuum DESC NULLS LAST;

```

**Salida esperada**

```text
 schemaname |      nombre_tabla      | filas_vivas | filas_muertas | filas_modificadas | porc_tuplas_muertas_vacuum | change_pct_analyze 
------------+-----------------------+-------------+---------------+-------------------+----------------------------+--------------------
 lab        | demo_extreme_bloat    |       50000 |        450000 |            950000 |                      90.00 |            1900.00
 lab        | demo_heavy_updates    |      200000 |        400000 |            400000 |                      66.67 |             200.00
 lab        | demo_escudo_historial |      100002 |         49999 |            149999 |                      33.33 |             150.00
 lab        | demo_vip_facturas     |      100000 |          9999 |             59999 |                       9.09 |              60.00

```





# Escenario 1: Mantenimiento Diario Inteligente
aqui demo_extreme_bloat esta forzada por eso se hace y demo_extreme_bloat cumplio con la condicion de maint.filters el cual decia que se forza si tiene 9999 de tuplas muertas


```sql
CALL maint.sp_orchestrate_vacuum(
    p_scope          => 'CUSTOM_LIST',  -- VARCHAR : Alcance ('SMART_USER', 'ALL_USER', 'CUSTOM_LIST', 'SMART_SYSTEM_USER', 'ALL_SYSTEM_USER', 'ALL_SYSTEM')
    p_profile        => 'BALANCED',    -- VARCHAR : Perfil de vacuum ('LIGHT', 'BALANCED', 'AGGRESSIVE')
    p_parallel_workers => 4,           -- INT     : Cantidad máxima de hilos/workers asíncronos en paralelo
    p_cutoff_time    => NULL,          -- TIME    : Freno de emergencia / Kill-Switch por hora límite (ej. '06:00:00'::TIME; NULL = sin límite)
    p_verbose        => TRUE,          -- BOOLEAN : Diagnóstico visual en tiempo real en consola (TRUE/FALSE)
    p_threshold_pct  => 60,          -- NUMERIC : Umbral de porcentaje mínimo de tuplas muertas (5.00 = 5% de muertas)
    p_min_dead_tuples   => 5000,          -- INT     : Cantidad mínima de tuplas muertas para evaluar (Filtro anti-morralla)
    p_force_dead_tuples => 50000,         -- INT     : Fuerza la entrada si la tabla supera esta cantidad de tuplas muertas (NULL para desactivar)
    p_keep_history   => TRUE           -- BOOLEAN : Retención de auditoría en vacuum_tasks (FALSE = Purga la cola al finalizar)
);
```

**Salida esperada**

```text
INFO:  =========================================================
INFO:  [DBA SQUAD] INICIANDO ORQUESTADOR VACUUM VANGUARD (V4.1.0 HOMOLOGADO - EXT: 1.4)
INFO:  ALCANCE: CUSTOM_LIST | PERFIL: BALANCED | HILOS: 4 | CUTOFF: SIN LIMITE | HISTORIAL: t
INFO:  =========================================================
INFO:      [>] LANZANDO [BALANCED] PID 2337116 -> lab.demo_vip_facturas
INFO:      [>] LANZANDO [BALANCED] PID 2337117 -> lab.demo_extreme_bloat
INFO:      [✓] SUCCESS -> lab.demo_vip_facturas
INFO:      [✓] SUCCESS -> lab.demo_extreme_bloat
INFO:  ---------------------------------------------------------
INFO:  [✓] ORQUESTACION FINALIZADA. Job 18 | Tablas procesadas: 2 / 2
INFO:  Tiempo Total: 00:00:01.026781
INFO:  =========================================================
CALL

```

---

### Revisar los porcentajes de tuplas muertas

```sql
SELECT
    schemaname,
    relname AS nombre_tabla,
    n_live_tup AS filas_vivas,
    n_dead_tup AS filas_muertas,
    n_mod_since_analyze AS filas_modificadas,
    ROUND(COALESCE((n_dead_tup::numeric / NULLIF(n_live_tup + n_dead_tup, 0)) * 100, 0.00), 2) as porc_tuplas_muertas_vacuum,
    ROUND((n_mod_since_analyze::numeric / NULLIF(n_live_tup, 0)) * 100, 2) AS change_pct_analyze
FROM pg_stat_user_tables
WHERE      schemaname  = 'lab' and relname in('demo_extreme_bloat','demo_heavy_updates','demo_vip_facturas','demo_escudo_historial')
ORDER BY porc_tuplas_muertas_vacuum DESC NULLS LAST;

```

**Salida esperada**

```text
 schemaname |     nombre_tabla      | filas_vivas | filas_muertas | filas_modificadas | porc_tuplas_muertas_vacuum | change_pct_analyze 
------------+-----------------------+-------------+---------------+-------------------+----------------------------+--------------------
 lab        | demo_heavy_updates    |      200000 |        400000 |            400000 |                      66.67 |             200.00
 lab        | demo_escudo_historial |      100002 |         49999 |            149999 |                      33.33 |             150.00
 lab        | demo_extreme_bloat    |       50000 |             0 |            950000 |                       0.00 |            1900.00
 lab        | demo_vip_facturas     |       50000 |             0 |             59999 |                       0.00 |             120.00
(4 rows)
```




# Escenario 1: Mantenimiento Diario Inteligente

 

```sql

Ahora excluimos la tabla forzada para que no salga mas.
update maint.filters set filter_type = 'EXCLUDE' where table_name = 'demo_extreme_bloat';


CALL maint.sp_orchestrate_vacuum(
    p_scope          => 'SMART_USER',  -- VARCHAR : Alcance ('SMART_USER', 'ALL_USER', 'CUSTOM_LIST', 'SMART_SYSTEM_USER', 'ALL_SYSTEM_USER', 'ALL_SYSTEM')
    p_profile        => 'BALANCED',    -- VARCHAR : Perfil de vacuum ('LIGHT', 'BALANCED', 'AGGRESSIVE')
    p_parallel_workers => 4,           -- INT     : Cantidad máxima de hilos/workers asíncronos en paralelo
    p_cutoff_time    => NULL,          -- TIME    : Freno de emergencia / Kill-Switch por hora límite (ej. '06:00:00'::TIME; NULL = sin límite)
    p_verbose        => TRUE,          -- BOOLEAN : Diagnóstico visual en tiempo real en consola (TRUE/FALSE)
    p_threshold_pct  => 30,          -- NUMERIC : Umbral de porcentaje mínimo de tuplas muertas (5.00 = 5% de muertas)
    p_min_dead_tuples   => 49999,          -- INT     : Cantidad mínima de tuplas muertas para evaluar (Filtro anti-morralla)
    p_force_dead_tuples => 50000,         -- INT     : Fuerza la entrada si la tabla supera esta cantidad de tuplas muertas (NULL para desactivar)
    p_keep_history   => TRUE           -- BOOLEAN : Retención de auditoría en vacuum_tasks (FALSE = Purga la cola al finalizar)
);

 

```

**Salida esperada**

```text
INFO:  =========================================================
INFO:  [DBA SQUAD] INICIANDO ORQUESTADOR VACUUM VANGUARD (V4.1.0 HOMOLOGADO - EXT: 1.4)
INFO:  ALCANCE: SMART_USER | PERFIL: BALANCED | HILOS: 4 | CUTOFF: SIN LIMITE | HISTORIAL: t
INFO:  =========================================================
INFO:      [>] LANZANDO [BALANCED] PID 2337750 -> lab.demo_escudo_historial
INFO:      [✓] SUCCESS -> lab.demo_escudo_historial
INFO:  ---------------------------------------------------------
INFO:  [✓] ORQUESTACION FINALIZADA. Job 19 | Tablas procesadas: 1 / 1
INFO:  Tiempo Total: 00:00:01.016945
INFO:  =========================================================
CALL
```

### Revisar los porcentajes de tuplas muertas

```sql
SELECT
    schemaname,
    relname AS nombre_tabla,
    n_live_tup AS filas_vivas,
    n_dead_tup AS filas_muertas,
    n_mod_since_analyze AS filas_modificadas,
    ROUND(COALESCE((n_dead_tup::numeric / NULLIF(n_live_tup + n_dead_tup, 0)) * 100, 0.00), 2) as porc_tuplas_muertas_vacuum,
    ROUND((n_mod_since_analyze::numeric / NULLIF(n_live_tup, 0)) * 100, 2) AS change_pct_analyze
FROM pg_stat_user_tables
WHERE      schemaname  = 'lab' and relname in('demo_extreme_bloat','demo_heavy_updates','demo_vip_facturas','demo_escudo_historial')
ORDER BY porc_tuplas_muertas_vacuum DESC NULLS LAST;

```

**Salida esperada**

```text
 schemaname |     nombre_tabla      | filas_vivas | filas_muertas | filas_modificadas | porc_tuplas_muertas_vacuum | change_pct_analyze 
------------+-----------------------+-------------+---------------+-------------------+----------------------------+--------------------
 lab        | demo_heavy_updates    |      200000 |        400000 |            400000 |                      66.67 |             200.00
 lab        | demo_extreme_bloat    |       50000 |             0 |            950000 |                       0.00 |            1900.00
 lab        | demo_vip_facturas     |       50000 |             0 |             59999 |                       0.00 |             120.00
 lab        | demo_escudo_historial |       50001 |             0 |            149999 |                       0.00 |             299.99
(4 rows)
```

# Escenario 2 : Mantenimiento modificando el p_force_dead_tuples a 40000



```sql
-- la tabla demo_heavy_updates antes estaba forzada, ahora la colocamos en custom o lo podemos tambien eliminar, y como no se configuro el action_params
-- entonces este se toma de los valores por default del orquestador
update maint.filters set filter_type= 'CUSTOM' where table_name ='demo_heavy_updates';

CALL maint.sp_orchestrate_vacuum(
    p_scope          => 'SMART_USER',  -- VARCHAR : Alcance ('SMART_USER', 'ALL_USER', 'CUSTOM_LIST', 'SMART_SYSTEM_USER', 'ALL_SYSTEM_USER', 'ALL_SYSTEM')
    p_profile        => 'BALANCED',    -- VARCHAR : Perfil de vacuum ('LIGHT', 'BALANCED', 'AGGRESSIVE')
    p_parallel_workers => 4,           -- INT     : Cantidad máxima de hilos/workers asíncronos en paralelo
    p_cutoff_time    => NULL,          -- TIME    : Freno de emergencia / Kill-Switch por hora límite (ej. '06:00:00'::TIME; NULL = sin límite)
    p_verbose        => TRUE,          -- BOOLEAN : Diagnóstico visual en tiempo real en consola (TRUE/FALSE)
    p_threshold_pct  => 70,          -- NUMERIC : Umbral de porcentaje mínimo de tuplas muertas (5.00 = 5% de muertas)
    p_min_dead_tuples   => 5000,          -- INT     : Cantidad mínima de tuplas muertas para evaluar (Filtro anti-morralla)
    p_force_dead_tuples => 400000,         -- INT     : Fuerza la entrada si la tabla supera esta cantidad de tuplas muertas (NULL para desactivar)
    p_keep_history   => TRUE           -- BOOLEAN : Retención de auditoría en vacuum_tasks (FALSE = Purga la cola al finalizar)
);
```

**Salida esperada**

```text
INFO:  =========================================================
INFO:  [DBA SQUAD] INICIANDO ORQUESTADOR VACUUM VANGUARD (V4.1.0 HOMOLOGADO - EXT: 1.4)
INFO:  ALCANCE: SMART_USER | PERFIL: BALANCED | HILOS: 4 | CUTOFF: SIN LIMITE | HISTORIAL: t
INFO:  =========================================================
INFO:      [>] LANZANDO [BALANCED] PID 2338239 -> lab.demo_heavy_updates
INFO:      [✓] SUCCESS -> lab.demo_heavy_updates
INFO:  ---------------------------------------------------------
INFO:  [✓] ORQUESTACION FINALIZADA. Job 21 | Tablas procesadas: 1 / 1
INFO:  Tiempo Total: 00:00:01.015826
INFO:  =========================================================
CALL
```

### Revisar los porcentajes de tuplas muertas

```sql
SELECT
    schemaname,
    relname AS nombre_tabla,
    n_live_tup AS filas_vivas,
    n_dead_tup AS filas_muertas,
    n_mod_since_analyze AS filas_modificadas,
    ROUND(COALESCE((n_dead_tup::numeric / NULLIF(n_live_tup + n_dead_tup, 0)) * 100, 0.00), 2) as porc_tuplas_muertas_vacuum,
    ROUND((n_mod_since_analyze::numeric / NULLIF(n_live_tup, 0)) * 100, 2) AS change_pct_analyze
FROM pg_stat_user_tables
WHERE      schemaname  = 'lab' and relname in('demo_extreme_bloat','demo_heavy_updates','demo_vip_facturas','demo_escudo_historial')
ORDER BY porc_tuplas_muertas_vacuum DESC NULLS LAST;

```

**Salida esperada**

```text
 schemaname |     nombre_tabla      | filas_vivas | filas_muertas | filas_modificadas | porc_tuplas_muertas_vacuum | change_pct_analyze 
------------+-----------------------+-------------+---------------+-------------------+----------------------------+--------------------
 lab        | demo_extreme_bloat    |       50000 |             0 |            950000 |                       0.00 |            1900.00
 lab        | demo_heavy_updates    |      200000 |             0 |            400000 |                       0.00 |             200.00
 lab        | demo_vip_facturas     |       50000 |             0 |             59999 |                       0.00 |             120.00
 lab        | demo_escudo_historial |       50001 |             0 |            149999 |                       0.00 |             299.99
(4 rows)
```



---

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
FROM maint.jobs where started_at::date = current_date and maintenance_action = 'VACUUM' order by job_id limit 2;

```

**Salida esperada**

```sql
 job_id |       job_type       | maintenance_action | orchestrator_pid |  status   | tables_processed |          started_at           |           ended_at            
--------+----------------------+--------------------+------------------+-----------+------------------+-------------------------------+-------------------------------
     12 | CUSTOM_LIST_BALANCED | VACUUM             |          2322100 | COMPLETED |                1 | 2026-09-20 14:53:25.321376-07 | 2026-09-20 14:53:26.338042-07
     13 | CUSTOM_LIST_BALANCED | VACUUM             |          2322100 | COMPLETED |                1 | 2026-09-20 14:54:04.185718-07 | 2026-09-20 14:54:05.198631-07
(2 rows)
```

# Validaremos el detalle de cada proceso ejecutado

Aqui revisaremos la tabla que se le aplico mantenimiento, la hora inicio y fin, el estatus y mas.

```sql
select * FROM maint.vacuum_tasks  where  job_id = 12 ;

```

**Salida esperada**

```text
 task_id | job_id | schema_name |     table_name     | n_live_tup | n_dead_tup | dead_tuples_pct | status  | child_pid | child_cookie |          started_at           |           ended_at           | error_log 
---------+--------+-------------+--------------------+------------+------------+-----------------+---------+-----------+--------------+-------------------------------+------------------------------+-----------
       1 |     12 | lab         | demo_extreme_bloat |      50000 |     450000 |           90.00 | SUCCESS |   2335476 |              | 2026-09-20 14:53:25.327911-07 | 2026-09-20 14:53:26.33543-07 | 
(1 row)
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

```text
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

# Escenario 5: Simular una interrrupción en el orquetador y se quedo con status RUNNING

Aqui simulamos un orquestador caido y que el  PID no esta en la vista pg_stat_activity,  pero resulto que el unico proceso hijo que alcanzo ejecutar ya estaba en  SUCCESS
por lo que el orquestador se coloca con estatus abortado y huerfano

```sql
update maint.jobs set status = 'RUNNING'  where job_id = 17 ;
-- UPDATE 1

```

### Revisamos las tablas

```sql
select * FROM maint.jobs where started_at::date = current_date and    job_id = 17  ;
select * FROM maint.vacuum_tasks  where  job_id = 17 ;

```

**Salida esperada**

```text
-[ RECORD 1 ]------+-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
job_id             | 17
job_type           | SMART_USER_BALANCED
maintenance_action | VACUUM
orchestrator_pid   | 855252
execution_params   | {"scope": "SMART_USER", "profile": "BALANCED", "cutoff_time": null, "keep_history": true, "threshold_pct": 5, "parallel_workers": 4, "min_dead_tuples": 10000, "force_dead_tuples": 40000}
status             | RUNNING
tables_processed   | 1
started_at         | 2026-08-25 17:22:27.681069+00
ended_at           | 2026-08-25 19:19:27.853279+00

-[ RECORD 1 ]------------------------------
task_id         | 14
job_id          | 17
schema_name     | lab
table_name      | demo_heavy_updates
n_live_tup      | 200000
n_dead_tup      | 400000
dead_tuples_pct | 66.67
status          | SUCCESS
child_pid       | 859442
started_at      | 2026-08-25 17:22:27.687482+00
ended_at        | 2026-08-25 17:22:28.692742+00
error_log       | 

```

### Ejecutamos un mantenimiento

```sql
 
 CALL maint.sp_orchestrate_vacuum(
    p_scope          => 'SMART_USER',  -- VARCHAR : Alcance ('SMART_USER', 'ALL_USER', 'CUSTOM_LIST', 'SMART_SYSTEM_USER', 'ALL_SYSTEM_USER', 'ALL_SYSTEM')
    p_profile        => 'BALANCED',    -- VARCHAR : Perfil de vacuum ('LIGHT', 'BALANCED', 'AGGRESSIVE')
    p_parallel_workers => 4,           -- INT     : Cantidad máxima de hilos/workers asíncronos en paralelo
    p_cutoff_time    => NULL,          -- TIME    : Freno de emergencia / Kill-Switch por hora límite (ej. '06:00:00'::TIME; NULL = sin límite)
    p_verbose        => TRUE,          -- BOOLEAN : Diagnóstico visual en tiempo real en consola (TRUE/FALSE)
    p_threshold_pct  => 5,          -- NUMERIC : Umbral de porcentaje mínimo de tuplas muertas (5.00 = 5% de muertas)
    p_min_dead_tuples   => 100,          -- INT     : Cantidad mínima de tuplas muertas para evaluar (Filtro anti-morralla)
    p_force_dead_tuples => 1000,         -- INT     : Fuerza la entrada si la tabla supera esta cantidad de tuplas muertas (NULL para desactivar)
    p_keep_history   => TRUE           -- BOOLEAN : Retención de auditoría en vacuum_tasks (FALSE = Purga la cola al finalizar)
);

```

**Salida esperada**

```text
NOTICE:  [SELF-HEALING] Job 17 detectado como huérfano. Estado actualizado a ABORTED_ORPHAN.
NOTICE:  [SELF-HEALING] Se auto-sanaron y cerraron 1 trabajo(s) huérfano(s) en maint.jobs.
INFO:  =========================================================
INFO:  [DBA SQUAD] INICIANDO ORQUESTADOR VACUUM VANGUARD
INFO:  ALCANCE: SMART_USER | PERFIL: BALANCED | HILOS: 4 | CUTOFF: SIN LIMITE | HISTORIAL: t
INFO:  =========================================================
INFO:  ---------------------------------------------------------
INFO:  [✓] ORQUESTACION FINALIZADA. Job 26 | Tablas procesadas: 0 / 0 (Sistema optimo)
INFO:  Tiempo Total: 00:00:00.010539
INFO:  =========================================================
CALL

```

```sql
select * FROM maint.jobs where started_at::date = current_date and    job_id = 17  ;
select * FROM maint.vacuum_tasks  where  job_id = 17 ;

```

**Salida esperada**

```text
-[ RECORD 1 ]------+-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
job_id             | 17
job_type           | SMART_USER_BALANCED
maintenance_action | VACUUM
orchestrator_pid   | 855252
execution_params   | {"scope": "SMART_USER", "profile": "BALANCED", "cutoff_time": null, "keep_history": true, "threshold_pct": 5, "parallel_workers": 4, "min_dead_tuples": 10000, "force_dead_tuples": 40000}
status             | ABORTED_ORPHAN
tables_processed   | 1
started_at         | 2026-08-25 17:22:27.681069+00
ended_at           | 2026-08-25 19:21:27.582986+00

-[ RECORD 1 ]------------------------------
task_id         | 14
job_id          | 17
schema_name     | lab
table_name      | demo_heavy_updates
n_live_tup      | 200000
n_dead_tup      | 400000
dead_tuples_pct | 66.67
status          | SUCCESS
child_pid       | 859442
started_at      | 2026-08-25 17:22:27.687482+00
ended_at        | 2026-08-25 17:22:28.692742+00
error_log       | 

```

---

# Escenario 6: Simular una interrrupción en el orquetador y hijos

Aqui simulamos un orquestador y hijo caido y  que el  PID no esta en la vista pg_stat_activity,  los dos se quedan con estatus RUNNING,
y se coloca con estatus abortado y huerfano

```sql
update maint.jobs set status = 'RUNNING'  where job_id = 17 ;
update maint.vacuum_tasks set status = 'RUNNING' where  job_id = 17 ;

```

### Revisamos las tablas

```sql
select * FROM maint.jobs where started_at::date = current_date and    job_id = 17  ;
select * FROM maint.vacuum_tasks  where  job_id = 17 ;

```

**Salida esperada**

```text
-[ RECORD 1 ]------+-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
job_id             | 17
job_type           | SMART_USER_BALANCED
maintenance_action | VACUUM
orchestrator_pid   | 855252
execution_params   | {"scope": "SMART_USER", "profile": "BALANCED", "cutoff_time": null, "keep_history": true, "threshold_pct": 5, "parallel_workers": 4, "min_dead_tuples": 10000, "force_dead_tuples": 40000}
status             | RUNNING
tables_processed   | 1
started_at         | 2026-08-25 17:22:27.681069+00
ended_at           | 2026-08-25 19:21:27.582986+00

-[ RECORD 1 ]------------------------------
task_id         | 14
job_id          | 17
schema_name     | lab
table_name      | demo_heavy_updates
n_live_tup      | 200000
n_dead_tup      | 400000
dead_tuples_pct | 66.67
status          | RUNNING
child_pid       | 859442
started_at      | 2026-08-25 17:22:27.687482+00
ended_at        | 2026-08-25 17:22:28.692742+00
error_log       | 

```

### Ejecutamos un mantenimiento

```sql
 
 CALL maint.sp_orchestrate_vacuum(
    p_scope          => 'SMART_USER',  -- VARCHAR : Alcance ('SMART_USER', 'ALL_USER', 'CUSTOM_LIST', 'SMART_SYSTEM_USER', 'ALL_SYSTEM_USER', 'ALL_SYSTEM')
    p_profile        => 'BALANCED',    -- VARCHAR : Perfil de vacuum ('LIGHT', 'BALANCED', 'AGGRESSIVE')
    p_parallel_workers => 4,           -- INT     : Cantidad máxima de hilos/workers asíncronos en paralelo
    p_cutoff_time    => NULL,          -- TIME    : Freno de emergencia / Kill-Switch por hora límite (ej. '06:00:00'::TIME; NULL = sin límite)
    p_verbose        => TRUE,          -- BOOLEAN : Diagnóstico visual en tiempo real en consola (TRUE/FALSE)
    p_threshold_pct  => 5,          -- NUMERIC : Umbral de porcentaje mínimo de tuplas muertas (5.00 = 5% de muertas)
    p_min_dead_tuples   => 100,          -- INT     : Cantidad mínima de tuplas muertas para evaluar (Filtro anti-morralla)
    p_force_dead_tuples => 1000,         -- INT     : Fuerza la entrada si la tabla supera esta cantidad de tuplas muertas (NULL para desactivar)
    p_keep_history   => TRUE           -- BOOLEAN : Retención de auditoría en vacuum_tasks (FALSE = Purga la cola al finalizar)
);

```

**Salida esperada**

```text
NOTICE:  [SELF-HEALING] Job 17 detectado como huérfano. Estado actualizado a ABORTED_ORPHAN.
NOTICE:  [SELF-HEALING] Se auto-sanaron y cerraron 1 trabajo(s) huérfano(s) en maint.jobs.
INFO:  =========================================================
INFO:  [DBA SQUAD] INICIANDO ORQUESTADOR VACUUM VANGUARD
INFO:  ALCANCE: SMART_USER | PERFIL: BALANCED | HILOS: 4 | CUTOFF: SIN LIMITE | HISTORIAL: t
INFO:  =========================================================
INFO:  ---------------------------------------------------------
INFO:  [✓] ORQUESTACION FINALIZADA. Job 27 | Tablas procesadas: 0 / 0 (Sistema optimo)
INFO:  Tiempo Total: 00:00:00.007794
INFO:  =========================================================
CALL

```

```sql
select * FROM maint.jobs where started_at::date = current_date and    job_id = 17  ;
select * FROM maint.vacuum_tasks  where  job_id = 17 ;

```

**Salida esperada**

```text
-[ RECORD 1 ]------+-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
job_id             | 17
job_type           | SMART_USER_BALANCED
maintenance_action | VACUUM
orchestrator_pid   | 855252
execution_params   | {"scope": "SMART_USER", "profile": "BALANCED", "cutoff_time": null, "keep_history": true, "threshold_pct": 5, "parallel_workers": 4, "min_dead_tuples": 10000, "force_dead_tuples": 40000}
status             | ABORTED_ORPHAN
tables_processed   | 0
started_at         | 2026-08-25 17:22:27.681069+00
ended_at           | 2026-08-25 19:31:34.339332+00

-[ RECORD 1 ]---------------------------------------------
task_id         | 14
job_id          | 17
schema_name     | lab
table_name      | demo_heavy_updates
n_live_tup      | 200000
n_dead_tup      | 400000
dead_tuples_pct | 66.67
status          | ABORTED_ORPHAN
child_pid       | 859442
started_at      | 2026-08-25 17:22:27.687482+00
ended_at        | 2026-08-25 19:31:34.339207+00
error_log       | Orchestrator process died or was superseded.

```

---

### Querys extras:

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

