 
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
 

#### Escenario 2: Mantenimiento Diario Inteligente

> **Discurso para el cliente:** *"Es lunes de madrugada. Lanzamos el mantenimiento general. Observen cómo el orquestador detecta automáticamente la tabla con actualizaciones masivas (`demo_heavy_updates`), procesa sus tuplas muertas en segundo plano, pero respeta estrictamente nuestro escudo de seguridad, ignorando por completo la tabla crítica `demo_escudo_historial` a pesar de estar llena de basura."*

```sql
CALL maint.sp_orchestrate_vacuum(
    p_scope => 'SMART_USER',
    p_profile => 'AGGRESSIVE',
    p_parallel_workers => 4,
    p_threshold_pct => 0.05,
    p_verbose => TRUE
);

---- Mantenimiento a todas las tablas Forzado
CALL maint.sp_orchestrate_vacuum(
    p_scope            => 'ALL_USER', --- ALL_USER, SMART_USER, CUSTOM_LIST , SMART_SYSTEM_USER , ALL_SYSTEM_USER, ALL_SYSTEM
    p_profile          => 'BALANCED',
    p_parallel_workers => 16,
    p_cutoff_time      => NULL, -- puedes colocar la hora 
    p_verbose          => TRUE,
    p_threshold_pct    => 0,
    p_min_dead_tup     => 0
);




-- Demuestra que el escudo funcionó:
SELECT table_name, status, error_log FROM maint.vacuum_tasks WHERE job_id = (SELECT MAX(job_id) FROM maint.jobs);

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

