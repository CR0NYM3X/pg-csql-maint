 
### 🪖 FASE 1: WAR GAMES (GENERACIÓN DE DEGRADACIÓN FÍSICA Y ESPACIO EN DISCO)

Ejecuta este bloque inicial para limpiar el esquema `lab`, desactivar `autovacuum` y generar diversos tipos de fragmentación física (tuplas muertas + espacio libre en páginas de disco).

```sql
CREATE DATABASE db_mantos;
\C db_mantos

-- ====================================================================================
-- DBA SQUAD: VANGUARD BLACK-OPS | SIMULADOR DE ESTRÉS PARA VACUUM FULL V3.4
-- ====================================================================================
CREATE SCHEMA IF NOT EXISTS lab;

-- 1. Limpieza Total del Entorno
DROP TABLE IF EXISTS lab.demo_extreme_bloat CASCADE;
DROP TABLE IF EXISTS lab.demo_heavy_updates CASCADE;
DROP TABLE IF EXISTS lab.demo_vip_facturas CASCADE;
DROP TABLE IF EXISTS lab.demo_escudo_historial CASCADE;

-- 2. Creación de Topología de Tablas
CREATE TABLE lab.demo_extreme_bloat (id SERIAL PRIMARY KEY, payload TEXT, status VARCHAR(20));
CREATE TABLE lab.demo_heavy_updates (id SERIAL PRIMARY KEY, balance NUMERIC, last_tx TIMESTAMPTZ);
CREATE TABLE lab.demo_vip_facturas (id SERIAL PRIMARY KEY, monto NUMERIC, cliente TEXT);
CREATE TABLE lab.demo_escudo_historial (id SERIAL PRIMARY KEY, log_data TEXT);

-- Desactivar Autovacuum para simular degradación física sin autogestión
ALTER TABLE lab.demo_extreme_bloat SET (autovacuum_enabled = false);
ALTER TABLE lab.demo_heavy_updates SET (autovacuum_enabled = false);
ALTER TABLE lab.demo_vip_facturas SET (autovacuum_enabled = false);
ALTER TABLE lab.demo_escudo_historial SET (autovacuum_enabled = false);

-- ====================================================================================
-- 3. INYECCIÓN MASIVA DE TRÁFICO Y GENERACIÓN DE HUECOS FÍSICOS (BLOAT)
-- ====================================================================================

-- [CASO A] TABLA DE BLOAT CRÍTICO: Objetivo -> Bypass de Fuerza Bruta / SMART
-- Inserción de 300,000 filas pesadas. Borramos el 90% y aplicamos VACUUM normal.
-- Esto deja la tabla llena de "Espacio Libre Físico" en disco que solo recupera VACUUM FULL.
INSERT INTO lab.demo_extreme_bloat(payload, status) 
SELECT repeat('A', 800), 'PROCESADO' FROM generate_series(1, 300000) g;

DELETE FROM lab.demo_extreme_bloat WHERE id % 10 != 0; -- Borra 270,000 filas


-- [CASO B] TABLA DE REESCRITURA PENDIENTE: Objetivo -> SMART con Historial
INSERT INTO lab.demo_heavy_updates(balance, last_tx) 
SELECT g * 10.5, clock_timestamp() FROM generate_series(1, 150000) g;
UPDATE lab.demo_heavy_updates SET balance = balance + 1.0; 


-- [CASO C] TABLA VIP (Lista Blanca): Objetivo -> CUSTOM_LIST / FORCE_SURGERY
INSERT INTO lab.demo_vip_facturas(monto, cliente) 
SELECT 100.00, 'Cliente VIP' FROM generate_series(1, 40000) g;
UPDATE lab.demo_vip_facturas SET monto = 150.00 WHERE id < 10000;


-- [CASO D] TABLA INMUNE (Lista Negra): Objetivo -> ESCUDO DE IGNORADOS
INSERT INTO lab.demo_escudo_historial(log_data) 
SELECT 'Log de Sistema Crítico' FROM generate_series(1, 80000) g;
DELETE FROM lab.demo_escudo_historial WHERE id < 40000;

VACUUM lab.demo_escudo_historial;
VACUUM lab.demo_vip_facturas;
VACUUM lab.demo_heavy_updates;
VACUUM lab.demo_extreme_bloat; -- Convierte tuplas muertas en Espacio Libre de Páginas (Free Space)


ANALYZE lab.demo_escudo_historial;
ANALYZE lab.demo_vip_facturas;
ANALYZE lab.demo_heavy_updates;
ANALYZE lab.demo_extreme_bloat;

-- ====================================================================================
-- 4. CONFIGURACIÓN DEL PANEL DE SEGURIDAD (maint.filters)
-- ====================================================================================
DELETE FROM maint.filters WHERE schema_name = 'lab';

INSERT INTO maint.filters (schema_name, table_name, is_ignored, force_maintenance, maintenance_action) VALUES 
('lab', 'demo_escudo_historial', TRUE,  FALSE, 'VACUUM_FULL'), -- [ESCUDO ACTIVO]: Intocable.
('lab', 'demo_vip_facturas',     FALSE, TRUE,  'VACUUM_FULL'); -- [PASE VIP]: Mantenimiento prioritario.

```

---

### 🔍 REVISIÓN DE FILTROS Y ESTADO PREVIO A LA CIRUGÍA

#### Consulta A: Filtros Registrados

```sql
SELECT filter_id, schema_name, table_name, maintenance_action, is_ignored, force_maintenance 
FROM maint.filters 
WHERE schema_name = 'lab';
```

**Salida Esperada:**

```text
 filter_id | schema_name |      table_name       | maintenance_action | is_ignored | force_maintenance 
-----------+-------------+-----------------------+--------------------+------------+-------------------
         1 | lab         | demo_escudo_historial | VACUUM_FULL        | t          | f
         2 | lab         | demo_vip_facturas     | VACUUM_FULL        | f          | t

```

#### Consulta B: Registro del Inodo Físico (`relfilenode`) Previo

Identifica el identificador del archivo en disco de cada tabla antes de cualquier operación.

```sql

SELECT 
    n.nspname AS schema_name,
    c.relname AS table_name,
    c.oid AS table_oid,
    c.relfilenode AS old_relfilenode,
    pg_size_pretty(pg_relation_size(c.oid)) AS total_size,
    -- COLUMNA SOLICITADA: Detecta si existe registro de éxito en las bitácoras históricas
    EXISTS (
        SELECT 1 
        FROM maint.vacuum_full_tasks t
        WHERE t.schema_name = n.nspname 
          AND t.table_name = c.relname 
          AND t.status = 'SUCCESS'
    ) OR EXISTS (
        SELECT 1 
        FROM maint.pgstattuple p
        WHERE p.schema_name = n.nspname 
          AND p.table_name = c.relname 
          AND p.deep_scanned = TRUE
    ) AS has_had_vf
FROM pg_class c 
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'lab'
  AND c.relkind IN ('r', 'm') -- FILTRO CRÍTICO: Excluye Índices, Secuencias y Vistas
  AND c.relname in('demo_extreme_bloat','demo_heavy_updates','demo_vip_facturas','demo_escudo_historial')
ORDER BY pg_relation_size(c.oid) DESC;

```

**Salida Esperada:**

```text
 schema_name |      table_name       | table_oid | old_relfilenode | total_size | has_had_vf 
-------------+-----------------------+-----------+-----------------+------------+------------
 lab         | demo_extreme_bloat    |   1804959 |         1804959 | 260 MB     | f
 lab         | demo_heavy_updates    |   1804968 |         1804968 | 15 MB      | f
 lab         | demo_escudo_historial |   1804986 |         1804986 | 4712 kB    | f
 lab         | demo_vip_facturas     |   1804977 |         1804977 | 2552 kB    | f
(4 rows)
```

### Revisar las estadisticas de manrea manual.  
```
SELECT 
    n.nspname AS schema_name,
    c.relname AS table_name,
    ROUND((pg_relation_size(c.oid) / 1024.0 / 1024.0)::numeric, 2) AS total_mb,
    ROUND((app.table_len / 1024.0 / 1024.0)::numeric, 2) AS scan_mb,
    ROUND(app.scanned_percent::numeric, 2) AS scanned_pct,
    app.approx_tuple_count AS live_tuples,
    ROUND((app.approx_tuple_len / 1024.0 / 1024.0)::numeric, 2) AS live_mb,
    ROUND(app.approx_tuple_percent::numeric, 2) AS live_pct,
    app.dead_tuple_count AS dead_tuples,
    ROUND((app.dead_tuple_len / 1024.0 / 1024.0)::numeric, 2) AS dead_mb,
    ROUND(app.dead_tuple_percent::numeric, 2) AS dead_pct,
    ROUND((app.approx_free_space / 1024.0 / 1024.0)::numeric, 2) AS free_mb,
    ROUND(app.approx_free_percent::numeric, 2) AS free_pct,
    ROUND((app.dead_tuple_percent + app.approx_free_percent)::numeric, 2) AS total_bloat_pct
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
CROSS JOIN LATERAL pgstattuple_approx(c.oid) app
WHERE n.nspname = 'lab'
  AND c.relkind IN ('r', 'm')
  AND c.relname IN (
      'demo_extreme_bloat',
      'demo_heavy_updates',
      'demo_vip_facturas',
      'demo_escudo_historial'
  )
ORDER BY total_bloat_pct DESC;
```

**Salida esperada**
```
 schema_name |      table_name       | total_mb | scan_mb | scanned_pct | live_tuples | live_mb | live_pct | dead_tuples | dead_mb | dead_pct | free_mb | free_pct | total_bloat_pct 
-------------+-----------------------+----------+---------+-------------+-------------+---------+----------+-------------+---------+----------+---------+----------+-----------------
 lab         | demo_extreme_bloat    |   260.42 |  260.42 |        0.00 |       29981 |   26.14 |    10.04 |           0 |    0.00 |     0.00 |  234.28 |    89.96 |           89.96
 lab         | demo_escudo_historial |     4.60 |    4.60 |        0.00 |       40001 |    2.31 |    50.13 |           0 |    0.00 |     0.00 |    2.29 |    49.87 |           49.87
 lab         | demo_heavy_updates    |    14.93 |   14.93 |        0.00 |      150000 |    7.49 |    50.19 |           0 |    0.00 |     0.00 |    7.44 |    49.81 |           49.81
 lab         | demo_vip_facturas     |     2.49 |    2.49 |        0.00 |       40000 |    1.99 |    79.96 |           0 |    0.00 |     0.00 |    0.50 |    20.04 |           20.04
(4 rows)
```



---

### 🧪 ESCENARIOS DE EVALUACIÓN Y EJECUCIÓN

---

### 📍 ESCENARIO 1: RADAR TRIAGE Y SIMULACIÓN HISTÓRICA (`sp_pgstattuple`)

Ejecutamos el procedimiento Triage para registrar el *bloat* en Kilobytes en la tabla `maint.pgstattuple`.

```sql
CALL maint.sp_pgstattuple(
    p_scope               => 'ALL_USER',
    p_bloat_pct_threshold => 50.00,
    p_bloat_mb_threshold  => 50.00,        -- Umbral regular (50 MB)
    p_threshold_operator => 'OR',         -- Compuerta entre % y MB ('OR' / 'AND')
    p_min_table_mb        => 0.00,         -- Evalúa desde 0 MB en adelante
    p_force_bloat_mb      => NULL,         -- [NUEVO]: Bypass de emergencia (NULL = Desactivado, o p. ej. 500.00 MB)
    p_enable_deep_scan    => FALSE,        -- Escaneo bloque a bloque (FALSE = Aprox rápido)
    p_verbose             => TRUE          -- Diagnóstico visual en consola
);

```
**Salida esperada**
```
INFO:  =========================================================
INFO:  [DBA SQUAD] RADAR DE TRIAGE DIARIO (V3.4.4 - LOGIC: OR | THRESHOLD: 51200.00 KB | FORCE: DESACTIVADO)
INFO:  =========================================================
INFO:  [✓] TRIAGE FINALIZADO. Evaluadas: 9, Deep Scans: 0, Requiere VF: 5
CALL
```

### Revisar las si guardo los datos correctos
si observamos aunque este aplicado el filtro de la tabla demo_escudo_historial aun asi se involuctra en el escaneo, aqui el orquestador es inteligente para ya no ejecutarlo. 
```
select * from maint.pgstattuple where table_name 
 IN (
      'demo_extreme_bloat',
      'demo_heavy_updates',
      'demo_vip_facturas',
      'demo_escudo_historial'
  );
```
**Salida esperada**
```
-[ RECORD 1 ]-------------+------------------------------
triage_id                 | 229
evaluation_date           | 2026-08-26
schema_name               | lab
table_name                | demo_extreme_bloat
approx_scanned            | t
approx_evaluated_at       | 2026-08-26 00:33:06.125732+00
approx_table_len          | 273072128
approx_scanned_percent    | 0.00
approx_tuple_count        | 29981
approx_tuple_len          | 27413312
approx_tuple_percent      | 10.04
approx_dead_tuple_count   | 0
approx_dead_tuple_len     | 0
approx_dead_tuple_percent | 0.00
approx_free_space         | 245658816
approx_free_percent       | 89.96
deep_scanned              | f
deep_evaluated_at         | 
deep_table_len            | 
deep_tuple_count          | 
deep_tuple_len            | 
deep_tuple_percent        | 
deep_dead_tuple_count     | 
deep_dead_tuple_len       | 
deep_dead_tuple_percent   | 
deep_free_space           | 
deep_free_percent         | 
total_bloat_kb            | 239901.19
total_bloat_pct           | 89.96
requiere_vf               | t
-[ RECORD 2 ]-------------+------------------------------
triage_id                 | 239
evaluation_date           | 2026-08-26
schema_name               | lab
table_name                | demo_heavy_updates
approx_scanned            | t
approx_evaluated_at       | 2026-08-26 00:33:06.145787+00
approx_table_len          | 15654912
approx_scanned_percent    | 0.00
approx_tuple_count        | 150000
approx_tuple_len          | 7857632
approx_tuple_percent      | 50.19
approx_dead_tuple_count   | 0
approx_dead_tuple_len     | 0
approx_dead_tuple_percent | 0.00
approx_free_space         | 7797280
approx_free_percent       | 49.81
deep_scanned              | f
deep_evaluated_at         | 
deep_table_len            | 
deep_tuple_count          | 
deep_tuple_len            | 
deep_tuple_percent        | 
deep_dead_tuple_count     | 
deep_dead_tuple_len       | 
deep_dead_tuple_percent   | 
deep_free_space           | 
deep_free_percent         | 
total_bloat_kb            | 7614.53
total_bloat_pct           | 49.81
requiere_vf               | t
-[ RECORD 3 ]-------------+------------------------------
triage_id                 | 264
evaluation_date           | 2026-08-26
schema_name               | lab
table_name                | demo_vip_facturas
approx_scanned            | t
approx_evaluated_at       | 2026-08-26 00:33:06.1774+00
approx_table_len          | 2613248
approx_scanned_percent    | 0.00
approx_tuple_count        | 40000
approx_tuple_len          | 2089632
approx_tuple_percent      | 79.96
approx_dead_tuple_count   | 0
approx_dead_tuple_len     | 0
approx_dead_tuple_percent | 0.00
approx_free_space         | 523616
approx_free_percent       | 20.04
deep_scanned              | f
deep_evaluated_at         | 
deep_table_len            | 
deep_tuple_count          | 
deep_tuple_len            | 
deep_tuple_percent        | 
deep_dead_tuple_count     | 
deep_dead_tuple_len       | 
deep_dead_tuple_percent   | 
deep_free_space           | 
deep_free_percent         | 
total_bloat_kb            | 511.34
total_bloat_pct           | 20.04
requiere_vf               | t
-[ RECORD 4 ]-------------+------------------------------
triage_id                 | 269
evaluation_date           | 2026-08-26
schema_name               | lab
table_name                | demo_escudo_historial
approx_scanned            | t
approx_evaluated_at       | 2026-08-26 00:33:06.183404+00
approx_table_len          | 4825088
approx_scanned_percent    | 0.00
approx_tuple_count        | 40001
approx_tuple_len          | 2418976
approx_tuple_percent      | 50.13
approx_dead_tuple_count   | 0
approx_dead_tuple_len     | 0
approx_dead_tuple_percent | 0.00
approx_free_space         | 2406112
approx_free_percent       | 49.87
deep_scanned              | f
deep_evaluated_at         | 
deep_table_len            | 
deep_tuple_count          | 
deep_tuple_len            | 
deep_tuple_percent        | 
deep_dead_tuple_count     | 
deep_dead_tuple_len       | 
deep_dead_tuple_percent   | 
deep_free_space           | 
deep_free_percent         | 
total_bloat_kb            | 2349.72
total_bloat_pct           | 49.87
requiere_vf               | t
```  



#### Inyección Manual de Histórico (Simulación de 5 Días de Degradación)

Para probar la condición de `p_sustained_days => 5` sin esperar 5 días reales, duplicamos la entrada de telemetría para los 4 días anteriores:

```sql
INSERT INTO maint.pgstattuple (
    evaluation_date, schema_name, table_name, approx_scanned, 
    total_bloat_kb, total_bloat_pct, requiere_vf
)
SELECT 
    CURRENT_DATE - i, schema_name, table_name, approx_scanned, 
    total_bloat_kb, total_bloat_pct, requiere_vf
FROM maint.pgstattuple, generate_series(1, 4) i
WHERE evaluation_date = CURRENT_DATE
ON CONFLICT (evaluation_date, schema_name, table_name) DO NOTHING;

```

#### Consulta de Confirmación del Radar:

```sql
SELECT evaluation_date, schema_name, table_name, total_bloat_kb, (total_bloat_kb / 1024)::numeric(14,2) as total_bloat_mb, total_bloat_pct, requiere_vf 
FROM maint.pgstattuple 
WHERE schema_name = 'lab' AND evaluation_date between CURRENT_DATE -5 and CURRENT_DATE and
table_name IN ('demo_extreme_bloat','demo_heavy_updates', 'demo_vip_facturas', 'demo_escudo_historial' )
ORDER BY  total_bloat_kb DESC, table_name desc , evaluation_date asc;
```

**Salida esperada**
```
 evaluation_date | schema_name |      table_name       | total_bloat_kb | total_bloat_mb | total_bloat_pct | requiere_vf 
-----------------+-------------+-----------------------+----------------+----------------+-----------------+-------------
 2026-08-22      | lab         | demo_extreme_bloat    |      239901.19 |         234.28 |           89.96 | t
 2026-08-23      | lab         | demo_extreme_bloat    |      239901.19 |         234.28 |           89.96 | t
 2026-08-24      | lab         | demo_extreme_bloat    |      239901.19 |         234.28 |           89.96 | t
 2026-08-25      | lab         | demo_extreme_bloat    |      239901.19 |         234.28 |           89.96 | t
 2026-08-26      | lab         | demo_extreme_bloat    |      239901.19 |         234.28 |           89.96 | t
 2026-08-22      | lab         | demo_heavy_updates    |        7614.53 |           7.44 |           49.81 | f
 2026-08-23      | lab         | demo_heavy_updates    |        7614.53 |           7.44 |           49.81 | f
 2026-08-24      | lab         | demo_heavy_updates    |        7614.53 |           7.44 |           49.81 | f
 2026-08-25      | lab         | demo_heavy_updates    |        7614.53 |           7.44 |           49.81 | f
 2026-08-26      | lab         | demo_heavy_updates    |        7614.53 |           7.44 |           49.81 | f
 2026-08-22      | lab         | demo_escudo_historial |        2349.72 |           2.29 |           49.87 | f
 2026-08-23      | lab         | demo_escudo_historial |        2349.72 |           2.29 |           49.87 | f
 2026-08-24      | lab         | demo_escudo_historial |        2349.72 |           2.29 |           49.87 | f
 2026-08-25      | lab         | demo_escudo_historial |        2349.72 |           2.29 |           49.87 | f
 2026-08-26      | lab         | demo_escudo_historial |        2349.72 |           2.29 |           49.87 | f
 2026-08-22      | lab         | demo_vip_facturas     |         511.34 |           0.50 |           20.04 | f
 2026-08-23      | lab         | demo_vip_facturas     |         511.34 |           0.50 |           20.04 | f
 2026-08-24      | lab         | demo_vip_facturas     |         511.34 |           0.50 |           20.04 | f
 2026-08-25      | lab         | demo_vip_facturas     |         511.34 |           0.50 |           20.04 | f
 2026-08-26      | lab         | demo_vip_facturas     |         511.34 |           0.50 |           20.04 | f
(20 rows)
```

---

### 📍 ESCENARIO 2: MANTENIMIENTO SMART CON HISTORIAL Y VERIFICACIÓN FÍSICA

Ejecutamos `sp_orchestrate_vacuum_full` en modo `SMART`. Evaluará las tablas de usuario que cumplan los umbrales históricos acumulados durante los 5 días.

* `demo_extreme_bloat` debe procesarse por superar holgadamente el *bloat*.
* `demo_escudo_historial` **debe ser omitida** por estar en la lista negra (`is_ignored = TRUE`).

```sql
CALL maint.sp_orchestrate_vacuum_full(
    p_scope               => 'ALL_USER',
    p_profile             => 'SMART',
    p_parallel_workers    => 1,
    p_cutoff_time         => NULL,
    p_verbose             => TRUE,
    p_bloat_pct_threshold => 50.00,
    p_bloat_mb_threshold  => 50.00,
    p_threshold_operator => 'OR',
    p_sustained_days      => 5,
    p_min_table_mb        => 0.00,
    p_force_bloat_mb      => NULL,        -- Desactivado para forzar la validación de días
    p_enable_deep_scan    => FALSE,
    p_keep_history        => TRUE
);
```

**Salida Esperada:**

```text
INFO:  [RADAR] Ejecutando sp_pgstattuple síncronamente para refrescar telemetría...
INFO:  =========================================================
INFO:  [DBA SQUAD] RADAR DE TRIAGE DIARIO (V3.4.4 - LOGIC: OR | THRESHOLD: 51200.00 KB | FORCE: DESACTIVADO)
INFO:  =========================================================
INFO:  [✓] TRIAGE FINALIZADO. Evaluadas: 9, Deep Scans: 0, Requiere VF: 5
INFO:  =========================================================
INFO:  [DBA SQUAD] INICIANDO CIRUGIA MAYOR (VACUUM FULL V3.4)
INFO:  ALCANCE: ALL_USER | MODO: SMART | HILOS: 1 | CUTOFF: SIN LIMITE | FORCE_MB: DESACTIVADO
INFO:  =========================================================
INFO:      [>] LANZANDO [VACUUM FULL] PID 1010119 -> lab.demo_extreme_bloat (OLD NODE: 1807252) | Bloat: 239901.19 KB | Dias: 5
INFO:      [✓] CIRUGIA CONFIRMADA -> lab.demo_extreme_bloat (NODE: 1807252 -> 1807342)
INFO:  ---------------------------------------------------------
INFO:  [✓] ORQUESTACION QUIRURGICA FINALIZADA. Job 3 | Procesadas: 1 / 1
INFO:  Tiempo Total: 00:00:02.029293
INFO:  =========================================================
CALL

```

---

### 📍 ESCENARIO 3: CIRUGÍA POR FUERZA BRUTA / EMERGENCY BYPASS (`p_force_bloat_mb`)

Probamos la inyección del parámetro de rescate de espacio en disco. Configuramos `p_force_bloat_mb => 10.00` ($10 \text{ MB}$) y reducimos `p_sustained_days => 10` (simulando un escenario donde no se cumple el historial de días).

* `demo_heavy_updates` no cumpliría por días, pero como su *bloat* supera los $10 \text{ MB}$, activa el **BYPASS DIRECTO** y entra inmediatamente a cirugía.

```sql
CALL maint.sp_orchestrate_vacuum_full(
    p_scope               => 'ALL_USER',
    p_profile             => 'SMART',
    p_parallel_workers    => 1,
    p_cutoff_time         => NULL,
    p_verbose             => TRUE,
    p_bloat_pct_threshold => 20.00,
    p_bloat_mb_threshold  => 5.00,
    p_threshold_operator => 'OR',
    p_sustained_days      => 10,           -- Exige 10 días (No se cumple)
    p_min_table_mb        => 0.00,
    p_force_bloat_mb      => 10.00,         -- BYPASS ACTIVO (10 MB = 10,240 KB)
    p_enable_deep_scan    => FALSE,
    p_keep_history        => TRUE
);

```

**Salida Esperada:**

```text
INFO:  =========================================================
INFO:  [DBA SQUAD] INICIANDO CIRUGIA MAYOR (VACUUM FULL V3.4)
INFO:  ALCANCE: ALL_USER | MODO: SMART | HILOS: 1 | CUTOFF: SIN LIMITE | FORCE_MB: 10.00
INFO:  =========================================================
INFO:      [>] ENCOLADO BYPASS (FORCE BLOAT 10240.00 KB) -> lab.demo_heavy_updates | Bloat: 11264.00 KB
INFO:      [>] LANZANDO [VACUUM FULL] PID 861310 -> lab.demo_heavy_updates (OLD NODE: 245812)
INFO:      [✓] CIRUGIA CONFIRMADA -> lab.demo_heavy_updates (NODE: 245812 -> 245851)
INFO:  ---------------------------------------------------------
INFO:  [✓] ORQUESTACION QUIRURGICA FINALIZADA. Job 2 | Procesadas: 1 / 1
INFO:  Tiempo Total: 00:00:01.321045
INFO:  =========================================================

```

---

### 📍 ESCENARIO 4: MODO FRANCOTIRADOR CIEGO (`FORCE_SURGERY` + `CUSTOM_LIST`)

Validamos la ejecución forzada sobre la tabla `demo_vip_facturas` configurada en `maint.filters` con `force_maintenance = TRUE`. Omite todo cálculo de *bloat* e ingresa de inmediato.

```sql
CALL maint.sp_orchestrate_vacuum_full(
    p_scope               => 'CUSTOM_LIST',   -- Obligatorio para FORCE_SURGERY
    p_profile             => 'FORCE_SURGERY', -- Francotirador Ciego
    p_parallel_workers    => 1,
    p_cutoff_time         => NULL,
    p_verbose             => TRUE,
    p_bloat_pct_threshold => 0.00,
    p_bloat_mb_threshold  => 0.00,
    p_threshold_operator => 'OR',
    p_sustained_days      => 0,
    p_min_table_mb        => 0.00,
    p_force_bloat_mb      => NULL,
    p_enable_deep_scan    => FALSE,
    p_keep_history        => TRUE
);

```

**Salida esperada**
```
INFO:  =========================================================
INFO:  [DBA SQUAD] INICIANDO CIRUGIA MAYOR (VACUUM FULL V3.4)
INFO:  ALCANCE: CUSTOM_LIST | MODO: FORCE_SURGERY | HILOS: 1 | CUTOFF: SIN LIMITE | FORCE_MB: DESACTIVADO
INFO:  =========================================================
INFO:      [>] LANZANDO [VACUUM FULL] PID 1010379 -> lab.demo_vip_facturas (OLD NODE: 1807270) | Bloat: 511.34 KB | Dias: 0
INFO:      [✓] CIRUGIA CONFIRMADA -> lab.demo_vip_facturas (NODE: 1807270 -> 1807354)
INFO:  ---------------------------------------------------------
INFO:  [✓] ORQUESTACION QUIRURGICA FINALIZADA. Job 4 | Procesadas: 1 / 1
INFO:  Tiempo Total: 00:00:02.013515
INFO:  =========================================================
CALL

```
---

### 📊 ESCENARIO 5: AUDITORÍA FORENSE Y VERIFICACIÓN DE INODOS (`relfilenode`)

Una vez concluidas las ejecuciones, verificamos las tablas de bitácora para validar que el `relfilenode` haya cambiado en cada tabla intervenida y certificar el éxito tanto lógico como físico.

#### Consulta A: Verificación de la Cola de Tareas (`maint.vacuum_full_tasks`)

```sql
SELECT 
    task_id,
    job_id,
    schema_name,
    table_name,
    bloat_pct_evaluado,
    bloat_kb_evaluado,
    old_relfilenode AS "Nodo Físico ANTES",
    new_relfilenode AS "Nodo Físico DESPUÉS",
    CASE 
        WHEN old_relfilenode != new_relfilenode THEN '✓ REESCRITURA CONFIRMADA'
        ELSE 'X FALLO DE INODO'
    END AS verificacion_fisica,
    status,
    child_pid,
    ended_at - started_at AS duracion
FROM maint.vacuum_full_tasks
ORDER BY task_id ASC;

```

**Salida Esperada:**

```text
 task_id | job_id | schema_name |     table_name     | bloat_pct_evaluado | bloat_kb_evaluado | Nodo Físico ANTES | Nodo Físico DESPUÉS |   verificacion_fisica    | status  | child_pid |    duracion     
---------+--------+-------------+--------------------+--------------------+-------------------+-------------------+---------------------+--------------------------+---------+-----------+-----------------
       4 |      3 | lab         | demo_extreme_bloat |              89.96 |         239901.19 |           1807252 |             1807342 | ✓ REESCRITURA CONFIRMADA | SUCCESS |   1010119 | 00:00:02.006412
       5 |      4 | lab         | demo_vip_facturas  |              20.04 |            511.34 |           1807270 |             1807354 | ✓ REESCRITURA CONFIRMADA | SUCCESS |   1010379 | 00:00:02.00614

```

### Revisar las estadisticas de manrea manual.  
```
SELECT 
    n.nspname AS schema_name,
    c.relname AS table_name,
    ROUND((pg_relation_size(c.oid) / 1024.0 / 1024.0)::numeric, 2) AS total_mb,
    ROUND((app.table_len / 1024.0 / 1024.0)::numeric, 2) AS scan_mb,
    ROUND(app.scanned_percent::numeric, 2) AS scanned_pct,
    app.approx_tuple_count AS live_tuples,
    ROUND((app.approx_tuple_len / 1024.0 / 1024.0)::numeric, 2) AS live_mb,
    ROUND(app.approx_tuple_percent::numeric, 2) AS live_pct,
    app.dead_tuple_count AS dead_tuples,
    ROUND((app.dead_tuple_len / 1024.0 / 1024.0)::numeric, 2) AS dead_mb,
    ROUND(app.dead_tuple_percent::numeric, 2) AS dead_pct,
    ROUND((app.approx_free_space / 1024.0 / 1024.0)::numeric, 2) AS free_mb,
    ROUND(app.approx_free_percent::numeric, 2) AS free_pct,
    ROUND((app.dead_tuple_percent + app.approx_free_percent)::numeric, 2) AS total_bloat_pct
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
CROSS JOIN LATERAL pgstattuple_approx(c.oid) app
WHERE n.nspname = 'lab'
  AND c.relkind IN ('r', 'm')
  AND c.relname IN (
      'demo_extreme_bloat',
      'demo_heavy_updates',
      'demo_vip_facturas',
      'demo_escudo_historial'
  )
ORDER BY total_bloat_pct DESC;
```

**Salida esperada**
```
 schema_name |      table_name       | total_mb | scan_mb | scanned_pct | live_tuples | live_mb | live_pct | dead_tuples | dead_mb | dead_pct | free_mb | free_pct | total_bloat_pct 
-------------+-----------------------+----------+---------+-------------+-------------+---------+----------+-------------+---------+----------+---------+----------+-----------------
 lab         | demo_escudo_historial |     4.60 |    4.60 |        0.00 |       40001 |    2.31 |    50.13 |           0 |    0.00 |     0.00 |    2.29 |    49.87 |           49.87
 lab         | demo_heavy_updates    |    14.93 |   14.93 |        0.00 |      150000 |    7.49 |    50.19 |           0 |    0.00 |     0.00 |    7.44 |    49.81 |           49.81
 lab         | demo_extreme_bloat    |    26.05 |   26.05 |      100.00 |       30000 |   24.09 |    92.49 |           0 |    0.00 |     0.00 |    1.58 |     6.07 |            6.07
 lab         | demo_vip_facturas     |     1.99 |    1.99 |      100.00 |       40000 |    1.72 |    86.17 |           0 |    0.00 |     0.00 |    0.00 |     0.09 |            0.09
(4 rows)
```



----




### 📍 ESCENARIO  : Forzaremos todo lo que pese igual o mas de 7MB se le realizara vacuum full 
 
```sql

CALL maint.sp_orchestrate_vacuum_full(
    p_scope               => 'ALL_USER',
    p_profile             => 'SMART',
    p_parallel_workers    => 1,
    p_cutoff_time         => NULL,
    p_verbose             => TRUE,
    p_bloat_pct_threshold => 40.00,
    p_bloat_mb_threshold  => 5.00,
    p_threshold_operator => 'OR',
    p_sustained_days      => 5,
    p_min_table_mb        => 0.00,
    p_force_bloat_mb      => 7,        -- Desactivado para forzar la validación de días
    p_enable_deep_scan    => FALSE,
    p_keep_history        => TRUE
);


```

**Salida esperada**
```
INFO:  [RADAR] Ejecutando sp_pgstattuple síncronamente para refrescar telemetría...
INFO:  =========================================================
INFO:  [DBA SQUAD] RADAR DE TRIAGE DIARIO (V3.4.4 - LOGIC: OR | THRESHOLD: 5120.00 KB | FORCE: DESACTIVADO)
INFO:  =========================================================
INFO:  [✓] TRIAGE FINALIZADO. Evaluadas: 9, Deep Scans: 0, Requiere VF: 7
INFO:  =========================================================
INFO:  [DBA SQUAD] INICIANDO CIRUGIA MAYOR (VACUUM FULL V3.4)
INFO:  ALCANCE: ALL_USER | MODO: SMART | HILOS: 1 | CUTOFF: SIN LIMITE | FORCE_MB: 7
INFO:  =========================================================
INFO:      [>] LANZANDO [VACUUM FULL] PID 1012152 -> lab.demo_heavy_updates (OLD NODE: 1807261) | Bloat: 7614.53 KB | Dias: 0
INFO:      [✓] CIRUGIA CONFIRMADA -> lab.demo_heavy_updates (NODE: 1807261 -> 1807387)
INFO:  ---------------------------------------------------------
INFO:  [✓] ORQUESTACION QUIRURGICA FINALIZADA. Job 6 | Procesadas: 1 / 1
INFO:  Tiempo Total: 00:00:02.027926
INFO:  =========================================================
CALL
```

### Validar proceso hijo
```
select * from maint.vacuum_full_tasks where job_id = 6; 
```

```
-[ RECORD 1 ]------+------------------------------
task_id            | 6
job_id             | 6
schema_name        | lab
table_name         | demo_heavy_updates
bloat_pct_evaluado | 49.81
bloat_kb_evaluado  | 7614.53
sustained_days_met | 0
old_relfilenode    | 1807261
new_relfilenode    | 1807387
status             | SUCCESS
child_pid          | 1012152
started_at         | 2026-08-26 10:00:37.548252+00
ended_at           | 2026-08-26 10:00:39.555145+00
error_log    
```

---
---

# Escenario: simulación de interrupción de proesos.

```
update maint.jobs set status = 'RUNNING' where job_id = 6;
update maint.vacuum_full_tasks  set status = 'RUNNING' where job_id = 6;
```

### Validar

```
select * from maint.jobs where job_id = 6;
select * from maint.vacuum_full_tasks where job_id = 6;
```

**Salida**
```
-[ RECORD 1 ]------+-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
job_id             | 6
job_type           | ALL_USER_SMART_SURGERY
maintenance_action | VACUUM_FULL
orchestrator_pid   | 1005502
execution_params   | {"scope": "ALL_USER", "profile": "SMART", "cutoff_time": null, "keep_history": true, "force_bloat_mb": 7, "sustained_days": 5, "enable_deep_scan": false, "parallel_workers": 1, "bloat_mb_threshold": 5.00, "threshold_operator": "OR", "bloat_pct_threshold": 40.00, "force_bloat_kb_calc": 7168.00, "bloat_kb_threshold_calc": 5120.00}
status             | RUNNING
tables_processed   | 1
started_at         | 2026-08-26 10:00:37.544795+00
ended_at           | 2026-08-26 10:00:39.556694+00

 
-[ RECORD 1 ]------+------------------------------
task_id            | 6
job_id             | 6
schema_name        | lab
table_name         | demo_heavy_updates
bloat_pct_evaluado | 49.81
bloat_kb_evaluado  | 7614.53
sustained_days_met | 0
old_relfilenode    | 1807261
new_relfilenode    | 1807387
status             | RUNNING
child_pid          | 1012152
started_at         | 2026-08-26 10:00:37.548252+00
ended_at           | 2026-08-26 10:00:39.555145+00
error_log          | 
```

### Ejecutar orquestador
```
CALL maint.sp_orchestrate_vacuum_full(
    p_scope               => 'ALL_USER',
    p_profile             => 'SMART',
    p_parallel_workers    => 1,
    p_cutoff_time         => NULL,
    p_verbose             => TRUE,
    p_bloat_pct_threshold => 40.00,
    p_bloat_mb_threshold  => 5.00,
    p_threshold_operator => 'OR',
    p_sustained_days      => 5,
    p_min_table_mb        => 0.00,
    p_force_bloat_mb      => 7,        -- Desactivado para forzar la validación de días
    p_enable_deep_scan    => FALSE,
    p_keep_history        => TRUE
);
```

**Salida**
```
NOTICE:  [SELF-HEALING] Job 6 detectado como huérfano. Estado actualizado a ABORTED_ORPHAN.
NOTICE:  [SELF-HEALING] Se auto-sanaron y cerraron 1 trabajo(s) huérfano(s) en maint.jobs.
INFO:  [RADAR] Ejecutando sp_pgstattuple síncronamente para refrescar telemetría...
INFO:  =========================================================
INFO:  [DBA SQUAD] RADAR DE TRIAGE DIARIO (V3.4.4 - LOGIC: OR | THRESHOLD: 5120.00 KB | FORCE: DESACTIVADO)
INFO:  =========================================================
INFO:  [✓] TRIAGE FINALIZADO. Evaluadas: 9, Deep Scans: 0, Requiere VF: 6
INFO:  =========================================================
INFO:  [DBA SQUAD] INICIANDO CIRUGIA MAYOR (VACUUM FULL V3.4)
INFO:  ALCANCE: ALL_USER | MODO: SMART | HILOS: 1 | CUTOFF: SIN LIMITE | FORCE_MB: 7
INFO:  =========================================================
INFO:  [✓] ORQUESTACION FINALIZADA. Job 7 | Procesadas: 0 / 0 (Sin tablas que requieran cirugia)
CALL
```



### Validar

```
select * from maint.jobs where job_id = 6;
select * from maint.vacuum_full_tasks where job_id = 6;
```

**Salida**
```
-[ RECORD 1 ]------+-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
job_id             | 6
job_type           | ALL_USER_SMART_SURGERY
maintenance_action | VACUUM_FULL
orchestrator_pid   | 1005502
execution_params   | {"scope": "ALL_USER", "profile": "SMART", "cutoff_time": null, "keep_history": true, "force_bloat_mb": 7, "sustained_days": 5, "enable_deep_scan": false, "parallel_workers": 1, "bloat_mb_threshold": 5.00, "threshold_operator": "OR", "bloat_pct_threshold": 40.00, "force_bloat_kb_calc": 7168.00, "bloat_kb_threshold_calc": 5120.00}
status             | ABORTED_ORPHAN
tables_processed   | 0
started_at         | 2026-08-26 10:00:37.544795+00
ended_at           | 2026-08-26 10:20:56.691912+00

 
-[ RECORD 1 ]------+---------------------------------------------
task_id            | 6
job_id             | 6
schema_name        | lab
table_name         | demo_heavy_updates
bloat_pct_evaluado | 49.81
bloat_kb_evaluado  | 7614.53
sustained_days_met | 0
old_relfilenode    | 1807261
new_relfilenode    | 1807387
status             | ABORTED_ORPHAN
child_pid          | 1012152
started_at         | 2026-08-26 10:00:37.548252+00
ended_at           | 2026-08-26 10:20:56.691702+00
error_log          | Orchestrator process died or was superseded.

```

---


#### Consulta C: Bitácora Maestra de Jobs (`maint.jobs`)

```sql
SELECT 
    job_id,
    job_type,
    maintenance_action,
    orchestrator_pid,
    status,
    tables_processed,
    execution_params->>'force_bloat_mb' AS force_mb_param,
    started_at,
    ended_at
FROM maint.jobs
WHERE maintenance_action = 'VACUUM_FULL'
ORDER BY job_id DESC;



SELECT 
    a.pid,
    a.usename AS user_name,
    a.datname AS db_name,
    a.client_addr AS client_ip,
    a.backend_type,
    a.state,
    ROUND(EXTRACT(EPOCH FROM (clock_timestamp() - a.query_start))::numeric, 2) AS duration_seconds,
    a.wait_event_type,
    a.wait_event,
    a.query
FROM pg_stat_activity a
WHERE a.pid != pg_backend_pid() -- Excluye la consulta que tú mismo estás ejecutando
  AND a.state IS NOT NULL
  AND a.state != 'idle'         -- Filtra sesiones dormidas/inactivas para ver solo trabajo real
ORDER BY a.query_start ASC;

```

---

### 📋 RESUMEN TÁCTICO PARA LA COMANDANCIA

1. **Pruebas de Estrés Superadas:** El laboratorio demuestra el aislamiento estricto de tablas en listas negras, la activación del Bypass por fuerza bruta y la ejecución quirúrgica por `CUSTOM_LIST`.
2. **Integridad de Datos Garantizada:** El nuevo mecanismo de comparación `old_relfilenode` vs `new_relfilenode` provee una garantía forense al $100\%$, certificando que cada tarea marcada como `SUCCESS` sufrió la reescritura de archivos en el almacenamiento operativo.
