BEGIN;

-- DROP SCHEMA  maint;
CREATE SCHEMA IF NOT EXISTS maint;

-- 1. TABLA PADRE: Orquestación Global
-- DROP TABLE IF EXISTS maint.jobs CASCADE;
-- TRUNCATE TABLE maint.jobs RESTART IDENTITY CASCADE ;
CREATE TABLE IF NOT EXISTS maint.jobs (
    job_id SERIAL PRIMARY KEY,                                 -- Identificador único secuencial del trabajo maestro de mantenimiento.
    job_type VARCHAR(50) NOT NULL,                             -- Tipo de trabajo y modo (ej. 'SMART', 'ALL', 'PRELOAD', 'SMART_USER_BALANCED').
    maintenance_action VARCHAR(20) NOT NULL DEFAULT 'ANALYZE', -- Acción core ejecutada ('ANALYZE' o 'VACUUM').
    threshold_pct NUMERIC DEFAULT 0.05,                        -- Umbral porcentual de cambio/basura utilizado para la selección.
    parallel_workers INT NOT NULL,                             -- Concurrencia máxima de hilos paralelos configurados.
    tables_processed INT NOT NULL DEFAULT 0,                   -- [Métrica RAM O(1)] Total de tablas completadas exitosamente en el trabajo.
    status VARCHAR(30) DEFAULT 'INITIALIZING',                 -- Estado del Job (INITIALIZING, RUNNING, COMPLETED, COMPLETED_WITH_CUTOFF).
    started_at TIMESTAMPTZ DEFAULT clock_timestamp(),          -- Marca de tiempo de inicio del orquestador.
    ended_at TIMESTAMPTZ                                       -- Marca de tiempo de finalización global del orquestador.
);

-- 3. ÍNDICE DE HERENCIA Y RENDIMIENTO
CREATE INDEX IF NOT EXISTS idx_maint_jobs_type_action_id 
ON maint.jobs (job_type, maintenance_action, job_id DESC);

-- 2. DICCIONARIO DE DATOS NATIVO (pg_description)
COMMENT ON TABLE  maint.jobs IS 'Cabecera maestra unificada que registra la ejecución global, estado, tipo de acción (ANALYZE/VACUUM) y métricas de cada ciclo de orquestación.';
COMMENT ON COLUMN maint.jobs.job_id IS 'Identificador único secuencial del trabajo maestro de mantenimiento.';
COMMENT ON COLUMN maint.jobs.job_type IS 'Modo o perfil de ejecución asignado al trabajo (ej. SMART, ALL, PRELOAD, SMART_USER_BALANCED).';
COMMENT ON COLUMN maint.jobs.maintenance_action IS 'Acción principal del motor de base de datos ejecutada (ej. ANALYZE, VACUUM).';
COMMENT ON COLUMN maint.jobs.threshold_pct IS 'Umbral porcentual de modificación (drift_pct) o tuplas muertas configurado para el disparo.';
COMMENT ON COLUMN maint.jobs.parallel_workers IS 'Límite de concurrencia de hilos/workers paralelos asignados al trabajo.';
COMMENT ON COLUMN maint.jobs.tables_processed IS 'Métrica de contador en memoria RAM del total de tablas analizadas o limpiadas con éxito.';
COMMENT ON COLUMN maint.jobs.status IS 'Estado global del trabajo (INITIALIZING, RUNNING, COMPLETED, COMPLETED_WITH_CUTOFF).';
COMMENT ON COLUMN maint.jobs.started_at IS 'Marca de tiempo (Timestamptz) de cuando inició el orquestador maestro.';
COMMENT ON COLUMN maint.jobs.ended_at IS 'Marca de tiempo (Timestamptz) de cuando concluyó la orquestación global.';

-- DROP TABLE IF EXISTS maint.filters CASCADE;
CREATE TABLE maint.filters (
    filter_id SERIAL PRIMARY KEY,                              
    schema_name VARCHAR(255) NOT NULL,                         
    table_name VARCHAR(255) NOT NULL,
    
    -- [CORRECCIÓN DIAMANTE] Columna con integridad de dominio estricta
    maintenance_action VARCHAR(50) NOT NULL DEFAULT 'ALL',                         
    is_ignored BOOLEAN NOT NULL DEFAULT FALSE,                 
    force_maintenance BOOLEAN NOT NULL DEFAULT FALSE,          
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(), 
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(), 
    updated_by VARCHAR(100) DEFAULT current_user,              
    
    -- REGLA 1: Evitar duplicidad de la misma acción para la misma tabla
    CONSTRAINT uq_maintenance_filters_schema_table_action UNIQUE (schema_name, table_name, maintenance_action),
    
    -- REGLA 2: [NUEVO] El candado del Gatekeeper. Solo admite estos 5 valores exactos.
    CONSTRAINT chk_valid_maintenance_action CHECK (
        maintenance_action IN ('ALL', 'VACUUM', 'VACUUM_FULL', 'ANALYZE', 'REINDEX')
    )
);

COMMENT ON CONSTRAINT chk_valid_maintenance_action ON maint.filters IS 'Candado de integridad: Previene errores tipográficos al registrar filtros de mantenimiento.';


 
-- 2. TABLA HIJA: Trazabilidad Forense por Tabla (CON TELEMETRÍA Y SLOTS)
-- DROP TABLE IF EXISTS maint.analyze_tasks CASCADE;
-- TRUNCATE TABLE maint.analyze_tasks RESTART IDENTITY ;
CREATE TABLE IF NOT EXISTS maint.analyze_tasks (
    task_id SERIAL PRIMARY KEY,
    job_id INT NOT NULL REFERENCES maint.jobs(job_id) ON DELETE CASCADE,
    schema_name TEXT NOT NULL,
    table_name TEXT NOT NULL,
    total_filas BIGINT,                  
    filas_afectadas BIGINT,              
    drift_pct NUMERIC(5,2),              
    status VARCHAR(20) DEFAULT 'PENDING', 
    --slot_id INT,                         
    child_pid INT,
    stage_number INT DEFAULT 1,
    started_at TIMESTAMPTZ,
    ended_at TIMESTAMPTZ,
    error_log TEXT
);

CREATE INDEX IF NOT EXISTS idx_analyze_task_active_queue 
ON maint.analyze_tasks (job_id, stage_number, task_id ASC)
WHERE status IN ('PENDING', 'RUNNING');

CREATE INDEX IF NOT EXISTS idx_analyze_task_forensic_trace 
ON maint.analyze_tasks (schema_name, table_name, ended_at DESC);

-- Índice Operativo Principal: Cubre Integridad Referencial (CASCADE), Filtros de Fase, Estados y Ordenamiento del Despachador.
CREATE INDEX IF NOT EXISTS idx_analyze_tasks_job_stage_status_id 
ON maint.analyze_tasks (job_id, stage_number, status, task_id);

-- 2. DICCIONARIO DE DATOS NATIVO (DOCUMENTACIÓN CORPORATIVA)
COMMENT ON TABLE  maint.analyze_tasks IS 'Cola transaccional y bitácora forense para la orquestación asíncrona de estadísticas (ANALYZE).';
COMMENT ON INDEX  maint.idx_analyze_task_active_queue IS 'Índice Parcial de Despacho. Mantiene un B-Tree ultraligero exclusivo para tareas vivas, ignorando el historial muerto para un polling de latencia cero.';
COMMENT ON INDEX  maint.idx_maint_jobs_type_action_id IS 'Acelera la búsqueda del último trabajo ejecutado (MAX job_id) para herencias de estado en milisegundos.';
COMMENT ON INDEX  maint.idx_analyze_task_forensic_trace IS 'Índice Forense. Permite a los DBAs auditar el historial de mantenimiento de una tabla específica en milisegundos, ordenado desde el más reciente.';
COMMENT ON INDEX  maint.idx_analyze_tasks_job_stage_status_id IS 'Índice central de despacho: Evita Seq Scans en DELETE CASCADE y optimiza radicalmente los bloqueos WHERE job_id = X AND stage_number = Y AND status = Z ORDER BY task_id LIMIT 1.';
COMMENT ON COLUMN maint.analyze_tasks.task_id IS 'Identificador único secuencial de la tarea individual por tabla.';
COMMENT ON COLUMN maint.analyze_tasks.job_id IS 'Llave foránea enlazada al registro maestro en jobs (ON DELETE CASCADE).';
COMMENT ON COLUMN maint.analyze_tasks.schema_name IS 'Nombre del esquema de base de datos donde reside la tabla objetivo.';
COMMENT ON COLUMN maint.analyze_tasks.table_name IS 'Nombre de la tabla física objetivo de la actualización de estadísticas.';
COMMENT ON COLUMN maint.analyze_tasks.total_filas IS 'Tuplas vivas (n_live_tup) estimadas al momento de encolar la tarea.';
COMMENT ON COLUMN maint.analyze_tasks.filas_afectadas IS 'Tuplas modificadas (n_mod_since_analyze) detectadas al momento de encolar.';
COMMENT ON COLUMN maint.analyze_tasks.drift_pct IS 'Porcentaje de desfase estadístico calculado (filas_afectadas / total_filas).';
COMMENT ON COLUMN maint.analyze_tasks.status IS 'Estado de la tarea (PENDING, RUNNING, SUCCESS, FAILED, SKIPPED_TIME_LIMIT).';
--COMMENT ON COLUMN maint.analyze_tasks.slot_id IS 'Identificador de la ranura de concurrencia asignada para la gestión estricta de hilos.';
COMMENT ON COLUMN maint.analyze_tasks.child_pid IS 'Identificador del proceso (PID) del worker de fondo lanzado en Linux.';
COMMENT ON COLUMN maint.analyze_tasks.stage_number IS 'Fase de ejecución actual (Vital para la orquestación escalonada del modo PRELOAD).';
COMMENT ON COLUMN maint.analyze_tasks.started_at IS 'Marca de tiempo del inicio de la ejecución individual de la tabla.';
COMMENT ON COLUMN maint.analyze_tasks.ended_at IS 'Marca de tiempo de finalización del análisis (éxito o fallo).';
COMMENT ON COLUMN maint.analyze_tasks.error_log IS 'Captura forense del mensaje nativo de error (SQLERRM) extraído de la memoria dinámica.';




-- DROP PROCEDURE IF EXISTS maint.sp_orchestrate_analyze(VARCHAR, VARCHAR, INT, BOOLEAN, NUMERIC, INT, INT, TIME, BOOLEAN);
CREATE OR REPLACE PROCEDURE maint.sp_orchestrate_analyze(
    p_scope VARCHAR DEFAULT 'SMART_USER',       -- 'SMART_USER', 'ALL_USER', 'CUSTOM_LIST', 'SMART_SYSTEM_USER', 'ALL_SYSTEM_USER', 'ALL_SYSTEM'
    p_profile VARCHAR DEFAULT 'NORMAL',          -- 'NORMAL', 'PRELOAD'
    p_parallel_workers INT DEFAULT 4,
    p_verbose BOOLEAN DEFAULT FALSE,
    p_threshold_pct NUMERIC DEFAULT 5.00,       -- 5.00 = 5% (Homologado con Vacuum)
    p_min_rows INT DEFAULT 1000,                -- Mínimo de cambios para evaluar
    p_force_rows INT DEFAULT 50000,             -- Filas modificadas para FORZAR analyze (NULL para desactivar)
    p_cutoff_time TIME DEFAULT NULL,            -- puedes usarlo asi '06:00:00'::TIME
    p_keep_history BOOLEAN DEFAULT TRUE         -- TRUE = Conserva auditoría; FALSE = Limpia tareas al finalizar
)
LANGUAGE plpgsql AS $$
DECLARE
    v_job_id INT; v_task_id INT; v_schema TEXT; v_table TEXT; v_child_pid INT;
    v_active_workers INT; v_pending_tasks INT; v_total_tasks INT := 0; v_raw_sql TEXT;
    v_start_time TIMESTAMPTZ := clock_timestamp(); r_finished RECORD;
    v_current_stage INT := 1; v_max_stages INT := 1;
    v_success_count INT := 0;
    
    -- Variables para construcción dinámica de SETs en la cadena del worker
    v_set_prefix TEXT := '';
    v_target_stat INT;
    v_param RECORD;
BEGIN
    PERFORM pg_catalog.set_config('client_min_messages', 'notice', false);
    PERFORM pg_catalog.set_config('search_path', 'maint, public, pg_temp', true);

    -- 1. Validar Perfil y determinar número de etapas
    IF UPPER(p_profile) = 'PRELOAD' THEN 
        v_max_stages := 3; 
    ELSIF UPPER(p_profile) <> 'NORMAL' THEN
        RAISE EXCEPTION 'CRÍTICO: El perfil "%" no es válido en maint.sp_orchestrate_analyze. Use "NORMAL" o "PRELOAD".', p_profile;
    END IF;

    -- 2. Intercepta SETs locales de la sesión SOLO si sufrieron cambios respecto a su reset_val
    FOR v_param IN (
        SELECT name, setting 
        FROM pg_settings 
        WHERE name IN ('maintenance_work_mem', 'vacuum_cost_delay', 'vacuum_buffer_usage_limit')
          AND setting IS DISTINCT FROM reset_val
    ) LOOP
        v_set_prefix := v_set_prefix || format('SET %I = %L; ', v_param.name, v_param.setting);
    END LOOP;

    IF p_verbose THEN
        RAISE INFO '=========================================================';
        RAISE INFO '[DBA SQUAD] INICIANDO ORQUESTADOR ANALYZE VANGUARD';
        RAISE INFO 'ALCANCE: % | PERFIL: % | HILOS: % | FASES: % | CUTOFF: % | HISTORIAL: %', 
                   p_scope, UPPER(p_profile), p_parallel_workers, v_max_stages, COALESCE(p_cutoff_time::TEXT, 'SIN LÍMITE'), p_keep_history;
        RAISE INFO '=========================================================';
    END IF;

    -- 3. Crear Job Padre
    INSERT INTO maint.jobs (job_type, maintenance_action, threshold_pct, parallel_workers, status)
    VALUES (p_scope || '_' || UPPER(p_profile), 'ANALYZE', p_threshold_pct, p_parallel_workers, 'RUNNING')
    RETURNING job_id INTO v_job_id;
    COMMIT;

    -- 4. BUCLE GLOBAL DE FASES (Soporta PRELOAD)
    WHILE v_current_stage <= v_max_stages LOOP

        IF p_verbose THEN
            RAISE INFO '---------------------------------------------------------';
            RAISE INFO '>>> INICIANDO FASE % DE % <<<', v_current_stage, v_max_stages;
            RAISE INFO '---------------------------------------------------------';
        END IF;

        -- POBLAR COLA PARA LA FASE ACTUAL CON INTEGRACIÓN CORREGIDA DE FILTROS Y ALCANCE
        INSERT INTO maint.analyze_tasks (job_id, schema_name, table_name, total_filas, filas_afectadas, drift_pct, stage_number)
        SELECT v_job_id, st.schemaname, st.relname, st.n_live_tup, COALESCE(st.n_mod_since_analyze, 0),
               ROUND((COALESCE(st.n_mod_since_analyze, 0)::numeric / NULLIF(st.n_live_tup, 0)) * 100, 2), v_current_stage
        FROM pg_stat_all_tables st
        LEFT JOIN LATERAL (
            SELECT is_ignored, force_maintenance 
            FROM maint.filters f 
            WHERE f.schema_name = st.schemaname AND f.table_name = st.relname 
              AND f.maintenance_action IN ('ALL', 'ANALYZE')
            ORDER BY CASE WHEN f.maintenance_action = 'ANALYZE' THEN 1 ELSE 2 END ASC LIMIT 1
        ) mf ON TRUE
        WHERE st.schemaname <> 'pg_toast' 
          AND COALESCE(mf.is_ignored, FALSE) = FALSE
          AND (
              (p_scope = 'CUSTOM_LIST' AND mf.force_maintenance = TRUE) OR
              (p_scope IN ('SMART_USER', 'ALL_USER') AND st.schemaname NOT IN ('pg_catalog', 'information_schema')) OR
              (p_scope IN ('SMART_SYSTEM_USER', 'ALL_SYSTEM_USER')) OR
              (p_scope = 'ALL_SYSTEM' AND st.schemaname IN ('pg_catalog', 'information_schema'))
          )
          AND (
              (p_scope LIKE 'SMART%' AND (
                  mf.force_maintenance = TRUE OR (
                      COALESCE(st.n_mod_since_analyze, 0) >= p_min_rows AND (
                          ((COALESCE(st.n_mod_since_analyze, 0)::numeric / NULLIF(st.n_live_tup, 0)) ) >= (p_threshold_pct / 100 )
                          OR (p_force_rows IS NOT NULL AND COALESCE(st.n_mod_since_analyze, 0) >= p_force_rows)
                      )
                  )
              )) OR
              (p_scope NOT LIKE 'SMART%')
          )
        ORDER BY COALESCE(st.n_mod_since_analyze, 0) DESC, st.n_live_tup DESC;
        COMMIT;

        SELECT COUNT(*) INTO v_total_tasks FROM maint.analyze_tasks WHERE job_id = v_job_id AND stage_number = v_current_stage;

        IF v_current_stage = 1 AND v_total_tasks = 0 THEN
            IF p_verbose THEN 
                RAISE INFO '---------------------------------------------------------';
                RAISE INFO '[✓] ORQUESTACIÓN FINALIZADA. Job % | Tablas procesadas: 0 / 0 (Sistema óptimo)', v_job_id;
                RAISE INFO '⏱️  Tiempo Total: %', (clock_timestamp() - v_start_time);
                RAISE INFO '=========================================================';
            END IF;
            UPDATE maint.jobs SET status = 'COMPLETED', ended_at = clock_timestamp(), tables_processed = 0 WHERE job_id = v_job_id;
            COMMIT; RETURN;
        END IF;

        -- 5. BUCLE DE DESPACHO ASÍNCRONO
        LOOP
            -- A. RECOLECTOR FORENSE
            FOR r_finished IN 
                SELECT task_id, child_pid, schema_name, table_name FROM maint.analyze_tasks 
                WHERE job_id = v_job_id AND stage_number = v_current_stage 
                  AND status = 'RUNNING' AND child_pid NOT IN (SELECT pid FROM pg_stat_activity WHERE backend_type = 'pg_background')
            LOOP
                BEGIN
                    PERFORM * FROM public.pg_background_result(r_finished.child_pid::INT) AS (result TEXT);

                    UPDATE maint.analyze_tasks SET status = 'SUCCESS', ended_at = clock_timestamp(), child_pid = NULL WHERE task_id = r_finished.task_id;
                    v_success_count := v_success_count + 1;
                    IF p_verbose THEN RAISE INFO '    [✓] ÉXITO (Fase %) -> %.%', v_current_stage, r_finished.schema_name, r_finished.table_name; END IF;
                EXCEPTION WHEN OTHERS THEN
                    UPDATE maint.analyze_tasks SET status = 'FAILED', ended_at = clock_timestamp(), error_log = SQLERRM, child_pid = NULL WHERE task_id = r_finished.task_id;
                    IF p_verbose THEN RAISE WARNING '    [X] FALLO EN %.%: %', r_finished.schema_name, r_finished.table_name, SQLERRM; END IF;
                END;
                COMMIT;
            END LOOP;

            -- B. FRENO DE EMERGENCIA (KILL-SWITCH)
            IF p_cutoff_time IS NOT NULL AND LOCALTIME >= p_cutoff_time THEN
                UPDATE maint.analyze_tasks SET status = 'SKIPPED_TIME_LIMIT', error_log = 'Cutoff Time Reached' 
                WHERE job_id = v_job_id AND stage_number = v_current_stage AND status = 'PENDING';
                COMMIT;
            END IF;

            -- C. EVALUACIÓN DE ESTADO
            SELECT COUNT(*) INTO v_active_workers FROM maint.analyze_tasks WHERE job_id = v_job_id AND stage_number = v_current_stage AND status = 'RUNNING';
            SELECT COUNT(*) INTO v_pending_tasks FROM maint.analyze_tasks WHERE job_id = v_job_id AND stage_number = v_current_stage AND status = 'PENDING';

            IF v_active_workers = 0 AND v_pending_tasks = 0 THEN 
                EXIT; -- Terminó la fase actual
            END IF;

            -- D. DESPACHADOR DE TAREAS
            WHILE v_active_workers < p_parallel_workers AND v_pending_tasks > 0 LOOP
                IF p_cutoff_time IS NOT NULL AND LOCALTIME >= p_cutoff_time THEN EXIT; END IF;

                SELECT task_id, schema_name, table_name INTO v_task_id, v_schema, v_table
                FROM maint.analyze_tasks
                WHERE job_id = v_job_id AND stage_number = v_current_stage AND status = 'PENDING' 
                ORDER BY task_id ASC LIMIT 1;

                IF v_task_id IS NOT NULL THEN
                    UPDATE maint.analyze_tasks SET status = 'RUNNING', started_at = clock_timestamp() WHERE task_id = v_task_id;
                    COMMIT;

                    -- Ensamblado dinámico de la consulta con SETs inline
                    v_raw_sql := v_set_prefix;

                    IF UPPER(p_profile) = 'PRELOAD' THEN
                        v_target_stat := CASE v_current_stage WHEN 1 THEN 1 WHEN 2 THEN 10 ELSE 100 END;
                        v_raw_sql := v_raw_sql || format('SET default_statistics_target = %s; ', v_target_stat);
                    END IF;

                    v_raw_sql := v_raw_sql || format('ANALYZE %I.%I;', v_schema, v_table);

                    v_child_pid := public.pg_background_launch(v_raw_sql);
                    UPDATE maint.analyze_tasks SET child_pid = v_child_pid WHERE task_id = v_task_id;
                    COMMIT;

                    IF p_verbose THEN RAISE INFO '    [>] LANZANDO (Fase %) PID % -> %.%', v_current_stage, v_child_pid, v_schema, v_table; END IF;
                    v_active_workers := v_active_workers + 1; v_pending_tasks := v_pending_tasks - 1;
                END IF;
            END LOOP;
            PERFORM pg_sleep(1);
        END LOOP;

        IF p_cutoff_time IS NOT NULL AND LOCALTIME >= p_cutoff_time THEN
            IF p_verbose THEN RAISE WARNING '[!] Ventana de mantenimiento excedida. Abortando fases restantes.'; END IF;
            EXIT; 
        END IF;

        v_current_stage := v_current_stage + 1;
    END LOOP;

    -- 6. CIERRE, REPORTE Y PURGA OPCIONAL
    IF EXISTS (SELECT 1 FROM maint.analyze_tasks WHERE job_id = v_job_id AND status = 'SKIPPED_TIME_LIMIT') THEN
        UPDATE maint.jobs SET status = 'COMPLETED_WITH_CUTOFF', ended_at = clock_timestamp(), tables_processed = v_success_count WHERE job_id = v_job_id;
    ELSE
        UPDATE maint.jobs SET status = 'COMPLETED', ended_at = clock_timestamp(), tables_processed = v_success_count WHERE job_id = v_job_id;
    END IF;

    -- Purga de la cola de tareas si el DBA no desea almacenar el historial de tareas
    IF NOT p_keep_history THEN
        DELETE FROM maint.analyze_tasks WHERE job_id = v_job_id;
        IF p_verbose THEN RAISE INFO '[ - ] Purga ejecutada: Registros de maint.analyze_tasks eliminados para el Job %.', v_job_id; END IF;
    END IF;

    COMMIT;

    IF p_verbose THEN
        RAISE INFO '---------------------------------------------------------';
        RAISE INFO '[✓] ORQUESTACIÓN FINALIZADA. Job % | Tablas procesadas: % / %', v_job_id, v_success_count, v_total_tasks;
        RAISE INFO '  Tiempo Total: %', (clock_timestamp() - v_start_time);
        RAISE INFO '=========================================================';
    END IF;
END;
$$;


REVOKE EXECUTE ON PROCEDURE maint.sp_orchestrate_analyze FROM PUBLIC;

COMMIT;
