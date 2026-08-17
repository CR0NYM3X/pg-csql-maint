/* =========================================================================================
   ██████╗ ██████╗  █████╗     ███████╗ ██████╗ ██╗   ██╗ █████╗ ██████╗ 
   ██╔══██╗██╔══██╗██╔══██╗    ██╔════╝██╔═══██╗██║   ██║██╔══██╗██╔══██╗
   ██║  ██║██████╔╝███████║    ███████╗██║   ██║██║   ██║███████║██║  ██║
   ██║  ██║██╔══██╗██╔══██║    ╚════██║██║▄▄ ██║██║   ██║██╔══██║██║  ██║
   ██████╔╝██████╔╝██║  ██║    ███████║╚██████╔╝╚██████╔╝██║  ██║██████╔╝
   ╚═════╝ ╚═════╝ ╚═╝  ╚═╝    ╚══════╝ ╚══▀▀═╝  ╚═════╝ ╚═╝  ╚═╝╚═════╝ 
                               VANGUARD BLACK-OPS
                               
   MÓDULO: Orquestador Asíncrono de Mantenimiento de Bases de Datos (Vacuum/Analyze)
   VERSIÓN: 2.0 (Grado Diamante)
   ARQUITECTURA: Multi-hilo, Resiliente, Forense, Libre de Subtransacciones.
   
   DESCRIPCIÓN: 
   Suite de mantenimiento avanzado que reemplaza el autovacuum tradicional para ventanas 
   críticas. Permite despachar hilos en segundo plano, capturar errores de forma aislada,
   evaluar fragmentación profunda y auto-recuperarse de bloqueos sin asfixiar el clúster.
========================================================================================= */
BEGIN;

-- DROP SCHEMA  maint;
CREATE SCHEMA IF NOT EXISTS maint;

-- =========================================================================================
-- [FASE 1]: EXTENSIONES DEL KERNEL DE POSTGRESQL
-- =========================================================================================
-- pgstattuple:   Requerida para el radar de triage. Inspecciona el mapa de espacio libre real.
-- pg_background: Requerida para orquestación. Permite lanzar Workers asíncronos y leer memoria DSM.
CREATE EXTENSION IF NOT EXISTS pgstattuple;
CREATE EXTENSION IF NOT EXISTS pg_background;



-- =========================================================================================
-- [FASE 2]: DICCIONARIO DE DATOS Y TELEMETRÍA (DDL)
-- =========================================================================================


-- =========================================================================================
-- 1. TABLA PADRE: Orquestación Global de Trabajos
-- =========================================================================================
/* 
 * PROPÓSITO: Cabecera maestra que registra la ejecución global, perfil, límites y estado 
 *            de cada ciclo de orquestación despachado por la herramienta.
 */
CREATE TABLE IF NOT EXISTS maint.jobs (
    job_id SERIAL PRIMARY KEY,                                 -- Identificador único secuencial del trabajo maestro de mantenimiento.
    job_type VARCHAR(50) NOT NULL,                             -- Combinación de Scope y Perfil ejecutado (ej. 'SMART_USER_BALANCED').
    maintenance_action VARCHAR(20) NOT NULL,                   -- Tipo de acción principal del motor (ej. 'VACUUM', 'ANALYZE').
    threshold_pct NUMERIC DEFAULT 0.05,                        -- Umbral porcentual de basura/espacio libre utilizado para la selección.
    parallel_workers INT NOT NULL,                             -- Número máximo de hilos/workers paralelos configurados para este job.
    tables_processed INT NOT NULL DEFAULT 0,                   -- [Métrica RAM] Conteo total de tablas completadas exitosamente.
    status VARCHAR(30) DEFAULT 'INITIALIZING',                 -- Estado global (INITIALIZING, RUNNING, COMPLETED, COMPLETED_WITH_CUTOFF).
    started_at TIMESTAMPTZ DEFAULT clock_timestamp(),          -- Fecha y hora exacta de inicio del trabajo de orquestación.
    ended_at TIMESTAMPTZ                                       -- Fecha y hora exacta de finalización global del trabajo.
);

-- Registros de documentación oficial en el diccionario de datos del motor (pg_description)
COMMENT ON TABLE maint.jobs IS 'Cabecera maestra que almacena el estado global, parámetros de ejecución y métricas de cada ciclo de orquestación.';
COMMENT ON COLUMN maint.jobs.job_id IS 'Identificador único secuencial del trabajo maestro de mantenimiento.';
COMMENT ON COLUMN maint.jobs.job_type IS 'Combinación del alcance (Scope) y perfil asignado al trabajo (ej. SMART_USER_BALANCED).';
COMMENT ON COLUMN maint.jobs.maintenance_action IS 'Acción principal ejecutada por el orquestador (ej. VACUUM, ANALYZE).';
COMMENT ON COLUMN maint.jobs.threshold_pct IS 'Umbral porcentual de tuplas muertas o espacio libre configurado para el disparo.';
COMMENT ON COLUMN maint.jobs.parallel_workers IS 'Límite de concurrencia máxima de procesos hijos asignados al trabajo.';
COMMENT ON COLUMN maint.jobs.tables_processed IS 'Métrica incrementada en memoria RAM del total de tablas procesadas con éxito.';
COMMENT ON COLUMN maint.jobs.status IS 'Estado actual del job (INITIALIZING, RUNNING, COMPLETED, COMPLETED_WITH_CUTOFF).';
COMMENT ON COLUMN maint.jobs.started_at IS 'Marca de tiempo (Timestamptz) de cuando inició el orquestador maestro.';
COMMENT ON COLUMN maint.jobs.ended_at IS 'Marca de tiempo (Timestamptz) de cuando concluyó la orquestación global.';


-- =========================================================================================
-- 2. TABLA HIJA: Cola Transaccional y Estado de Tareas
-- =========================================================================================
/* 
 * PROPÓSITO: Cola de trabajo detallada a nivel de tabla. Rastrea el progreso individual, 
 *            PIDs asignados y captura forense de errores de cada hilo en ejecución.
 */
CREATE TABLE IF NOT EXISTS maint.vacuum_tasks (
    task_id SERIAL PRIMARY KEY,                                -- Identificador único secuencial de la tarea individual por tabla.
    job_id INT NOT NULL REFERENCES maint.jobs(job_id) ON DELETE CASCADE, -- Referencia foránea al trabajo maestro al que pertenece.
    schema_name TEXT NOT NULL,                                 -- Nombre del esquema de la tabla procesada.
    table_name TEXT NOT NULL,                                  -- Nombre de la tabla objetivo del mantenimiento.
    n_live_tup BIGINT,                                         -- Cantidad estimada de tuplas vivas registradas al momento de encolar.
    n_dead_tup BIGINT,                                         -- Cantidad estimada de tuplas muertas registradas al momento de encolar.
    dead_pct NUMERIC(5,2),                                     -- Porcentaje calculado de tuplas muertas o espacio libre previo.
    status VARCHAR(30) DEFAULT 'PENDING',                      -- Estado de la tarea (PENDING, RUNNING, SUCCESS, FAILED, SKIPPED_TIME_LIMIT).
    child_pid INT,                                             -- PID del proceso worker de pg_background asignado a la ejecución.
    started_at TIMESTAMPTZ,                                    -- Fecha y hora en que el worker inició el mantenimiento de esta tabla.
    ended_at TIMESTAMPTZ,                                      -- Fecha y hora en que el worker concluyó la tarea (éxito o fallo).
    error_log TEXT                                             -- Captura forense del mensaje nativo de error (SQLERRM) devuelto si falló.
);

-- Registros de documentación oficial en el diccionario de datos del motor (pg_description)
COMMENT ON TABLE maint.vacuum_tasks IS 'Cola transaccional que almacena el desglose por tabla, duraciones, PIDs asignados y logs forenses de error.';
COMMENT ON COLUMN maint.vacuum_tasks.task_id IS 'Identificador único secuencial de la tarea individual por tabla.';
COMMENT ON COLUMN maint.vacuum_tasks.job_id IS 'Llave foránea enlazada al registro maestro en maintenance_jobs.';
COMMENT ON COLUMN maint.vacuum_tasks.schema_name IS 'Nombre del esquema de base de datos donde reside la tabla.';
COMMENT ON COLUMN maint.vacuum_tasks.table_name IS 'Nombre de la tabla física objetivo de la operación de mantenimiento.';
COMMENT ON COLUMN maint.vacuum_tasks.n_live_tup IS 'Estimación de tuplas activas/vivas en la tabla según pg_stat_all_tables al encolar.';
COMMENT ON COLUMN maint.vacuum_tasks.n_dead_tup IS 'Estimación de tuplas muertas/obsoletas en la tabla según pg_stat_all_tables al encolar.';
COMMENT ON COLUMN maint.vacuum_tasks.dead_pct IS 'Porcentaje de degradación o espacio perdido calculado para ponderar la prioridad.';
COMMENT ON COLUMN maint.vacuum_tasks.status IS 'Estado específico de la tarea (PENDING, RUNNING, SUCCESS, FAILED, SKIPPED_TIME_LIMIT).';
COMMENT ON COLUMN maint.vacuum_tasks.child_pid IS 'Identificador del proceso (PID) del worker de fondo lanzado por pg_background.';
COMMENT ON COLUMN maint.vacuum_tasks.started_at IS 'Marca de tiempo del inicio del mantenimiento individual de esta tabla.';
COMMENT ON COLUMN maint.vacuum_tasks.ended_at IS 'Marca de tiempo de finalización del mantenimiento individual de esta tabla.';
COMMENT ON COLUMN maint.vacuum_tasks.error_log IS 'Texto descriptivo del error nativo (SQLERRM) extraído de la memoria en caso de fallo.';


-- =========================================================================================
-- 3. TABLA DE CONTROL: Reglas y Filtros de Seguridad (Blacklist / Whitelist)
-- =========================================================================================
/* 
 * PROPÓSITO: Panel de reglas de seguridad e inmunidad. Define qué tablas están protegidas 
 *            totalmente (Kill Switch) y cuáles tienen pase VIP para ejecuciones dedicadas.
 */
CREATE TABLE IF NOT EXISTS maint.filters (
    filter_id SERIAL PRIMARY KEY,                              -- Identificador único de la regla de filtrado.
    schema_name VARCHAR(255) NOT NULL,                         -- Esquema objetivo de la regla de filtrado.
    table_name VARCHAR(255) NOT NULL,                          -- Tabla objetivo de la regla de filtrado.
    is_ignored BOOLEAN NOT NULL DEFAULT FALSE,                 -- [Kill Switch]: Si es TRUE, el orquestador jamás tocará esta tabla.
    force_maintenance BOOLEAN NOT NULL DEFAULT FALSE,          -- [Pase VIP]: Si es TRUE, permite inclusión en Scope CUSTOM_LIST.
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(), -- Fecha de creación de la regla de seguridad.
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(), -- Fecha de última modificación de la regla.
    updated_by VARCHAR(100) DEFAULT current_user,              -- Usuario de base de datos que creó o modificó el filtro.
    CONSTRAINT uq_maintenance_filters_schema_table UNIQUE (schema_name, table_name)
);

-- Registros de documentación oficial en el diccionario de datos del motor (pg_description)
COMMENT ON TABLE maint.filters IS 'Panel de control de seguridad para exclusión obligatoria (Kill Switch) o priorización VIP de tablas.';
COMMENT ON COLUMN maint.filters.filter_id IS 'Identificador único de la regla de filtrado de mantenimiento.';
COMMENT ON COLUMN maint.filters.schema_name IS 'Nombre del esquema aplicable a la regla de filtrado.';
COMMENT ON COLUMN maint.filters.table_name IS 'Nombre de la tabla aplicable a la regla de filtrado.';
COMMENT ON COLUMN maint.filters.is_ignored IS 'Flag de exclusión total (Kill Switch). Si es TRUE, la tabla es inmune al orquestador.';
COMMENT ON COLUMN maint.filters.force_maintenance IS 'Flag de priorización VIP. Si es TRUE, la tabla se incluye en el scope CUSTOM_LIST.';
COMMENT ON COLUMN maint.filters.created_at IS 'Marca de tiempo del registro original del filtro en el sistema.';
COMMENT ON COLUMN maint.filters.updated_at IS 'Marca de tiempo del último cambio aplicado a la regla de filtrado.';
COMMENT ON COLUMN maint.filters.updated_by IS 'Nombre del usuario/rol de PostgreSQL que configuró o modificó la regla.';


-- =========================================================================================
-- 4. TABLA DE TELEMETRÍA: Triage Predictivo de Fragmentación Profunda
-- =========================================================================================
/* 
 * PROPÓSITO: Almacén histórico del análisis de espacio libre en disco. Permite evaluar 
 *            periódocamente la ganancia real en GB antes de ejecutar un VACUUM FULL.
 */
CREATE TABLE IF NOT EXISTS maint.vacuum_full_triage (
    triage_id BIGSERIAL PRIMARY KEY,                           -- Identificador único secuencial del registro de triage.
    evaluation_week DATE NOT NULL DEFAULT date_trunc('week', current_date), -- Semana del año a la que pertenece la evaluación.
    schema_name VARCHAR(255) NOT NULL,                         -- Esquema de la tabla analizada.
    table_name VARCHAR(255) NOT NULL,                          -- Nombre de la tabla analizada.
    approx_scanned BOOLEAN NOT NULL DEFAULT FALSE,             -- Indica si la Fase 1 (Escaneo superficial rápido) fue completada.
    approx_evaluated_at TIMESTAMPTZ,                           -- Marca de tiempo en que se ejecutó el escaneo superficial.
    approx_table_len BIGINT,                                   -- Tamaño total en bytes de la tabla detectado en el escaneo superficial.
    approx_dead_tuple_percent NUMERIC(5,2),                    -- Porcentaje estimado de tuplas muertas en la Fase 1.
    approx_free_percent NUMERIC(5,2),                          -- Porcentaje estimado de espacio libre interno en la Fase 1.
    approx_scanned_percent NUMERIC(5,2),                       -- Porcentaje de páginas del disco analizadas durante la Fase 1.
    deep_scanned BOOLEAN NOT NULL DEFAULT FALSE,               -- Indica si la Fase 2 (Escaneo profundo e intensivo) fue requerida y ejecutada.
    deep_evaluated_at TIMESTAMPTZ,                             -- Marca de tiempo en que se ejecutó el escaneo profundo.
    deep_table_len BIGINT,                                     -- Tamaño total en bytes de la tabla validado en la Fase 2.
    deep_dead_tuple_percent NUMERIC(5,2),                      -- Porcentaje exacto de tuplas muertas calculado en la Fase 2.
    deep_free_percent NUMERIC(5,2),                            -- Porcentaje exacto de espacio libre interno recuperable validado en Fase 2.
    CONSTRAINT uq_triage_week_schema_table UNIQUE (evaluation_week, schema_name, table_name)
);

-- Registros de documentación oficial en el diccionario de datos del motor (pg_description)
COMMENT ON TABLE maint.vacuum_full_triage IS 'Histórico semanal de telemetría física para predecir y justificar ejecuciones de VACUUM FULL según espacio recuperable.';
COMMENT ON COLUMN maint.vacuum_full_triage.triage_id IS 'Identificador único secuencial de la evaluación de triage.';
COMMENT ON COLUMN maint.vacuum_full_triage.evaluation_week IS 'Fecha de inicio de la semana de evaluación (primer día de la semana).';
COMMENT ON COLUMN maint.vacuum_full_triage.schema_name IS 'Nombre del esquema de la tabla evaluada.';
COMMENT ON COLUMN maint.vacuum_full_triage.table_name IS 'Nombre de la tabla evaluada.';
COMMENT ON COLUMN maint.vacuum_full_triage.approx_scanned IS 'Bandera que confirma la ejecución de pgstattuple_approx (Fase 1 superficial).';
COMMENT ON COLUMN maint.vacuum_full_triage.approx_evaluated_at IS 'Timestamp de cuando se realizó la evaluación aproximada de Fase 1.';
COMMENT ON COLUMN maint.vacuum_full_triage.approx_table_len IS 'Longitud en bytes de la relación obtenida en la evaluación aproximada.';
COMMENT ON COLUMN maint.vacuum_full_triage.approx_dead_tuple_percent IS 'Porcentaje estimado de tuplas obsoletas según la vista aproximada.';
COMMENT ON COLUMN maint.vacuum_full_triage.approx_free_percent IS 'Porcentaje de espacio libre disponible internamente en las páginas según la Fase 1.';
COMMENT ON COLUMN maint.vacuum_full_triage.approx_scanned_percent IS 'Porcentaje de la tabla que fue escaneado físicamente en la aproximación.';
COMMENT ON COLUMN maint.vacuum_full_triage.deep_scanned IS 'Bandera que confirma la ejecución de pgstattuple profundo (Fase 2 bloqueante).';
COMMENT ON COLUMN maint.vacuum_full_triage.deep_evaluated_at IS 'Timestamp de cuando se realizó la evaluación profunda de Fase 2.';
COMMENT ON COLUMN maint.vacuum_full_triage.deep_table_len IS 'Longitud exacta en bytes de la relación confirmada por el análisis profundo.';
COMMENT ON COLUMN maint.vacuum_full_triage.deep_dead_tuple_percent IS 'Porcentaje exacto de tuplas muertas confirmado por la lectura de todas las páginas.';
COMMENT ON COLUMN maint.vacuum_full_triage.deep_free_percent IS 'Porcentaje exacto de espacio libre interno que solo un VACUUM FULL puede devolver al S.O.';


 
-- 1. ÍNDICE DE HERENCIA (Lectura Rápida)
CREATE INDEX IF NOT EXISTS idx_maint_jobs_type_action_id 
ON maint.jobs (job_type, maintenance_action, job_id DESC);

COMMENT ON INDEX maint.idx_maint_jobs_type_action_id IS 'Query Index: Acelera la búsqueda retrospectiva (MAX job_id) para heredar el estado de los mantenimientos previos.';


-- 2. ÍNDICE ESTRUCTURAL Y DE CRUCE (Protección DML y JOINs)
-- Importante: El orden inicia por job_id para proteger las operaciones ON DELETE CASCADE.
CREATE INDEX IF NOT EXISTS idx_vacuum_tasks_job_schema_tbl 
ON maint.vacuum_tasks (job_id, schema_name, table_name);

COMMENT ON INDEX maint.idx_vacuum_tasks_job_schema_tbl IS 'FK/JOIN Index: Mitiga Seq Scans durante el ON DELETE CASCADE del padre y optimiza el LEFT JOIN del historial.';


-- 3. ÍNDICE OPERATIVO DEL DESPACHADOR ASÍNCRONO (Protección de UPDATEs y Colas)
-- Importante: Ordenado lógicamente para optimizar el WHERE (job_id, status) y el ORDER BY (task_id).
CREATE INDEX IF NOT EXISTS idx_vacuum_tasks_job_status_id 
ON maint.vacuum_tasks (job_id, status, task_id);

COMMENT ON INDEX maint.idx_vacuum_tasks_job_status_id IS 'DML Index: Optimiza radicalmente los UPDATEs masivos (SKIPPED_TIME_LIMIT), los COUNT(*) de hilos y la selección LIMIT 1 de la cola.';





 
-- =========================================================================================
-- [FASE 3]: PROCEDIMIENTOS ALMACENADOS CORE
-- =========================================================================================

/* =========================================================================================
   PROCEDIMIENTO: maint.sp_populate_vacuum_triage
   FUNCIÓN: Escáner forense de dos etapas. Evalúa la fragmentación real física de las tablas.
   USO RECOMENDADO: Ejecutar una vez a la semana (Ej. Domingos 02:00 AM) antes de mantenimientos.
   
   PARÁMETROS:
   - p_scope              (VARCHAR) : Define qué esquemas evaluar ('ALL_USER', 'ALL_SYSTEM', 'CUSTOM_LIST').
   - p_free_pct_threshold (NUMERIC) : Gatillo Fase 2 -> Porcentaje de espacio libre estimado.
   - p_free_mb_threshold  (NUMERIC) : Gatillo Fase 2 -> Megabytes absolutos de espacio libre estimado.
   - p_dead_pct_threshold (NUMERIC) : Gatillo Fase 2 -> Porcentaje de tuplas muertas estimado.
   - p_min_table_mb       (NUMERIC) : Filtro Anti-Morralla. Ignora tablas que pesen menos de X MB.
   - p_verbose            (BOOLEAN) : Si es TRUE, imprime la bitácora operativa en consola.
========================================================================================= */
CREATE OR REPLACE PROCEDURE maint.sp_populate_vacuum_triage(
    p_scope VARCHAR DEFAULT 'ALL_USER',
    p_free_pct_threshold NUMERIC DEFAULT 15.00,
    p_free_mb_threshold NUMERIC DEFAULT 1024.00,
    p_dead_pct_threshold NUMERIC DEFAULT 20.00,
    p_min_table_mb NUMERIC DEFAULT 0.00,
    p_verbose BOOLEAN DEFAULT FALSE
)
LANGUAGE plpgsql AS $$
DECLARE
    r_table RECORD; r_approx RECORD; r_deep RECORD;
    v_week DATE := date_trunc('week', current_date)::DATE;
    v_processed INT := 0; v_sniped INT := 0;
    v_approx_free_mb NUMERIC;
BEGIN

   PERFORM pg_catalog.set_config('client_min_messages', 'notice', false);
   -- configuracion de seguridad
   PERFORM pg_catalog.set_config('search_path', 'public, pg_temp', true);
    -- Validar dependencia estricta del kernel
    IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pgstattuple') THEN
        RAISE EXCEPTION 'CRÍTICO: La extensión "pgstattuple" no está instalada.';
    END IF;

    IF p_verbose THEN
        RAISE INFO '=========================================================';
        RAISE INFO '[DBA SQUAD] RADAR DE TRIAGE DOMINICAL INICIADO';
        RAISE INFO 'SCOPE: % | IGNORANDO TABLAS MENORES A: % MB', p_scope, p_min_table_mb;
        RAISE INFO '=========================================================';
    END IF;

    -- [ITERADOR PRINCIPAL]: Selecciona candidatos basados en tamaño y reglas de negocio
    FOR r_table IN (
        SELECT c.oid AS table_oid, n.nspname AS schema_name, c.relname AS table_name
        FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
        LEFT JOIN maint.filters mf ON mf.schema_name = n.nspname AND mf.table_name = c.relname
        WHERE c.relkind IN ('r', 'm')
          AND n.nspname <> 'pg_toast'
          AND pg_relation_size(c.oid) >= (p_min_table_mb * 1024 * 1024)
          AND (
              (p_scope = 'CUSTOM_LIST' AND mf.force_maintenance = TRUE) OR
              (p_scope IN ('SMART_USER', 'ALL_USER') AND n.nspname NOT IN ('pg_catalog', 'information_schema')) OR
              (p_scope IN ('SMART_SYSTEM_USER', 'ALL_SYSTEM_USER')) OR
              (p_scope = 'ALL_SYSTEM' AND n.nspname IN ('pg_catalog', 'information_schema'))
          )
    ) LOOP
        BEGIN
            -- ETAPA 1: Radar Superficial (pgstattuple_approx). Bajo costo de I/O.
            SELECT * INTO r_approx FROM pgstattuple_approx(r_table.table_oid);

            -- Estampa o actualiza la telemetría semanal con el resultado superficial
            INSERT INTO maint.vacuum_full_triage (
                evaluation_week, schema_name, table_name, approx_scanned, approx_evaluated_at, approx_table_len, approx_dead_tuple_percent, approx_free_percent, approx_scanned_percent
            ) VALUES (
                v_week, r_table.schema_name, r_table.table_name, TRUE, clock_timestamp(), r_approx.table_len, r_approx.dead_tuple_percent, r_approx.approx_free_percent, r_approx.scanned_percent
            ) ON CONFLICT (evaluation_week, schema_name, table_name) DO UPDATE SET
                approx_scanned = TRUE, approx_evaluated_at = clock_timestamp(), approx_table_len = EXCLUDED.approx_table_len, approx_dead_tuple_percent = EXCLUDED.approx_dead_tuple_percent, approx_free_percent = EXCLUDED.approx_free_percent, approx_scanned_percent = EXCLUDED.approx_scanned_percent;

            v_processed := v_processed + 1;
            
            -- Cálculo de Masa Crítica: Espacio absoluto libre en MB
            v_approx_free_mb := (r_approx.table_len * (r_approx.approx_free_percent / 100.0)) / 1024 / 1024;

            -- ETAPA 2: El Francotirador (pgstattuple). Alto costo de I/O.
            -- Solo se ejecuta si la tabla presenta síntomas graves de fragmentación.
            IF r_approx.approx_free_percent >= p_free_pct_threshold
               OR v_approx_free_mb >= p_free_mb_threshold
               OR r_approx.dead_tuple_percent >= p_dead_pct_threshold
            THEN
                SELECT * INTO r_deep FROM pgstattuple(r_table.table_oid);
                
                UPDATE maint.vacuum_full_triage SET
                    deep_scanned = TRUE, deep_evaluated_at = clock_timestamp(), deep_table_len = r_deep.table_len, deep_dead_tuple_percent = r_deep.dead_tuple_percent, deep_free_percent = r_deep.free_percent
                WHERE evaluation_week = v_week AND schema_name = r_table.schema_name AND table_name = r_table.table_name;

                v_sniped := v_sniped + 1;
            END IF;

        EXCEPTION WHEN OTHERS THEN
            -- [Contención] Si una tabla está bloqueada, captura el warning y pasa a la siguiente.
            IF p_verbose THEN RAISE WARNING 'Error analizando %.%: %', r_table.schema_name, r_table.table_name, SQLERRM; END IF;
        END;
        COMMIT; -- Libera recursos transaccionales por iteración
    END LOOP;

    IF p_verbose THEN
        RAISE INFO '[✓] TRIAGE FINALIZADO. Tablas evaluadas: %, Escaneos profundos: %', v_processed, v_sniped;
    END IF;
END;
$$;


/* =========================================================================================
   PROCEDIMIENTO: maint.sp_orchestrate_vacuum
   FUNCIÓN: Motor asíncrono de Mantenimiento. Despacha workers y captura excepciones.
   USO RECOMENDADO: Ejecución diaria mediante CronJob o Scheduler durante ventanas valle.
   
   PARÁMETROS:
   - p_scope            (VARCHAR) : 'SMART_USER', 'CUSTOM_LIST', etc. Define a quién evaluar.
   - p_profile          (VARCHAR) : 'LIGHT', 'BALANCED', 'AGGRESSIVE', 'VACUUM_FULL', 'SMART_VACUUM_FULL'.
   - p_parallel_workers (INT)     : Cantidad máxima de conexiones/hilos en segundo plano a consumir.
   - p_cutoff_time      (TIME)    : [Opcional] Hora límite estricta (ej. '06:00'). Mata la orquestación si se excede.
   - p_verbose          (BOOLEAN) : Si es TRUE, imprime la bitácora operativa en consola.
   - p_threshold_pct    (NUMERIC) : Umbral de porcentaje de basura requerido para encolar la tabla.
   - p_min_dead_tup     (INT)     : Umbral absoluto de tuplas muertas para ignorar tablas microscópicas.
========================================================================================= */
CREATE OR REPLACE PROCEDURE maint.sp_orchestrate_vacuum(
    p_scope VARCHAR DEFAULT 'SMART_USER',
    p_profile VARCHAR DEFAULT 'BALANCED',
    p_parallel_workers INT DEFAULT 4,
    p_cutoff_time TIME DEFAULT NULL,
    p_verbose BOOLEAN DEFAULT FALSE,
    p_threshold_pct NUMERIC DEFAULT 0.05,
    p_min_dead_tup INT DEFAULT 5000
)
LANGUAGE plpgsql AS $$
DECLARE
    v_job_id INT; v_task_id INT; v_schema TEXT; v_table TEXT; v_child_pid INT;
    v_active_workers INT; v_pending_tasks INT; v_total_tasks INT; v_raw_sql TEXT;
    v_effective_workers INT := p_parallel_workers; r_finished RECORD; v_last_job_id INT;
    
    -- Variable en RAM O(1) para evitar conteos masivos a disco duro al final
    v_success_count INT := 0; 
BEGIN
   PERFORM pg_catalog.set_config('client_min_messages', 'notice', false);
   -- configuracion de seguridad
   PERFORM pg_catalog.set_config('search_path', 'maint, public, pg_temp', true);
   
    -- Regla de Negocio: VACUUM FULL es bloqueante exclusivo, se forza a 1 solo hilo de trabajo.
    IF p_profile IN ('VACUUM_FULL', 'SMART_VACUUM_FULL') THEN v_effective_workers := 1; END IF;

    -- [PASO 1]: Registrar el trabajo maestro
    INSERT INTO maint.jobs (job_type, maintenance_action, threshold_pct, parallel_workers, status)
    VALUES (p_scope || '_' || p_profile, 'VACUUM', p_threshold_pct, v_effective_workers, 'RUNNING') RETURNING job_id INTO v_job_id;
    COMMIT;

    -- Localizar el último trabajo similar para heredar la lógica de tareas pasadas (Skip Carryover)
    SELECT MAX(job_id) INTO v_last_job_id FROM maint.jobs WHERE job_type = (p_scope || '_' || p_profile) AND maintenance_action = 'VACUUM' AND job_id < v_job_id;

    -- [PASO 2]: Construir la Cola de Trabajo Dinámica
    -- Aplica algoritmos de negocio cruzando estadisticas nativas (pg_stat_all_tables), el triage dominical
    -- y las reglas de lista blanca/negra de seguridad (maintenance_filters).
    INSERT INTO maint.vacuum_tasks (job_id, schema_name, table_name, n_live_tup, n_dead_tup, dead_pct)
    SELECT v_job_id, st.schemaname, st.relname, st.n_live_tup, st.n_dead_tup, ROUND(COALESCE(vft.deep_free_percent, (st.n_dead_tup::numeric / NULLIF(st.n_live_tup + st.n_dead_tup, 0)) * 100), 2)
    FROM pg_stat_all_tables st
    LEFT JOIN maint.vacuum_tasks prev_t ON prev_t.job_id = v_last_job_id AND prev_t.schema_name = st.schemaname AND prev_t.table_name = st.relname
    LEFT JOIN maint.filters mf ON mf.schema_name = st.schemaname AND mf.table_name = st.relname
    LEFT JOIN maint.vacuum_full_triage vft ON vft.schema_name = st.schemaname AND vft.table_name = st.relname AND vft.evaluation_week = date_trunc('week', current_date)::DATE
    WHERE st.schemaname <> 'pg_toast' AND COALESCE(mf.is_ignored, FALSE) = FALSE
      AND (
          (p_scope = 'CUSTOM_LIST' AND mf.force_maintenance = TRUE) OR
          (p_scope IN ('SMART_USER', 'ALL_USER') AND st.schemaname NOT IN ('pg_catalog', 'information_schema')) OR
          (p_scope IN ('SMART_SYSTEM_USER', 'ALL_SYSTEM_USER')) OR
          (p_scope = 'ALL_SYSTEM' AND st.schemaname IN ('pg_catalog', 'information_schema'))
      )
      AND (
          (p_profile = 'SMART_VACUUM_FULL' AND vft.deep_scanned = TRUE AND vft.deep_free_percent >= (p_threshold_pct * 100)) OR
          (p_profile <> 'SMART_VACUUM_FULL' AND p_scope LIKE 'SMART%' AND st.n_dead_tup >= p_min_dead_tup AND ((st.n_dead_tup::numeric / NULLIF(st.n_live_tup + st.n_dead_tup, 0)) >= p_threshold_pct OR st.n_dead_tup >= 100000)) OR
          (p_profile <> 'SMART_VACUUM_FULL' AND p_scope NOT LIKE 'SMART%')
      )
    ORDER BY CASE WHEN prev_t.status = 'SKIPPED_TIME_LIMIT' THEN 0 ELSE 1 END ASC, CASE WHEN p_profile = 'SMART_VACUUM_FULL' THEN COALESCE(vft.deep_free_percent, 0) ELSE 0 END DESC, COALESCE(st.last_vacuum, '1970-01-01'::timestamptz) ASC, st.n_dead_tup DESC;
    COMMIT;

    -- Validar si la cola de trabajo quedó vacía
    SELECT COUNT(*) INTO v_total_tasks FROM maint.vacuum_tasks WHERE job_id = v_job_id;
    IF v_total_tasks = 0 THEN
        UPDATE maint.jobs SET status = 'COMPLETED', ended_at = clock_timestamp(), tables_processed = 0 WHERE job_id = v_job_id;
        IF p_verbose THEN RAISE INFO '[!] No hay tablas candidatas que cumplan los filtros actuales.'; END IF;
        COMMIT; RETURN;
    END IF;

    -- =========================================================================
    -- [PASO 3]: MOTOR ASÍNCRONO Y DE AUTORRECUPERACIÓN
    -- =========================================================================
    LOOP
        -- 3A. MÓDULO FORENSE: Buscar PIDs que estaban corriendo y desaparecieron del S.O.
        FOR r_finished IN (
            SELECT task_id, child_pid, schema_name, table_name 
            FROM maint.vacuum_tasks 
            WHERE job_id = v_job_id AND status = 'RUNNING' 
            AND child_pid NOT IN (SELECT pid FROM pg_stat_activity WHERE backend_type = 'pg_background')
        ) LOOP
            BEGIN
                -- Interceptar la Memoria Dinámica Compartida (DSM) del proceso muerto.
                -- Si el proceso falló (Ej. Error de Sintaxis o Transacción), lanzará una EXCEPTION nativa aquí.
                PERFORM * FROM public.pg_background_result(r_finished.child_pid) AS (result TEXT);

                -- Si cruza la línea anterior, fue Éxito Absoluto
                UPDATE maint.vacuum_tasks 
                SET status = 'SUCCESS', ended_at = clock_timestamp(), child_pid = NULL 
                WHERE task_id = r_finished.task_id;
                
                v_success_count := v_success_count + 1; -- Conteo en RAM para máxima velocidad
                IF p_verbose THEN RAISE INFO '    [✓] TAREA COMPLETADA -> %.%', r_finished.schema_name, r_finished.table_name; END IF;

            EXCEPTION WHEN OTHERS THEN
                -- Si falló, capturamos el SQLERRM (El mensaje exacto de PostgreSQL) y lo estampamos en la tabla
                UPDATE maint.vacuum_tasks 
                SET status = 'FAILED', ended_at = clock_timestamp(), error_log = SQLERRM, child_pid = NULL 
                WHERE task_id = r_finished.task_id;
                
                IF p_verbose THEN RAISE WARNING '    [X] FALLO EN %.%: %', r_finished.schema_name, r_finished.table_name, SQLERRM; END IF;
            END;
            COMMIT; -- Asegurar la escritura del log forense de inmediato
        END LOOP;

        -- 3B. KILL-SWITCH TEMPORAL: Respeto estricto de ventanas de mantenimiento
        IF p_cutoff_time IS NOT NULL AND LOCALTIME >= p_cutoff_time THEN
            UPDATE maint.vacuum_tasks SET status = 'SKIPPED_TIME_LIMIT', error_log = 'Cutoff Time' WHERE job_id = v_job_id AND status = 'PENDING'; 
            COMMIT;
        END IF;

        -- 3C. EVALUACIÓN DE ESTADO: Contar cuántos hilos están ocupados y cuántos esperan
        SELECT COUNT(*) INTO v_active_workers FROM maint.vacuum_tasks WHERE job_id = v_job_id AND status = 'RUNNING';
        SELECT COUNT(*) INTO v_pending_tasks FROM maint.vacuum_tasks WHERE job_id = v_job_id AND status = 'PENDING';
        
        -- Si ya no hay hilos operando ni tareas esperando, cerrar la fábrica.
        IF v_active_workers = 0 AND v_pending_tasks = 0 THEN EXIT; END IF;

        -- 3D. DESPACHADOR (DISPATCHER): Lanzar nuevos hilos si hay cupo en el worker pool
        WHILE v_active_workers < v_effective_workers AND v_pending_tasks > 0 LOOP
            IF p_cutoff_time IS NOT NULL AND LOCALTIME >= p_cutoff_time THEN EXIT; END IF;

            SELECT task_id, schema_name, table_name INTO v_task_id, v_schema, v_table FROM maint.vacuum_tasks WHERE job_id = v_job_id AND status = 'PENDING' ORDER BY task_id ASC LIMIT 1;
            
            IF v_task_id IS NOT NULL THEN
                UPDATE maint.vacuum_tasks SET status = 'RUNNING', started_at = clock_timestamp() WHERE task_id = v_task_id; COMMIT;

                -- Inyección dinámica del comando exacto según el perfil seleccionado
                IF p_profile = 'LIGHT' THEN v_raw_sql := format('VACUUM (SKIP_LOCKED ON, INDEX_CLEANUP OFF) %I.%I;', v_schema, v_table);
                ELSIF p_profile = 'BALANCED' THEN v_raw_sql := format('VACUUM (INDEX_CLEANUP AUTO) %I.%I;', v_schema, v_table);
                ELSIF p_profile = 'AGGRESSIVE' THEN v_raw_sql := format('VACUUM (INDEX_CLEANUP AUTO, PARALLEL 4, ANALYZE) %I.%I;', v_schema, v_table);
                ELSIF p_profile IN ('VACUUM_FULL', 'SMART_VACUUM_FULL') THEN v_raw_sql := format('VACUUM FULL %I.%I;', v_schema, v_table); END IF;

                -- Lanzar asíncronamente y registrar el PID para monitoreo forense posterior
                v_child_pid := public.pg_background_launch(v_raw_sql);
                UPDATE maint.vacuum_tasks SET child_pid = v_child_pid WHERE task_id = v_task_id; COMMIT;

                IF p_verbose THEN RAISE INFO '    [>] LANZANDO [%] PID % -> %.%', p_profile, v_child_pid, v_schema, v_table; END IF;
                v_active_workers := v_active_workers + 1; v_pending_tasks := v_pending_tasks - 1;
            END IF;
        END LOOP;
        
        -- Ciclo de respiro (Tick rate) del orquestador (Evita saturar CPU)
        PERFORM pg_sleep(1);
    END LOOP;

    -- =========================================================================
    -- [PASO 4]: CIERRE Y ESTAMPADO DE MÉTRICAS GLOBALES
    -- =========================================================================
    IF EXISTS (SELECT 1 FROM maint.vacuum_tasks WHERE job_id = v_job_id AND status = 'SKIPPED_TIME_LIMIT') THEN
        UPDATE maint.jobs SET status = 'COMPLETED_WITH_CUTOFF', ended_at = clock_timestamp(), tables_processed = v_success_count WHERE job_id = v_job_id;
    ELSE
        UPDATE maint.jobs SET status = 'COMPLETED', ended_at = clock_timestamp(), tables_processed = v_success_count WHERE job_id = v_job_id;
    END IF;
    COMMIT;
    
    IF p_verbose THEN RAISE INFO '[✓] ORQUESTACIÓN FINALIZADA. Job % | Procesadas: % / %', v_job_id, v_success_count, v_total_tasks; END IF;
END;
$$;


REVOKE EXECUTE ON PROCEDURE maint.sp_orchestrate_vacuum FROM PUBLIC;
REVOKE EXECUTE ON PROCEDURE maint.sp_populate_vacuum_triage FROM PUBLIC;


COMMIT;
