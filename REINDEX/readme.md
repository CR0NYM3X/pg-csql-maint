
# 🛡️ pg-csql-reindex
 

**pg-csql-reindex** es el módulo especializado de reestructuración física para la capa de almacenamiento B-Tree en PostgreSQL. Diseñado bajo la doctrina *Zero-Trust* y *Zero-Downtime*, automatiza la reconstrucción de índices fragmentados (`REINDEX INDEX CONCURRENTLY`), elimina páginas vacías (*empty pages*) y caza índices corruptos o zombis (`indisvalid = false`) sin bloquear las transacciones activas de lectura o escritura de la aplicación.

---

## 🥊 Cuadro Comparativo: ¿Por qué usar pg-csql-reindex?

| Característica / Herramienta | `pg-csql-reindex` 🛡️ | `pg_repack` 📦 | `REINDEX TABLE` tradicional |
| --- | --- | --- | --- |
| **Bloqueo sobre la Tabla** | **CERO** (`AccessShareLock` temporal) | `AccessExclusiveLock` (Breve al final) | **SÍ** (`AccessExclusiveLock` total) |
| **Cazador de Zombis (`INVALID`)** | **SÍ** (Detecta y cura índices `indisvalid=false`) | NO (Ignora o falla con índices inválidos) | NO |
| **Triage Predictivo B-Tree** | **SÍ** (Mide fragmentación foliar vía `pgstatindex`) | NO (Procesa a ciegas) | NO (Procesa a ciegas) |
| **Manejo de Parámetros en RAM** | **SÍ** (Inyecta `maintenance_work_mem` por hilo) | NO | SÍ (Global de sesión) |
| **Freno de Emergencia (`Cutoff`)** | **SÍ** (Detiene el despacho al cruzar la hora límite) | NO | NO |
| **Orquestación Asíncrona** | **SÍ** (Multi-hilo en segundo plano vía `pg_background`) | NO (Depende de scripts de SO) | NO (Secuencial y bloqueante) |

---

## 🏛️ Arquitectura y Diccionario de Datos

El motor opera sobre dos tablas de estado/control y una tabla de telemetría física semanal, garantizando trazabilidad inmutable y cero contención operativa.

### 1. `public.maintenance_jobs` (La Cabecera Maestra)

Almacena el estado global de cada ciclo de orquestación de reindexación.

```sql
CREATE TABLE IF NOT EXISTS public.maintenance_jobs (
    job_id SERIAL PRIMARY KEY,
    job_type VARCHAR(50) NOT NULL,                             -- ej. 'SMART_USER_CONCURRENT', 'SMART_USER_ZOMBIE_HUNTER'
    maintenance_action VARCHAR(20) NOT NULL DEFAULT 'REINDEX', -- 'REINDEX'
    threshold_pct NUMERIC DEFAULT 20.00,                       -- Umbral porcentual de fragmentación foliar
    parallel_workers INT NOT NULL,                             -- Concurrencia máxima de hilos paralelos
    tables_processed INT NOT NULL DEFAULT 0,                   -- [Métrica RAM] Total de índices procesados con éxito
    status VARCHAR(30) DEFAULT 'INITIALIZING',                 -- INITIALIZING, RUNNING, COMPLETED, COMPLETED_WITH_CUTOFF
    started_at TIMESTAMPTZ DEFAULT clock_timestamp(),
    ended_at TIMESTAMPTZ
);

```

---

### 2. `public.mant_reindex_task` (Cola Transaccional de Reindex)

Cola de trabajo a nivel de índice B-Tree para el seguimiento de la reconstrucción concurrente.

```sql
CREATE TABLE IF NOT EXISTS public.mant_reindex_task (
    task_id SERIAL PRIMARY KEY,
    job_id INT NOT NULL REFERENCES public.maintenance_jobs(job_id) ON DELETE CASCADE,
    schema_name TEXT NOT NULL,
    table_name TEXT NOT NULL,
    index_name TEXT NOT NULL,
    index_size_bytes BIGINT,
    fragmentation_pct NUMERIC(5,2),                            -- Fragmentación foliar B-Tree heredada del triage
    is_invalid BOOLEAN DEFAULT FALSE,                          -- Flag de índice zombi (indisvalid = false)
    status VARCHAR(20) DEFAULT 'PENDING',                      -- PENDING, RUNNING, SUCCESS, FAILED, SKIPPED_TIME_LIMIT
    child_pid INT,                                             -- PID del worker en Linux
    started_at TIMESTAMPTZ,
    ended_at TIMESTAMPTZ,
    error_log TEXT                                             -- Captura nativa de SQLERRM
);

```

---

### 3. `public.index_bloat_triage` (Telemetría Predictiva B-Tree)

Histórico semanal que escanea la densidad física de las páginas del índice usando la extensión `pgstattuple`.

```sql
CREATE TABLE IF NOT EXISTS public.index_bloat_triage (
    triage_id BIGSERIAL PRIMARY KEY,
    evaluation_week DATE NOT NULL DEFAULT date_trunc('week', current_date),
    schema_name VARCHAR(255) NOT NULL,
    table_name VARCHAR(255) NOT NULL,
    index_name VARCHAR(255) NOT NULL,
    index_size_bytes BIGINT,
    leaf_fragmentation_pct NUMERIC(5,2),                       -- Porcentaje de hojas B-Tree fragmentadas
    empty_pages_pct NUMERIC(5,2),                              -- Porcentaje de páginas totalmente vacías
    evaluated_at TIMESTAMPTZ DEFAULT clock_timestamp(),
    CONSTRAINT uq_triage_week_index UNIQUE (evaluation_week, schema_name, index_name)
);

```

---

## 🎛️ Ámbitos de Operación (`p_scope`)

El parámetro `p_scope` define el perímetro de búsqueda de índices:

* **`SMART_USER`** *(Recomendado)*: Evalúa índices de usuario, pero solo encola los que superen los umbrales de fragmentación B-Tree o estén marcados como inválidos.
* **`ALL_USER`**: Fuerza la evaluación de todos los índices de tablas de usuario en el catálogo.
* **`CUSTOM_LIST`**: Modo VIP. Procesa únicamente los índices pertenecientes a tablas configuradas con `force_maintenance = TRUE` en `public.maintenance_filters`.
* **`SMART_SYSTEM_USER` / `ALL_SYSTEM_USER` / `ALL_SYSTEM**`: Expande el rango de acción hacia los índices del catálogo del sistema (`pg_catalog`).

---

## ⚙️ Perfiles de Ejecución (`p_profile`)

* **`CONCURRENT`**: Ejecuta `REINDEX INDEX CONCURRENTLY` sobre índices con fragmentación foliar $\ge$ al umbral definido (`p_frag_pct`). También prioriza y sana cualquier índice zombi detectado.
* **`ZOMBIE_HUNTER`**: Modo de respuesta rápida. Filtra y reconstruye **exclusivamente** los índices marcados como corruptos o inválidos (`indisvalid = false`), ignorando la fragmentación de los índices sanos.

---

## 💻 Ejemplos de Uso Recomendados

### Escenario 1: Flujo en 2 Pasos para Ventana de Mantenimiento de Fin de Semana

Se ejecuta durante la ventana autorizada (ej. Sábados de 01:00 AM a 05:00 AM) para realizar telemetría y reconstrucción sin bloquear operaciones comerciales.

```sql
-- =====================================================================
-- PASO 1: RADAR PREDICTIVO DE ÍNDICES (01:00 AM)
-- Escanea la densidad de hojas B-Tree y llena la tabla 'index_bloat_triage'
-- =====================================================================
CALL public.sp_populate_index_triage(
    p_scope              => 'ALL_USER',
    p_min_index_mb       => 50.00,   -- Evalúa índices >= 50 MB
    p_frag_pct_threshold => 20.00,  -- Registra si la fragmentación es >= 20%
    p_verbose            => TRUE
);

-- =====================================================================
-- PASO 2: TUNING DINÁMICO + RECONSTRUCCIÓN CONCURRENTE (02:00 AM)
-- =====================================================================
SET maintenance_work_mem = '4GB';   -- Inyección de RAM por hilo para acelerar el B-Tree

CALL public.sp_orchestrate_reindex(
    p_scope            => 'SMART_USER',
    p_profile          => 'CONCURRENT',
    p_parallel_workers => 2,               -- 2 hilos paralelos para evitar contención de I/O
    p_cutoff_time      => '05:30:00'::TIME, -- [KILL SWITCH] Freno automático a las 05:30 AM
    p_frag_pct         => 20.00,           -- Solo reconstruye si fragmentación >= 20%
    p_verbose          => TRUE
);

RESET maintenance_work_mem;

```

---

### Escenario 2: Sanación de Emergencia de Índices Corruptos (`ZOMBIE_HUNTER`)

Ideal para ser ejecutado tras una falla del servidor o un proceso abortado que dejó índices inválidos en el catálogo.

```sql
-- Busca y reconstruye ÚNICAMENTE índices marcados con indisvalid = false
CALL public.sp_orchestrate_reindex(
    p_scope            => 'SMART_USER',
    p_profile          => 'ZOMBIE_HUNTER',
    p_parallel_workers => 4,
    p_verbose          => TRUE
);

```

---

## 📊 Tablero de Mando Ejecutivo (Dashboard)

Monitoreo consolidado C-Level para validar el resultado global de las ejecuciones de reindexación:

```sql
SELECT 
    j.job_id AS "ID Job",
    j.job_type AS "Perfil Ejecutado",
    j.status AS "Estado Final",
    j.parallel_workers AS "Hilos",
    j.tables_processed AS "Índices Exitosos",
    COUNT(t.task_id) AS "Total Candidatos",
    SUM(CASE WHEN t.is_invalid THEN 1 ELSE 0 END) AS "Zombis Curados",
    ROUND(EXTRACT(EPOCH FROM (j.ended_at - j.started_at))::numeric, 2) || ' seg' AS "Duración Total",
    j.started_at::TIME(0) AS "Inicio",
    j.ended_at::TIME(0) AS "Fin"
FROM public.maintenance_jobs j
LEFT JOIN public.mant_reindex_task t ON j.job_id = t.job_id
WHERE j.maintenance_action = 'REINDEX'
GROUP BY j.job_id, j.job_type, j.status, j.parallel_workers, j.tables_processed, j.started_at, j.ended_at
ORDER BY j.job_id DESC;

```
 
