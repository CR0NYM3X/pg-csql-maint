 
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
INSERT INTO maint.filters (schema_name, table_name, is_ignored, force_maintenance) VALUES 
('lab', 'demo_heavy_updates', TRUE, FALSE),  -- [ESCUDO ACTIVO]: Intocable.
('lab', 'demo_extreme_bloat', FALSE, TRUE);      -- [PASE VIP]: Mantenimiento prioritario.

```

---
 

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
WHERE     schemaname  = 'lab'
ORDER BY porc_tuplas_muertas_vacuum DESC NULLS LAST;
```

**Salida esperada**
```
 schemaname |     nombre_tabla      | filas_vivas | filas_muertas | filas_modificadas | porc_tuplas_muertas_vacuum | change_pct_analyze 
------------+-----------------------+-------------+---------------+-------------------+----------------------------+--------------------
 lab        | demo_extreme_bloat    |       50000 |        450000 |            950000 |                      90.00 |            1900.00
 lab        | demo_heavy_updates    |      200000 |        400000 |            400000 |                      66.67 |             200.00
 lab        | demo_escudo_historial |       50001 |         49999 |            149999 |                      50.00 |             299.99
 lab        | demo_vip_facturas     |       50000 |          9999 |             59999 |                      16.67 |             120.00
 lab        | pedidos               |       20000 |          3000 |                 0 |                      13.04 |               0.00
 lab        | inventario            |       20000 |          1200 |              1200 |                       5.66 |               6.00
 lab        | clientes              |       20000 |           400 |               400 |                       1.96 |               2.00
 lab        | carritos              |       10000 |             0 |                 0 |                       0.00 |               0.00
 lab        | sesiones              |       20000 |             0 |                 0 |                       0.00 |               0.00
 lab        | logs_auditoria        |       22000 |             0 |                 0 |                       0.00 |               0.00
 lab        | envios                |       20000 |             0 |                 0 |                       0.00 |               0.00
 lab        | pagos                 |       20000 |             0 |                 0 |                       0.00 |               0.00
 lab        | detalle_pedidos       |       20000 |             0 |                 0 |                       0.00 |               0.00
 lab        | productos             |       20000 |             0 |                 0 |                       0.00 |               0.00
(14 rows)
```




#### Escenario 2: Mantenimiento Diario Inteligente

> **Discurso para el cliente:** *"Es lunes de madrugada. Lanzamos el mantenimiento general. Observen cómo el orquestador detecta automáticamente la tabla con actualizaciones masivas (`demo_heavy_updates`), procesa sus tuplas muertas en segundo plano, pero respeta estrictamente nuestro escudo de seguridad, ignorando por completo la tabla crítica `demo_escudo_historial` a pesar de estar llena de basura."*

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
WHERE     schemaname  = 'lab'
ORDER BY porc_tuplas_muertas_vacuum DESC NULLS LAST;
```

**Salida esperada**
```
 schemaname |     nombre_tabla      | filas_vivas | filas_muertas | filas_modificadas | porc_tuplas_muertas_vacuum | change_pct_analyze 
------------+-----------------------+-------------+---------------+-------------------+----------------------------+--------------------
 lab        | demo_heavy_updates    |      200000 |        400000 |            400000 |                      66.67 |             200.00 --- Esta no se hizo porque cumplia con todo.
 lab        | demo_escudo_historial |       50001 |         49999 |            149999 |                      50.00 |             299.99
 lab        | demo_vip_facturas     |       50000 |          9999 |             59999 |                      16.67 |             120.00
 lab        | pedidos               |       20000 |          3000 |                 0 |                      13.04 |               0.00
 lab        | inventario            |       20000 |          1200 |              1200 |                       5.66 |               6.00
 lab        | clientes              |       20000 |           400 |               400 |                       1.96 |               2.00
 lab        | envios                |       20000 |             0 |                 0 |                       0.00 |               0.00
 lab        | carritos              |       10000 |             0 |                 0 |                       0.00 |               0.00
 lab        | sesiones              |       20000 |             0 |                 0 |                       0.00 |               0.00
 lab        | logs_auditoria        |       22000 |             0 |                 0 |                       0.00 |               0.00
 lab        | demo_extreme_bloat    |       50000 |             0 |            950000 |                       0.00 |            1900.00
 lab        | pagos                 |       20000 |             0 |                 0 |                       0.00 |               0.00
 lab        | detalle_pedidos       |       20000 |             0 |                 0 |                       0.00 |               0.00
 lab        | productos             |       20000 |             0 |                 0 |                       0.00 |               0.00
(14 rows)
```

 
### Revisar los filtros aplicados 
Aqui podemos ver que la tabla demo_heavy_updates del esquema lab, esta excluida de todos los mantenimientos (ANALYZE,VACUUM,VACUUM FULL Y REINDEX)
al estar en true la columna is_ignored este excluye al objeto de cualquier mantenimiento.
```sql
select * from maint.filters;
```
**Salida esperada**
```
 filter_id | schema_name |     table_name     | maintenance_action | is_ignored | force_maintenance |          created_at           |          updated_at           | updated_by 
-----------+-------------+--------------------+--------------------+------------+-------------------+-------------------------------+-------------------------------+------------
         1 | lab         | demo_heavy_updates | ALL                | t          | f                 | 2026-08-24 23:50:54.445692+00 | 2026-08-24 23:50:54.445692+00 | postgres
         2 | lab         | demo_extreme_bloat | ALL                | f          | t                 | 2026-08-24 23:50:54.445931+00 | 2026-08-24 23:50:54.445931+00 | postgres
(2 rows)
```

### Igual si quieres puedes especificar que unicamente quieres excluir el vacuum. 
```
update maint.filters set maintenance_action = 'VACUUM' where filter_id in( 1,2) ;
select * from maint.filters;
 filter_id | schema_name |     table_name     | maintenance_action | is_ignored | force_maintenance |          created_at           |          updated_at           | updated_by 
-----------+-------------+--------------------+--------------------+------------+-------------------+-------------------------------+-------------------------------+------------
         2 | lab         | demo_extreme_bloat | VACUUM             | f          | t                 | 2026-08-24 23:50:54.445931+00 | 2026-08-24 23:50:54.445931+00 | postgres2
         1 | lab         | demo_heavy_updates | VACUUM             | t          | f                 | 2026-08-24 23:50:54.445692+00 | 2026-08-24 23:50:54.445692+00 | postgres2
(2 rows)
```


 


---
 

#### Escenario 4: Auditoría Forense y Contención de Desastres

> **Discurso para el cliente:** *"¿Qué pasa si un mantenimiento falla porque la tabla estaba bloqueada por un usuario o el motor rechazó el comando? En herramientas tradicionales, el script muere en silencio. Nuestra herramienta atrapa el error de la memoria compartida de Linux y lo graba en piedra para el DBA."*

```sql
-- Mostrar la captura forense del error del Vacuum Full anterior
SELECT 
    table_name, 
    status, 
    error_log 
FROM maint.vacuum_tasks 
WHERE status = 'FAILED' 
ORDER BY task_id DESC LIMIT 1;

```

---

#### Escenario 5: El Pase VIP (Ventana Relámpago)

> **Discurso para el cliente:** *"Tenemos 5 minutos antes de un cierre contable y necesitamos limpiar SOLO las tablas de facturación sin que el orquestador escanee el resto del sistema. Usamos nuestro perfil `CUSTOM_LIST`."*

```sql
CALL maint.sp_orchestrate_vacuum(
    p_scope => 'CUSTOM_LIST',
    p_profile => 'BALANCED',
    p_parallel_workers => 2,
    p_verbose => TRUE
);

```

---

### 📊 FASE 3: EL TABLERO DE MANDO (DASHBOARD C-LEVEL)

> **Discurso de cierre:** *"Señores, la ingeniería de fondo es compleja, pero la visibilidad directiva debe ser inmediata. Este es el Dashboard que sus gerentes de TI verán cada mañana. Control absoluto, cero cajas negras."*

```sql
SELECT 
    j.job_id AS "ID Job",
    j.job_type AS "Perfil Estratégico",
    j.status AS "Estado Final",
    j.parallel_workers AS "Hilos",
    j.tables_processed AS "Éxitos",
    COUNT(t.task_id) AS "Total Evaluadas",
    SUM(CASE WHEN t.status = 'FAILED' THEN 1 ELSE 0 END) AS "Errores",
    ROUND(EXTRACT(EPOCH FROM (j.ended_at - j.started_at))::numeric, 2) || ' seg' AS "Duración",
    j.started_at::TIME(0) AS "Hora Inicio"
FROM maint.jobs j
LEFT JOIN maint.vacuum_tasks t ON j.job_id = t.job_id
GROUP BY j.job_id, j.job_type, j.status, j.parallel_workers, j.tables_processed, j.started_at, j.ended_at
ORDER BY j.job_id DESC;
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

