/* =========================================================================================
   ██████╗ ██████╗  █████╗     ███████╗ ██████╗ ██╗   ██╗ █████╗ ██████╗ 
   ██╔══██╗██╔══██╗██╔══██╗    ██╔════╝██╔═══██╗██║   ██║██╔══██╗██╔══██╗
   ██║  ██║██████╔╝███████║    ███████╗██║   ██║██║   ██║███████║██║  ██║
   ██║  ██║██╔══██╗██╔══██║    ╚════██║██║▄▄ ██║██║   ██║██╔══██║██║  ██║
   ██████╔╝██████╔╝██║  ██║    ███████║╚██████╔╝╚██████╔╝██║  ██║██████╔╝
   ╚═════╝ ╚═════╝ ╚═╝  ╚═╝    ╚══════╝ ╚══▀▀═╝  ╚═════╝ ╚═╝  ╚═╝╚═════╝ 
                               VANGUARD BLACK-OPS
                               
   MÓDULO: Orquestador Asíncrono de Mantenimiento de Bases de Datos (Vacuum/Analyze)
   VERSIÓN: 3.0 (Grado Diamante - Smart Triage & Dummy Orchestrator)
   ARQUITECTURA: Multi-hilo, Resiliente, Forense, Libre de Subtransacciones.
========================================================================================= */
BEGIN;

-- DROP SCHEMA  maint CASCADE;
CREATE SCHEMA IF NOT EXISTS maint;

-- =========================================================================================
-- [FASE 1]: EXTENSIONES DEL KERNEL DE POSTGRESQL
-- =========================================================================================
CREATE EXTENSION IF NOT EXISTS pgstattuple;
CREATE EXTENSION IF NOT EXISTS pg_background;
 
-- =========================================================================================
-- 1. TABLA PADRE: Orquestación Global de Trabajos
-- =========================================================================================
-- 1. Crear la tabla maestra de control con soporte para Orchestrator PID y Parámetros Universal JSONB
CREATE TABLE IF NOT EXISTS maint.jobs (
    job_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    job_type VARCHAR(50) NOT NULL,              -- Ej. 'SMART_USER_NORMAL', 'ALL_USER_PRELOAD'
    maintenance_action VARCHAR(20) NOT NULL,    -- 'ANALYZE', 'VACUUM', 'VACUUM_FULL', 'REINDEX'
    orchestrator_pid INT NOT NULL,              -- PID del proceso principal (Padre) para Self-Healing de 2 niveles
    execution_params JSONB NOT NULL,             -- Fotografía inmutable de los 8/9 parámetros de la invocación
    status VARCHAR(30) NOT NULL DEFAULT 'RUNNING',-- 'RUNNING', 'COMPLETED', 'COMPLETED_WITH_CUTOFF', 'ABORTED_ORPHAN', 'CANCELLED_BY_USER'
    tables_processed INT DEFAULT 0,             -- Cantidad real de tablas intervenidas exitosamente
    started_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    ended_at TIMESTAMPTZ                        -- Sello de tiempo final cuando concluye o se reconcilia
);

-- 2. Índice táctico para acelerar la auto-sanación de Jobs colgados al inicio de cada ejecución
CREATE INDEX IF NOT EXISTS idx_jobs_status_action 
ON maint.jobs (status, maintenance_action) 
WHERE status = 'RUNNING';

COMMENT ON TABLE maint.jobs IS 'Cabecera maestra que almacena el estado global, parámetros de ejecución y métricas de cada ciclo de orquestación.';
COMMENT ON COLUMN maint.jobs.job_id IS 'Identificador único secuencial del trabajo maestro de mantenimiento.';
COMMENT ON COLUMN maint.jobs.job_type IS 'Combinación del alcance (Scope) y perfil asignado al trabajo (ej. SMART_USER_BALANCED).';
COMMENT ON COLUMN maint.jobs.maintenance_action IS 'Acción principal ejecutada por el orquestador (ej. VACUUM, ANALYZE).';
COMMENT ON COLUMN maint.jobs.tables_processed IS 'Métrica incrementada en memoria RAM del total de tablas procesadas con éxito.';
COMMENT ON COLUMN maint.jobs.status IS 'Estado actual del job (INITIALIZING, RUNNING, COMPLETED, COMPLETED_WITH_CUTOFF).';
COMMENT ON COLUMN maint.jobs.started_at IS 'Marca de tiempo (Timestamptz) de cuando inició el orquestador maestro.';
COMMENT ON COLUMN maint.jobs.ended_at IS 'Marca de tiempo (Timestamptz) de cuando concluyó la orquestación global.';

-- =========================================================================================
-- 2. TABLA HIJA: Cola Transaccional y Estado de Tareas
-- =========================================================================================
CREATE TABLE IF NOT EXISTS maint.vacuum_tasks (
    task_id SERIAL PRIMARY KEY,                                
    job_id INT NOT NULL REFERENCES maint.jobs(job_id) ON DELETE CASCADE, 
    schema_name TEXT NOT NULL,                                 
    table_name TEXT NOT NULL,                                  
    n_live_tup BIGINT,                                         
    n_dead_tup BIGINT,                                         
    dead_pct NUMERIC(5,2),                                     
    status VARCHAR(30) DEFAULT 'PENDING',                      
    child_pid INT,                                             
    started_at TIMESTAMPTZ,                                    
    ended_at TIMESTAMPTZ,                                      
    error_log TEXT                                             
);

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
-- DROP TABLE IF EXISTS maint.filters CASCADE;
CREATE TABLE IF NOT EXISTS maint.filters (
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



CREATE TABLE maint.vacuum_profiles (
    profile_name VARCHAR(50) PRIMARY KEY, -- Ej: 'LIGHT', 'BALANCED', 'FREEZE_HEAVY'
    description TEXT,
    
    -- Parámetros Nativos de VACUUM (Fuertemente Tipados = Cero SQLi)
    is_analyze BOOLEAN DEFAULT FALSE,
    is_freeze BOOLEAN DEFAULT FALSE,
    skip_locked BOOLEAN DEFAULT TRUE,
    is_verbose BOOLEAN DEFAULT FALSE,
    index_cleanup VARCHAR(10) DEFAULT 'AUTO', -- Solo admitirá AUTO, ON, OFF
    truncate_pages BOOLEAN DEFAULT TRUE,
    parallel_workers INT DEFAULT 0, -- 0 significa sin PARALLEL
    
    -- Candados de Seguridad y Auditoría
    created_at TIMESTAMPTZ DEFAULT clock_timestamp(),
    updated_by VARCHAR(100) DEFAULT current_user,
    
    CONSTRAINT chk_index_cleanup CHECK (index_cleanup IN ('AUTO', 'ON', 'OFF')),
    CONSTRAINT chk_parallel_limit CHECK (parallel_workers BETWEEN 0 AND 32)
);

-- Inserción de los Perfiles Base del Escuadrón:
-- Inserción de los Perfiles Base del Escuadrón
INSERT INTO maint.vacuum_profiles (profile_name, description, skip_locked, index_cleanup, is_analyze, parallel_workers) VALUES 
('LIGHT', 'Perfil inofensivo. Salta bloqueos y no limpia índices.', TRUE, 'OFF', FALSE, 0),
('BALANCED', 'Perfil estándar. Limpia índices automáticamente.', FALSE, 'AUTO', FALSE, 0),
('AGGRESSIVE', 'Perfil profundo. Fuerza hilos paralelos y actualiza estadísticas.', FALSE, 'AUTO', TRUE, 4);



-- Índices Originales
CREATE INDEX IF NOT EXISTS idx_maint_jobs_type_action_id 
ON maint.jobs (job_type, maintenance_action, job_id DESC);

CREATE INDEX IF NOT EXISTS idx_vacuum_tasks_job_schema_tbl 
ON maint.vacuum_tasks (job_id, schema_name, table_name);

CREATE INDEX IF NOT EXISTS idx_vacuum_tasks_job_status_id 
ON maint.vacuum_tasks (job_id, status, task_id);


/* =========================================================================================
   PROCEDIMIENTO: maint.sp_orchestrate_vacuum
========================================================================================= */
-- DROP PROCEDURE IF EXISTS maint.sp_orchestrate_vacuum(VARCHAR, VARCHAR, INT, TIME, BOOLEAN, NUMERIC, INT);
CREATE OR REPLACE PROCEDURE maint.sp_orchestrate_vacuum(
    p_scope VARCHAR DEFAULT 'SMART_USER',       -- 'SMART_USER', 'ALL_USER', 'CUSTOM_LIST', 'SMART_SYSTEM_USER', 'ALL_SYSTEM_USER', 'ALL_SYSTEM'
    p_profile VARCHAR DEFAULT 'BALANCED',        -- 'LIGHT', 'BALANCED', 'AGGRESSIVE'
    p_parallel_workers INT DEFAULT 4,
    p_cutoff_time TIME DEFAULT NULL,
    p_verbose BOOLEAN DEFAULT FALSE,
    p_threshold_pct NUMERIC DEFAULT 5.00,       -- 5.00 = 5% (Homologado con Analyze)
    p_min_dead_rows INT DEFAULT 5000,            -- Mínimo de tuplas muertas para evaluar
    p_force_dead_rows INT DEFAULT 50000,         -- Tuplas muertas para FORZAR entrada (NULL para desactivar)
    p_keep_history BOOLEAN DEFAULT TRUE         -- TRUE = Conserva auditoría; FALSE = Purga detalles al terminar
)
LANGUAGE plpgsql AS $$
DECLARE
    v_job_id INT; v_task_id INT; v_schema TEXT; v_table TEXT; v_child_pid INT;
    v_active_workers INT; v_pending_tasks INT; v_total_tasks INT := 0; 
    v_raw_sql TEXT; v_options_str TEXT;
    v_start_time TIMESTAMPTZ := clock_timestamp(); r_finished RECORD;
    v_success_count INT := 0;
    
    -- Variables para lectura de perfil dinámico y telemetría
    r_profile RECORD;
    v_execution_params JSONB;

    -- Variables para interceptar SETs locales y transmitirlos a los workers (TU LÓGICA INTACTA)
    v_param RECORD;
    v_changed_params TEXT[] := '{}';
BEGIN
    PERFORM pg_catalog.set_config('client_min_messages', 'notice', false);
    PERFORM pg_catalog.set_config('search_path', 'maint, public, pg_temp', true);

    -- =====================================================================
    -- INTERCEPCIÓN DE PARÁMETROS DE SESIÓN AL INICIO (LÓGICA CLIENTE RESERVADA)
    -- =====================================================================
    FOR v_param IN (
        SELECT name, setting 
        FROM pg_settings 
        WHERE name IN ('max_parallel_maintenance_workers', 'maintenance_work_mem', 'vacuum_cost_delay')
          AND setting IS DISTINCT FROM reset_val
    ) LOOP
        EXECUTE format('ALTER ROLE %I SET %I = %L', current_user, v_param.name, v_param.setting);
        v_changed_params := array_append(v_changed_params, v_param.name);
    END LOOP;

    IF array_length(v_changed_params, 1) > 0 THEN
        COMMIT; -- Forzamos commit para que los futuros background workers lean la nueva config del rol
    END IF;
    -- =====================================================================

    -- 1-A. VALIDACIÓN ESTRICTA DEL PERFIL DINÁMICO
    SELECT * INTO r_profile FROM maint.vacuum_profiles WHERE UPPER(profile_name) = UPPER(p_profile);
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CRITICO: El perfil "%" no existe en la tabla maint.vacuum_profiles.', p_profile;
    END IF;

    -- 1-B. SELF-HEALING Y RECONCILIACIÓN ESTRUCTURAL DE JOBS Y WORKERS HUÉRFANOS
    -- Paso A: Identificar Jobs cuyo Padre murió Y cuyos Hijos ya no están activos en pg_stat_activity
    WITH dead_parent_jobs AS (
        SELECT j.job_id 
        FROM maint.jobs j
        WHERE j.status = 'RUNNING' 
          AND j.maintenance_action = 'VACUUM'
          -- CANDADO DE PADRE: Valida PID + Firma de Código + Estado Activo (Compatible con pg_cron y CLI)
          AND NOT EXISTS (
              SELECT 1 FROM pg_stat_activity a 
              WHERE a.pid = j.orchestrator_pid 
                AND a.query ILIKE '%sp_orchestrate_vacuum%'
                AND a.state != 'idle'
          )
          -- CANDADO DE HIJOS: Valida que no queden trabajadores pg_background procesando tareas de vacuum
          AND NOT EXISTS (
              SELECT 1 FROM maint.vacuum_tasks t
              JOIN pg_stat_activity a ON a.pid = t.child_pid
              WHERE t.job_id = j.job_id 
                AND t.status = 'RUNNING'
                AND a.backend_type = 'pg_background'
                AND a.query ILIKE 'VACUUM %'
          )
    )
    -- Actualizar tareas congeladas de Jobs huérfanos
    UPDATE maint.vacuum_tasks 
    SET status = 'ABORTED_ORPHAN', 
        ended_at = clock_timestamp(),
        error_log = 'Orchestrator process died. Task completed or abandoned without live collector.'
    WHERE status IN ('PENDING', 'RUNNING')
      AND job_id IN (SELECT job_id FROM dead_parent_jobs);

    -- Paso B: Cerrar y adjudicar el estado final en el Job Padre
    WITH dead_parent_jobs AS (
        SELECT j.job_id 
        FROM maint.jobs j
        WHERE j.status = 'RUNNING' 
          AND j.maintenance_action = 'VACUUM'
          AND NOT EXISTS (
              SELECT 1 FROM pg_stat_activity a 
              WHERE a.pid = j.orchestrator_pid 
                AND a.query ILIKE '%sp_orchestrate_vacuum%'
                AND a.state != 'idle'
          )
          AND NOT EXISTS (
              SELECT 1 FROM maint.vacuum_tasks t
              JOIN pg_stat_activity a ON a.pid = t.child_pid
              WHERE t.job_id = j.job_id 
                AND t.status = 'RUNNING'
                AND a.backend_type = 'pg_background'
                AND a.query ILIKE 'VACUUM %'
          )
    )
    UPDATE maint.jobs 
    SET status = 'ABORTED_ORPHAN', 
        ended_at = clock_timestamp(),
        tables_processed = (
            SELECT COUNT(*) FROM maint.vacuum_tasks 
            WHERE job_id = maint.jobs.job_id AND status = 'SUCCESS'
        )
    WHERE job_id IN (SELECT job_id FROM dead_parent_jobs);

    COMMIT;

    IF p_verbose THEN
        RAISE INFO '=========================================================';
        RAISE INFO '[DBA SQUAD] INICIANDO ORQUESTADOR VACUUM VANGUARD';
        RAISE INFO 'ALCANCE: % | PERFIL: % | HILOS: % | CUTOFF: % | HISTORIAL: %', 
                   p_scope, UPPER(p_profile), p_parallel_workers, COALESCE(p_cutoff_time::TEXT, 'SIN LIMITE'), p_keep_history;
        RAISE INFO '=========================================================';
    END IF;

    -- 2. Embalar parámetros para almacenamiento dinámico en maint.jobs (JSONB)
    v_execution_params := jsonb_build_object(
        'scope', p_scope,
        'profile', UPPER(p_profile),
        'parallel_workers', p_parallel_workers,
        'threshold_pct', p_threshold_pct,
        'min_dead_tup', p_min_dead_rows,
        'force_dead_tup', p_force_dead_rows,
        'cutoff_time', p_cutoff_time,
        'keep_history', p_keep_history
    );

    -- Crear Job Padre registrando el PID actual (pg_backend_pid) y el esquema universal JSONB
    INSERT INTO maint.jobs (job_type, maintenance_action, orchestrator_pid, execution_params, status)
    VALUES (p_scope || '_' || UPPER(p_profile), 'VACUUM', pg_backend_pid(), v_execution_params, 'RUNNING')
    RETURNING job_id INTO v_job_id;
    COMMIT;

    -- 3. POBLAR COLA DE TAREAS (TRIAGE CON BYPASS VIP Y FILTRO DE FUERZA BRUTA)
    INSERT INTO maint.vacuum_tasks (job_id, schema_name, table_name, n_live_tup, n_dead_tup, dead_pct)
    SELECT v_job_id, st.schemaname, st.relname, st.n_live_tup, st.n_dead_tup, 
           ROUND(COALESCE((st.n_dead_tup::numeric / NULLIF(st.n_live_tup + st.n_dead_tup, 0)) * 100, 0.00), 2)
    FROM pg_stat_all_tables st
    LEFT JOIN LATERAL (
        SELECT is_ignored, force_maintenance 
        FROM maint.filters f 
        WHERE f.schema_name = st.schemaname AND f.table_name = st.relname 
          AND f.maintenance_action IN ('ALL', 'VACUUM')
        ORDER BY CASE WHEN f.maintenance_action = 'VACUUM' THEN 1 ELSE 2 END ASC LIMIT 1
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
                  st.n_dead_tup >= p_min_dead_rows AND (
                      ((st.n_dead_tup::numeric / NULLIF(st.n_live_tup + st.n_dead_tup, 0)) * 100.0) >= p_threshold_pct
                      OR (p_force_dead_rows IS NOT NULL AND st.n_dead_tup >= p_force_dead_rows)
                  )
              )
          )) OR
          (p_scope NOT LIKE 'SMART%')
      )
    ORDER BY COALESCE(st.n_dead_tup, 0) DESC, st.n_live_tup DESC;
    COMMIT;

    SELECT COUNT(*) INTO v_total_tasks FROM maint.vacuum_tasks WHERE job_id = v_job_id;

    -- SALIDA TEMPRANA (Sistema óptimo sin candidatas)
    IF v_total_tasks = 0 THEN
        UPDATE maint.jobs SET status = 'COMPLETED', ended_at = clock_timestamp(), tables_processed = 0 WHERE job_id = v_job_id;
        
        IF p_verbose THEN 
            RAISE INFO '---------------------------------------------------------';
            RAISE INFO '[✓] ORQUESTACION FINALIZADA. Job % | Tablas procesadas: 0 / 0 (Sistema optimo)', v_job_id;
            RAISE INFO 'Tiempo Total: %', (clock_timestamp() - v_start_time);
            RAISE INFO '=========================================================';
        END IF;

        -- Limpieza de rol si no hubo tareas a procesar (LÓGICA CLIENTE RESERVADA)
        IF array_length(v_changed_params, 1) > 0 THEN
            FOR i IN 1 .. array_length(v_changed_params, 1) LOOP
                EXECUTE format('ALTER ROLE %I RESET %I', current_user, v_changed_params[i]);
            END LOOP;
        END IF;

        COMMIT; RETURN;
    END IF;

    -- 4. ENSAMBLADOR DE OPCIONES NATIVAS DE VACUUM (Cero SQLi)
    v_options_str := '';
    IF r_profile.skip_locked THEN v_options_str := v_options_str || 'SKIP_LOCKED ON, '; END IF;
    IF r_profile.is_analyze THEN v_options_str := v_options_str || 'ANALYZE ON, '; END IF;
    IF r_profile.is_freeze THEN v_options_str := v_options_str || 'FREEZE ON, '; END IF;
    IF r_profile.is_verbose THEN v_options_str := v_options_str || 'VERBOSE ON, '; END IF;
    IF NOT r_profile.truncate_pages THEN v_options_str := v_options_str || 'TRUNCATE OFF, '; END IF;
    
    v_options_str := v_options_str || 'INDEX_CLEANUP ' || r_profile.index_cleanup;
    
    IF r_profile.parallel_workers > 0 THEN 
        v_options_str := v_options_str || ', PARALLEL ' || r_profile.parallel_workers; 
    END IF;

    -- 5. BUCLE DE DESPACHO ASÍNCRONO
    LOOP
        -- A. RECOLECTOR FORENSE (Preserva child_pid inmutable para auditoría)
        FOR r_finished IN 
            SELECT task_id, child_pid, schema_name, table_name FROM maint.vacuum_tasks 
            WHERE job_id = v_job_id AND status = 'RUNNING' 
              AND child_pid NOT IN (SELECT pid FROM pg_stat_activity WHERE backend_type = 'pg_background')
        LOOP
            BEGIN
                PERFORM * FROM public.pg_background_result(r_finished.child_pid::INT) AS (result TEXT);

                -- Se conserva child_pid intacto para trazabilidad PCI-DSS / ISO 27001
                UPDATE maint.vacuum_tasks SET status = 'SUCCESS', ended_at = clock_timestamp() WHERE task_id = r_finished.task_id;
                v_success_count := v_success_count + 1; 
                IF p_verbose THEN RAISE INFO '    [✓] EXITO -> %.%', r_finished.schema_name, r_finished.table_name; END IF;
            EXCEPTION WHEN OTHERS THEN
                UPDATE maint.vacuum_tasks SET status = 'FAILED', ended_at = clock_timestamp(), error_log = SQLERRM WHERE task_id = r_finished.task_id;
                IF p_verbose THEN RAISE WARNING '    [ERROR] FALLO EN %.%: %', r_finished.schema_name, r_finished.table_name, SQLERRM; END IF;
            END;
            COMMIT; 
        END LOOP;

        -- B. FRENO DE EMERGENCIA (KILL-SWITCH POR TIEMPO)
        IF p_cutoff_time IS NOT NULL AND LOCALTIME >= p_cutoff_time THEN
            UPDATE maint.vacuum_tasks SET status = 'SKIPPED_TIME_LIMIT', error_log = 'Cutoff Time Reached' 
            WHERE job_id = v_job_id AND status = 'PENDING'; 
            COMMIT;
        END IF;

        -- C. EVALUACIÓN DE ESTADO
        SELECT COUNT(*) INTO v_active_workers FROM maint.vacuum_tasks WHERE job_id = v_job_id AND status = 'RUNNING';
        SELECT COUNT(*) INTO v_pending_tasks FROM maint.vacuum_tasks WHERE job_id = v_job_id AND status = 'PENDING';
        
        IF v_active_workers = 0 AND v_pending_tasks = 0 THEN EXIT; END IF;

        -- D. DESPACHADOR DE TAREAS
        WHILE v_active_workers < p_parallel_workers AND v_pending_tasks > 0 LOOP
            IF p_cutoff_time IS NOT NULL AND LOCALTIME >= p_cutoff_time THEN EXIT; END IF;
            
            SELECT task_id, schema_name, table_name INTO v_task_id, v_schema, v_table 
            FROM maint.vacuum_tasks 
            WHERE job_id = v_job_id AND status = 'PENDING' 
            ORDER BY task_id ASC LIMIT 1;
            
            IF v_task_id IS NOT NULL THEN
                UPDATE maint.vacuum_tasks SET status = 'RUNNING', started_at = clock_timestamp() WHERE task_id = v_task_id; 
                COMMIT;

                -- Construcción de la sentencia SQL de VACUUM
                v_raw_sql := format('VACUUM (%s) %I.%I;', v_options_str, v_schema, v_table);

                v_child_pid := public.pg_background_launch(v_raw_sql);
                UPDATE maint.vacuum_tasks SET child_pid = v_child_pid WHERE task_id = v_task_id; 
                COMMIT;
                
                IF p_verbose THEN RAISE INFO '    [>] LANZANDO [%] PID % -> %.%', UPPER(p_profile), v_child_pid, v_schema, v_table; END IF;
                v_active_workers := v_active_workers + 1; v_pending_tasks := v_pending_tasks - 1;
            END IF;
        END LOOP;
        PERFORM pg_sleep(1);
    END LOOP;

    -- 6. CIERRE NORMAL DE JOB
    IF EXISTS (SELECT 1 FROM maint.vacuum_tasks WHERE job_id = v_job_id AND status = 'SKIPPED_TIME_LIMIT') THEN
        UPDATE maint.jobs SET status = 'COMPLETED_WITH_CUTOFF', ended_at = clock_timestamp(), tables_processed = v_success_count WHERE job_id = v_job_id;
    ELSE
        UPDATE maint.jobs SET status = 'COMPLETED', ended_at = clock_timestamp(), tables_processed = v_success_count WHERE job_id = v_job_id;
    END IF;

    -- Purga de la cola de tareas si no se desea retener el historial
    IF NOT p_keep_history THEN
        DELETE FROM maint.vacuum_tasks WHERE job_id = v_job_id;
        IF p_verbose THEN RAISE INFO '[PURGE] Purga ejecutada: Registros de maint.vacuum_tasks eliminados para el Job %.', v_job_id; END IF;
    END IF;

    -- =====================================================================
    -- LIMPIEZA DEL ROL AL FINALIZAR TODA LA ORQUESTACIÓN (LÓGICA CLIENTE RESERVADA)
    -- =====================================================================
    IF array_length(v_changed_params, 1) > 0 THEN
        FOR i IN 1 .. array_length(v_changed_params, 1) LOOP
            EXECUTE format('ALTER ROLE %I RESET %I', current_user, v_changed_params[i]);
        END LOOP;
    END IF;

    COMMIT;

    IF p_verbose THEN 
        RAISE INFO '---------------------------------------------------------';
        RAISE INFO '[✓] ORQUESTACION FINALIZADA. Job % | Tablas procesadas: % / %', v_job_id, v_success_count, v_total_tasks;
        RAISE INFO 'Tiempo Total: %', (clock_timestamp() - v_start_time);
        RAISE INFO '=========================================================';
    END IF;
END;
$$;

REVOKE EXECUTE ON PROCEDURE maint.sp_orchestrate_vacuum FROM PUBLIC;

COMMIT;
