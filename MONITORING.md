

# 🛠️ MANUAL DE CONSULTAS OPERATIVAS Y MONITOREO (`pg-csql-maint`)

Este apartado contiene la batería de consultas SQL esenciales para la supervisión en tiempo real, auditoría de estados, diagnóstico de infraestructura y control del orquestador asíncrono.

---

## 🟢 1. MONITOREO EN TIEMPO REAL (Concurrencia y S.O.)

### 📍 1.1. Monitoreo de Workers Asíncronos Activos (`pg_background`)

Muestra únicamente las sesiones activas en segundo plano lanzadas por la extensión. Permite verificar qué trabajadores están ejecutando comandos de mantenimiento en el motor en un instante dado.

```sql
SELECT pid, 
       usename, 
       application_name, 
       client_addr, 
       state, 
       query_start, 
       clock_timestamp() - query_start AS duration, 
       query
FROM pg_stat_activity 
WHERE backend_type = 'pg_background'
ORDER BY query_start ASC;

```

* **Para qué sirve:** Identifica el PID de Linux/PostgreSQL de los hilos de fondo, la tabla que están procesando actualmente (`VACUUM`, `ANALYZE`, `REINDEX`) y el tiempo transcurrido desde que iniciaron.

---

### 📍 1.2. Conteo Rápido de Trabajadores en Segundo Plano

```sql
SELECT count(*) AS active_pg_background_workers 
FROM pg_stat_activity 
WHERE backend_type = 'pg_background';

```

* **Para qué sirve:** Verificación instantánea para confirmar si el orquestador está respetando el límite de concurrencia configurado en el parámetro `p_parallel_workers` (ej. 4, 8 u 10 hilos).

---

### 📍 1.3. Monitoreo del Proceso Padre Orquestador

> **REGLA DE ARQUITECTURA:** El proceso orquestador principal (Padre) **NO corre en `pg_background**`; es una sesión de cliente ordinaria (`client backend`) que ejecuta el procedimiento almacenado.

Para identificar la sesión del orquestador Padre en ejecución:

```sql
SELECT pid, 
       usename, 
       application_name, 
       client_addr, 
       state, 
       backend_type,
       clock_timestamp() - query_start AS total_execution_time, 
       query
FROM pg_stat_activity 
WHERE query LIKE '%sp_orchestrate_%'
  AND backend_type = 'client backend'
  AND pid <> pg_backend_pid();

```

* **Para qué sirve:** Permite al DBA ubicar el PID de la sesión principal que invocó el `CALL maint.sp_orchestrate_*`. Útil si se requiere inspeccionar bloqueos o aplicar un freno de emergencia kill-switch cancelando la sesión Padre.

---

## 📊 2. INSPECCIÓN DEL CATÁLOGO Y ESTRUCTURA (`maint`)

### 📍 2.1. Listado Completo de Tablas del Esquema Maint

```sql
SELECT table_schema, 
       table_name, 
       table_type
FROM information_schema.tables 
WHERE table_schema = 'maint' 
ORDER BY table_name;

```

* **Para qué sirve:** Muestra la infraestructura física del esquema de mantenimiento (`jobs`, `filters`, `vacuum_tasks`, `analyze_tasks`, `reindex_tasks`, `vacuum_full_tasks`, `pgstattuple`, `pgstatindex`, `vacuum_profiles`).

---

### 📍 2.2. Inspección del Diccionario de Datos del Esquema `maint`

```sql
SELECT table_name, 
       column_name, 
       data_type, 
       character_maximum_length, 
       is_nullable
FROM information_schema.columns 
WHERE table_schema = 'maint'
ORDER BY table_name, ordinal_position;

```

* **Para qué sirve:** Valida la estructura de columnas y tipos de datos del esquema (por ejemplo, verificar si `drift_pct` o `dead_pct` ya fueron actualizados a `NUMERIC(12,2)` para prevenir desbordamientos).

---

## 📑 3. CONTROL DE TRABAJOS Y AUDITORÍA (`maint.jobs` / `maint.filters`)

### 📍 3.1. Consulta de Cabecera Maestra de Trabajos (`maint.jobs`)

```sql
SELECT job_id, 
       job_type, 
       maintenance_action, 
       orchestrator_pid, 
       status, 
       tables_processed, 
       started_at, 
       ended_at, 
       ended_at - started_at AS total_duration,
       execution_params
FROM maint.jobs 
ORDER BY job_id DESC 
LIMIT 20;

```

* **Para qué sirve:** Ofrece la visión macro de los ciclos de mantenimiento ejecutados. Permite revisar el estado global (`RUNNING`, `COMPLETED`, `COMPLETED_WITH_CUTOFF`, `ABORTED_ORPHAN`), la cantidad real de tablas procesadas con éxito y la fotografía JSONB inmutable de los parámetros usados en la invocación.

---

### 📍 3.2. Consulta de Filtros y Reglas de Exclusión (`maint.filters`)

```sql
SELECT filter_id, 
       schema_name, 
       table_name, 
       maintenance_action, 
       is_ignored, 
       force_maintenance, 
       updated_at, 
       updated_by
FROM maint.filters 
ORDER BY schema_name, table_name;

```

* **Para qué sirve:** Muestra las Reglas de Negocio activas (Blacklist / Whitelist). Permite verificar qué tablas están configuradas como ignoradas (`is_ignored = TRUE`) o cuáles tienen prioridad forzada (`force_maintenance = TRUE` para el modo `CUSTOM_LIST`).

---

## 🔍 4. TELEMETRÍA DETALLADA Y DIAGNÓSTICO DE TAREAS HIJAS

### 📍 4.1. Seguimiento en Vivo de Tareas por Módulo (`maint.*_tasks`)

#### **A. Estado de Tareas de Vacuum:**

```sql
SELECT task_id, job_id, schema_name, table_name, n_dead_tup, dead_pct, status, child_pid, child_cookie, ended_at - started_at AS duration, error_log
FROM maint.vacuum_tasks
WHERE job_id = (SELECT max(job_id) FROM maint.jobs WHERE maintenance_action = 'VACUUM')
ORDER BY task_id ASC;

```

#### **B. Estado de Tareas de Analyze:**

```sql
SELECT task_id, job_id, schema_name, table_name, filas_afectadas, drift_pct, stage_number, status, child_pid, ended_at - started_at AS duration, error_log
FROM maint.analyze_tasks
WHERE job_id = (SELECT max(job_id) FROM maint.jobs WHERE maintenance_action = 'ANALYZE')
ORDER BY stage_number ASC, task_id ASC;

```

#### **C. Estado de Tareas de Reindex:**

```sql
SELECT task_id, job_id, schema_name, index_name, frag_pct_evaluado, bloat_pct_evaluado, old_relfilenode, new_relfilenode, status, error_log
FROM maint.reindex_tasks
WHERE job_id = (SELECT max(job_id) FROM maint.jobs WHERE maintenance_action = 'REINDEX')
ORDER BY task_id ASC;

```

#### **D. Estado de Tareas de Vacuum Full:**

```sql
SELECT task_id, job_id, schema_name, table_name, bloat_pct_evaluado, bloat_kb_evaluado, old_relfilenode, new_relfilenode, status, error_log
FROM maint.vacuum_full_tasks
WHERE job_id = (SELECT max(job_id) FROM maint.jobs WHERE maintenance_action = 'VACUUM_FULL')
ORDER BY task_id ASC;

```

* **Para qué sirven:** Muestran el detalle tabla por tabla del último trabajo ejecutado. Permiten detectar rápidamente cuáles tablas fallaron (`status = 'FAILED'`), los mensajes de error nativos (`error_log`) y certificar la reescritura física de archivos observando el cambio entre `old_relfilenode` y `new_relfilenode`.

---

### 📍 4.2. Resumen de Errores e Incidentes Recientes

```sql
SELECT 'VACUUM' AS modulo, schema_name, table_name, error_log, ended_at FROM maint.vacuum_tasks WHERE status = 'FAILED'
UNION ALL
SELECT 'ANALYZE' AS modulo, schema_name, table_name, error_log, ended_at FROM maint.analyze_tasks WHERE status = 'FAILED'
UNION ALL
SELECT 'REINDEX' AS modulo, schema_name, index_name AS table_name, error_log, ended_at FROM maint.reindex_tasks WHERE status LIKE 'FAILED%'
UNION ALL
SELECT 'VACUUM_FULL' AS modulo, schema_name, table_name, error_log, ended_at FROM maint.vacuum_full_tasks WHERE status LIKE 'FAILED%'
ORDER BY ended_at DESC 
LIMIT 20;

```

* **Para qué sirve:** Concentrador de fallos forenses. Permite al DBA revisar de un solo vistazo todos los errores ocurridos en cualquier módulo (ej. `numeric field overflow` o `No space left on device`) sin tener que consultar tabla por tabla.

---

## 📈 5. TELEMETRÍA DE BHOAT Y FRAGMENTACIÓN (RADAR)

### 📍 5.1. Consulta del Radar de Bloat Físico (`maint.pgstattuple`)

```sql
SELECT evaluation_date, 
       schema_name, 
       table_name, 
       ROUND(total_bloat_kb / 1024.0, 2) AS bloat_mb, 
       total_bloat_pct, 
       requiere_vf, 
       deep_scanned
FROM maint.pgstattuple
WHERE evaluation_date = CURRENT_DATE
ORDER BY total_bloat_kb DESC 
LIMIT 25;

```

* **Para qué sirve:** Muestra las tablas con mayor nivel de espacio desperdiciado (bloat) en la base de datos evaluadas por el radar diario de `VACUUM FULL`.

---

### 📍 5.2. Consulta del Radar de Fragmentación B-Tree (`maint.pgstatindex`)

```sql
SELECT evaluation_date, 
       schema_name, 
       table_name, 
       index_name, 
       ROUND(index_size_kb / 1024.0, 2) AS size_mb, 
       leaf_fragmentation_pct, 
       total_bloat_pct, 
       is_invalid, 
       requiere_reindex
FROM maint.pgstatindex
WHERE evaluation_date = CURRENT_DATE
ORDER BY leaf_fragmentation_pct DESC, index_size_kb DESC 
LIMIT 25;

```

* **Para qué sirve:** Identifica los índices B-Tree más fragmentados, con mayor porcentaje de bloat o marcados como corruptos/inválidos (`is_invalid = TRUE`), ideales para la intervención con `sp_orchestrate_reindex`.
