/* =========================================================================================
   ██████╗ ██████╗  █████╗     ███████╗ ██████╗ ██╗   ██╗ █████╗ ██████╗ 
   ██╔══██╗██╔══██╗██╔══██╗    ██╔════╝██╔═══██╗██║   ██║██╔══██╗██╔══██╗
   ██║  ██║██████╔╝███████║    ███████╗██║   ██║██║   ██║███████║██║  ██║
   ██║  ██║██╔══██╗██╔══██║    ╚════██║██║▄▄ ██║██║   ██║██╔══██║██║  ██║
   ██████╔╝██████╔╝██║  ██║    ███████║╚██████╔╝╚██████╔╝██║  ██║██████╔╝
   ╚═════╝ ╚═════╝ ╚═╝  ╚═╝    ╚══════╝ ╚══▀▀═╝  ╚═════╝ ╚═╝  ╚═╝╚═════╝ 
                               VANGUARD BLACK-OPS
                               
   MÓDULO: Orquestador Asíncrono de Mantenimiento de Estadísticas (ANALYZE)
   Compatibilidad : Universal (<= pg_background 1.4 y >= 2.0 / Cloud SQL & On-Premise)
   VERSIÓN: 3.1.1 (Grado Diamante - Smart Triage & Multi-Stage Preload)
   ARQUITECTURA: Multi-hilo, Resiliente, Forense, Libre de Subtransacciones.
========================================================================================= */
BEGIN;

CREATE SCHEMA IF NOT EXISTS maint;

-- =========================================================================================
-- [FASE 1]: EXTENSIONES DEL KERNEL DE POSTGRESQL
-- =========================================================================================
CREATE EXTENSION IF NOT EXISTS pg_background;

-- =========================================================================================
-- 1. TABLA PADRE: Orquestación Global (Unificada)
-- =========================================================================================
CREATE TABLE IF NOT EXISTS maint.jobs (
    job_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    job_type VARCHAR(50) NOT NULL,              -- Ej. 'SMART_USER_NORMAL', 'ALL_USER_PRELOAD'
    maintenance_action VARCHAR(20) NOT NULL,    -- 'ANALYZE', 'VACUUM', 'VACUUM_FULL', 'REINDEX'
    orchestrator_pid INT NOT NULL,              -- PID del proceso principal (Padre) para Self-Healing
    execution_params JSONB NOT NULL,             -- Fotografía inmutable de los parámetros de invocación
    status VARCHAR(30) NOT NULL DEFAULT 'RUNNING',-- 'RUNNING', 'COMPLETED', 'COMPLETED_WITH_CUTOFF', 'ABORTED_ORPHAN'
    tables_processed INT DEFAULT 0,             -- Cantidad real de tablas intervenidas exitosamente
    started_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    ended_at TIMESTAMPTZ                        -- Sello de tiempo final cuando concluye o se reconcilia
);

CREATE INDEX IF NOT EXISTS idx_jobs_status_action 
ON maint.jobs (status, maintenance_action) 
WHERE status = 'RUNNING';

CREATE INDEX IF NOT EXISTS idx_maint_jobs_type_action_id 
ON maint.jobs (job_type, maintenance_action, job_id DESC);

COMMENT ON TABLE maint.jobs IS 'Cabecera maestra unificada que registra la ejecución global, estado y parámetros JSONB.';
COMMENT ON COLUMN maint.jobs.job_id IS 'Identificador único secuencial del trabajo maestro de mantenimiento.';
COMMENT ON COLUMN maint.jobs.job_type IS 'Modo o perfil de ejecución asignado al trabajo (ej. SMART_USER_NORMAL, SMART_USER_PRELOAD).';
COMMENT ON COLUMN maint.jobs.maintenance_action IS 'Acción principal del motor de base de datos ejecutada (ANALYZE).';
COMMENT ON COLUMN maint.jobs.tables_processed IS 'Métrica de contador en memoria RAM del total de tablas analizadas con éxito.';
COMMENT ON COLUMN maint.jobs.status IS 'Estado global del trabajo (RUNNING, COMPLETED, COMPLETED_WITH_CUTOFF, ABORTED_ORPHAN).';
COMMENT ON COLUMN maint.jobs.started_at IS 'Marca de tiempo (Timestamptz) de cuando inició el orquestador maestro.';
COMMENT ON COLUMN maint.jobs.ended_at IS 'Marca de tiempo (Timestamptz) de cuando concluyó la orquestación global.';

-- =========================================================================================
-- 2. TABLA DE CONTROL: Reglas y Filtros de Seguridad
-- =========================================================================================
CREATE TABLE IF NOT EXISTS maint.filters (
    filter_id SERIAL PRIMARY KEY,                               
    schema_name VARCHAR(255) NOT NULL,                          
    table_name VARCHAR(255) NOT NULL,
    maintenance_action VARCHAR(50) NOT NULL DEFAULT 'ALL',                          
    is_ignored BOOLEAN NOT NULL DEFAULT FALSE,                  
    force_maintenance BOOLEAN NOT NULL DEFAULT FALSE,           
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(), 
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(), 
    updated_by VARCHAR(100) DEFAULT current_user,               
    
    CONSTRAINT uq_maintenance_filters_schema_table_action UNIQUE (schema_name, table_name, maintenance_action),
    CONSTRAINT chk_valid_maintenance_action CHECK (
        maintenance_action IN ('ALL', 'VACUUM', 'VACUUM_FULL', 'ANALYZE', 'REINDEX')
    )
);

COMMENT ON CONSTRAINT chk_valid_maintenance_action ON maint.filters IS 'Candado de integridad: Previene errores tipográficos al registrar filtros.';

-- =========================================================================================
-- 3. TABLA HIJA: Trazabilidad Forense de ANALYZE (Inyección Anti-PID Reuse v2.0)
-- =========================================================================================
CREATE TABLE IF NOT EXISTS maint.analyze_tasks (
    task_id SERIAL PRIMARY KEY,
    job_id BIGINT NOT NULL REFERENCES maint.jobs(job_id) ON DELETE CASCADE,
    schema_name TEXT NOT NULL,
    table_name TEXT NOT NULL,
    total_filas BIGINT,                      
    filas_afectadas BIGINT,                  
    drift_pct NUMERIC(5,2),                  
    status VARCHAR(30) DEFAULT 'PENDING', 
    child_pid INT,
    child_cookie BIGINT,                          -- [HOMOLOGACIÓN UNIVERSAL]: Token de seguridad v2.0
    stage_number INT DEFAULT 1,
    started_at TIMESTAMPTZ,
    ended_at TIMESTAMPTZ,
    error_log TEXT
);

-- Migración idempotente en caso de que la tabla ya existiera previamente
DO $$ 
BEGIN 
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_schema = 'maint' AND table_name = 'analyze_tasks' AND column_name = 'child_cookie'
    ) THEN 
        ALTER TABLE maint.analyze_tasks ADD COLUMN child_cookie BIGINT; 
    END IF; 
END $$;

CREATE INDEX IF NOT EXISTS idx_analyze_task_active_queue 
ON maint.analyze_tasks (job_id, stage_number, task_id ASC)
WHERE status IN ('PENDING', 'RUNNING');

CREATE INDEX IF NOT EXISTS idx_analyze_task_forensic_trace 
ON maint.analyze_tasks (schema_name, table_name, ended_at DESC);

CREATE INDEX IF NOT EXISTS idx_analyze_tasks_job_stage_status_id 
ON maint.analyze_tasks (job_id, stage_number, status, task_id);

COMMENT ON TABLE maint.analyze_tasks IS 'Cola transaccional y bitácora forense para la orquestación asíncrona de estadísticas (ANALYZE).';

/* =========================================================================================
   PROCEDIMIENTO: maint.sp_orchestrate_analyze (V3.1.1)
========================================================================================= */
CREATE OR REPLACE PROCEDURE maint.sp_orchestrate_analyze(
    p_scope VARCHAR DEFAULT 'SMART_USER',       -- 'SMART_USER', 'ALL_USER', 'CUSTOM_LIST', 'SMART_SYSTEM_USER', 'ALL_SYSTEM_USER', 'ALL_SYSTEM'
    p_profile VARCHAR DEFAULT 'NORMAL',          -- 'NORMAL', 'PRELOAD'
    p_parallel_workers INT DEFAULT 4,
    p_verbose BOOLEAN DEFAULT FALSE,
    p_threshold_pct NUMERIC DEFAULT 5.00,       -- 5.00 = 5% (Homologado)
    p_min_chg_rows INT DEFAULT 1000,            -- Mínimo de cambios para evaluar
    p_force_chg_rows INT DEFAULT 50000,         -- Filas modificadas para FORZAR entrada (NULL para desactivar)
    p_cutoff_time TIME DEFAULT NULL,
    p_keep_history BOOLEAN DEFAULT TRUE         -- TRUE = Conserva auditoría; FALSE = Limpia tareas al finalizar
)
LANGUAGE plpgsql AS $$
DECLARE
    v_job_id BIGINT; v_task_id INT; v_schema TEXT; v_table TEXT; v_child_pid INT; v_child_cookie BIGINT;
    v_active_workers INT; v_pending_tasks INT; v_total_tasks INT := 0; v_raw_sql TEXT;
    v_start_time TIMESTAMPTZ := clock_timestamp(); r_finished RECORD;
    v_current_stage INT := 1; v_max_stages INT := 1;
    v_success_count INT := 0; v_healed_count INT := 0;
    
    -- Variables para construcción dinámica y control
    v_set_prefix TEXT := '';
    v_target_stat INT;
    v_param RECORD;
    v_execution_params JSONB;
    v_orphaned_job RECORD;
    
    -- [INYECCIÓN POLIMÓRFICA]: Inmunidad a pg_background_handle
    v_launch_record RECORD;
    v_is_v2 BOOLEAN := FALSE;
    v_ext_version TEXT;
BEGIN
    PERFORM pg_catalog.set_config('client_min_messages', 'notice', false);
    PERFORM pg_catalog.set_config('search_path', 'maint, public, pg_temp', true);

    -- 0. Detección Dinámica de Versión en pg_extension
    SELECT extversion INTO v_ext_version FROM pg_extension WHERE extname = 'pg_background';
    IF v_ext_version IS NOT NULL AND SPLIT_PART(v_ext_version, '.', 1)::INT >= 2 THEN
        v_is_v2 := TRUE;
    END IF;

    -- 1-A. Validar Perfil
    IF UPPER(p_profile) = 'PRELOAD' THEN 
        v_max_stages := 3; 
    ELSIF UPPER(p_profile) <> 'NORMAL' THEN
        RAISE EXCEPTION 'CRITICO: El perfil "%" no es valido en maint.sp_orchestrate_analyze. Use "NORMAL" o "PRELOAD".', p_profile;
    END IF;

    -- =====================================================================
    -- 1-B. SELF-HEALING HERMÉTICO HOMOLOGADO CON NOTIFICACIÓN ACTIVA
    -- =====================================================================
    FOR v_orphaned_job IN (
        SELECT j.job_id 
        FROM maint.jobs j
        WHERE j.status = 'RUNNING' 
          AND j.maintenance_action = 'ANALYZE'
          AND NOT EXISTS (
              SELECT 1 FROM pg_stat_activity a 
              WHERE a.pid = j.orchestrator_pid 
                AND a.pid != pg_backend_pid()
                AND a.state != 'idle'
          )
          AND NOT EXISTS (
              SELECT 1 FROM maint.analyze_tasks t
              JOIN pg_stat_activity a ON a.pid = t.child_pid
              WHERE t.job_id = j.job_id 
                AND t.status = 'RUNNING'
                AND a.backend_type = 'pg_background'
          )
        FOR UPDATE OF j SKIP LOCKED
    ) LOOP
        UPDATE maint.analyze_tasks 
        SET status = 'ABORTED_ORPHAN', 
            ended_at = clock_timestamp(),
            error_log = 'Orchestrator process died or was superseded.'
        WHERE job_id = v_orphaned_job.job_id 
          AND status IN ('PENDING', 'RUNNING');

        UPDATE maint.jobs 
        SET status = 'ABORTED_ORPHAN', 
            ended_at = clock_timestamp(),
            tables_processed = (
                SELECT COUNT(*) FROM maint.analyze_tasks 
                WHERE job_id = v_orphaned_job.job_id AND status = 'SUCCESS'
            )
        WHERE job_id = v_orphaned_job.job_id;

        v_healed_count := v_healed_count + 1;

        IF p_verbose THEN
            RAISE NOTICE '[SELF-HEALING] Job % detectado como huérfano. Estado actualizado a ABORTED_ORPHAN.', v_orphaned_job.job_id;
        END IF;
    END LOOP;

    IF v_healed_count > 0 THEN
        RAISE NOTICE '[SELF-HEALING] Se auto-sanaron y cerraron % trabajo(s) huérfano(s) en maint.jobs.', v_healed_count;
    END IF;

    COMMIT;
    -- =====================================================================

    -- 2. Interceptar SETs locales de la sesión
    FOR v_param IN (
        SELECT name, setting 
        FROM pg_settings 
        WHERE name IN ('maintenance_work_mem', 'vacuum_cost_delay', 'vacuum_buffer_usage_limit', 'default_statistics_target')
          AND setting IS DISTINCT FROM reset_val
    ) LOOP
        IF UPPER(p_profile) = 'PRELOAD' AND v_param.name = 'default_statistics_target' THEN
            CONTINUE;
        END IF;
        
        v_set_prefix := v_set_prefix || format('SET %I = %L; ', v_param.name, v_param.setting);
    END LOOP;

    IF p_verbose THEN
        RAISE INFO '=========================================================';
        RAISE INFO '[DBA SQUAD] INICIANDO ORQUESTADOR ANALYZE VANGUARD (V3.1.1 - EXT: %)', COALESCE(v_ext_version, 'v1.x');
        RAISE INFO 'ALCANCE: % | PERFIL: % | HILOS: % | FASES: % | CUTOFF: % | HISTORIAL: %', 
                   p_scope, UPPER(p_profile), p_parallel_workers, v_max_stages, COALESCE(p_cutoff_time::TEXT, 'SIN LIMITE'), p_keep_history;
        RAISE INFO '=========================================================';
    END IF;

    -- 3. Embalar parámetros en JSONB y crear Job Padre
    v_execution_params := jsonb_build_object(
        'scope', p_scope,
        'profile', UPPER(p_profile),
        'parallel_workers', p_parallel_workers,
        'threshold_pct', p_threshold_pct,
        'min_rows', p_min_chg_rows,
        'force_rows', p_force_chg_rows,
        'cutoff_time', p_cutoff_time,
        'keep_history', p_keep_history,
        'pg_background_version', COALESCE(v_ext_version, '1.x')
    );

    INSERT INTO maint.jobs (job_type, maintenance_action, orchestrator_pid, execution_params, status)
    VALUES (p_scope || '_' || UPPER(p_profile), 'ANALYZE', pg_backend_pid(), v_execution_params, 'RUNNING')
    RETURNING job_id INTO v_job_id;
    COMMIT;

    -- 4. BUCLE GLOBAL DE FASES (Soporta PRELOAD)
    WHILE v_current_stage <= v_max_stages LOOP

        IF p_verbose THEN
            RAISE INFO '---------------------------------------------------------';
            RAISE INFO '>>> INICIANDO FASE % DE % <<<', v_current_stage, v_max_stages;
            RAISE INFO '---------------------------------------------------------';
        END IF;

        -- POBLAR COLA PARA LA FASE ACTUAL
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
                  COALESCE(st.n_mod_since_analyze, 0) >= p_min_chg_rows AND (
                      ((COALESCE(st.n_mod_since_analyze, 0)::numeric / NULLIF(st.n_live_tup, 0)) * 100.0) >= p_threshold_pct 
                      OR (p_force_chg_rows IS NOT NULL AND COALESCE(st.n_mod_since_analyze, 0) >= p_force_chg_rows)
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
                RAISE INFO '[✓] ORQUESTACION FINALIZADA. Job % | Tablas procesadas: 0 / 0 (Sistema optimo)', v_job_id;
                RAISE INFO 'Tiempo Total: %', (clock_timestamp() - v_start_time);
                RAISE INFO '=========================================================';
            END IF;
            UPDATE maint.jobs SET status = 'COMPLETED', ended_at = clock_timestamp(), tables_processed = 0 WHERE job_id = v_job_id;
            COMMIT; RETURN;
        END IF;

        -- 5. BUCLE DE DESPACHO ASÍNCRONO POLIMÓRFICO
        LOOP
            FOR r_finished IN 
                SELECT task_id, child_pid, child_cookie, schema_name, table_name FROM maint.analyze_tasks 
                WHERE job_id = v_job_id AND stage_number = v_current_stage 
                  AND status = 'RUNNING' AND child_pid NOT IN (SELECT pid FROM pg_stat_activity WHERE backend_type = 'pg_background')
            LOOP
                BEGIN
                    -- Consumo de Resultado (Realiza Auto-Detach Nativo en Flujo de Éxito)
                    IF v_is_v2 THEN
                        EXECUTE 'PERFORM * FROM public.pg_background_result($1, $2)' USING r_finished.child_pid, r_finished.child_cookie;
                    ELSE
                        EXECUTE 'PERFORM * FROM public.pg_background_result($1)' USING r_finished.child_pid;
                    END IF;

                    UPDATE maint.analyze_tasks SET status = 'SUCCESS', ended_at = clock_timestamp() WHERE task_id = r_finished.task_id;
                    v_success_count := v_success_count + 1;
                    IF p_verbose THEN RAISE INFO '    [✓] EXITO (Fase %) -> %.%', v_current_stage, r_finished.schema_name, r_finished.table_name; END IF;

                EXCEPTION WHEN OTHERS THEN
                    UPDATE maint.analyze_tasks SET status = 'FAILED', ended_at = clock_timestamp(), error_log = SQLERRM WHERE task_id = r_finished.task_id;
                    IF p_verbose THEN RAISE WARNING '    [ERROR] FALLO EN %.%: %', r_finished.schema_name, r_finished.table_name, SQLERRM; END IF;

                    -- [DETACH DEFENSIVO EN EXCEPCIÓN]: Purga de segmento DSM atascado si result() falló
                    BEGIN
                        IF v_is_v2 THEN
                            EXECUTE 'SELECT public.pg_background_detach($1, $2)' USING r_finished.child_pid, r_finished.child_cookie;
                        ELSE
                            EXECUTE 'SELECT public.pg_background_detach($1)' USING r_finished.child_pid;
                        END IF;
                    EXCEPTION WHEN OTHERS THEN
                        NULL; -- Ignora si la memoria ya había sido liberada por el Kernel
                    END;
                END;
                COMMIT;
            END LOOP;

            IF p_cutoff_time IS NOT NULL AND LOCALTIME >= p_cutoff_time THEN
                UPDATE maint.analyze_tasks SET status = 'SKIPPED_TIME_LIMIT', error_log = 'Cutoff Time Reached' 
                WHERE job_id = v_job_id AND stage_number = v_current_stage AND status = 'PENDING';
                COMMIT;
            END IF;

            SELECT COUNT(*) INTO v_active_workers FROM maint.analyze_tasks WHERE job_id = v_job_id AND stage_number = v_current_stage AND status = 'RUNNING';
            SELECT COUNT(*) INTO v_pending_tasks FROM maint.analyze_tasks WHERE job_id = v_job_id AND stage_number = v_current_stage AND status = 'PENDING';

            IF v_active_workers = 0 AND v_pending_tasks = 0 THEN 
                EXIT; 
            END IF;

            WHILE v_active_workers < p_parallel_workers AND v_pending_tasks > 0 LOOP
                IF p_cutoff_time IS NOT NULL AND LOCALTIME >= p_cutoff_time THEN EXIT; END IF;

                SELECT task_id, schema_name, table_name INTO v_task_id, v_schema, v_table
                FROM maint.analyze_tasks
                WHERE job_id = v_job_id AND stage_number = v_current_stage AND status = 'PENDING' 
                ORDER BY task_id ASC LIMIT 1;

                IF v_task_id IS NOT NULL THEN
                    UPDATE maint.analyze_tasks SET status = 'RUNNING', started_at = clock_timestamp() WHERE task_id = v_task_id;
                    COMMIT;

                    v_raw_sql := v_set_prefix;

                    IF UPPER(p_profile) = 'PRELOAD' THEN
                        v_target_stat := CASE v_current_stage WHEN 1 THEN 1 WHEN 2 THEN 10 ELSE 100 END;
                        v_raw_sql := v_raw_sql || format('SET default_statistics_target = %s; ', v_target_stat);
                    END IF;

                    v_raw_sql := v_raw_sql || format('ANALYZE %I.%I;', v_schema, v_table);

                    -- [LANZAMIENTO DINÁMICO POLIMÓRFICO]: Late Binding mediante RECORD
                    IF v_is_v2 THEN
                        EXECUTE 'SELECT * FROM public.pg_background_launch($1)' INTO v_launch_record USING v_raw_sql;
                        v_child_pid := (v_launch_record).pid;
                        v_child_cookie := (v_launch_record).cookie;
                    ELSE
                        EXECUTE 'SELECT public.pg_background_launch($1)' INTO v_child_pid USING v_raw_sql;
                        v_child_cookie := NULL;
                    END IF;

                    UPDATE maint.analyze_tasks 
                    SET child_pid = v_child_pid, child_cookie = v_child_cookie 
                    WHERE task_id = v_task_id;
                    COMMIT;

                    IF p_verbose THEN RAISE INFO '    [>] LANZANDO (Fase %) PID % -> %.%', v_current_stage, v_child_pid, v_schema, v_table; END IF;
                    v_active_workers := v_active_workers + 1; v_pending_tasks := v_pending_tasks - 1;
                END IF;
            END LOOP;
            PERFORM pg_sleep(1);
        END LOOP;

        IF p_cutoff_time IS NOT NULL AND LOCALTIME >= p_cutoff_time THEN
            IF p_verbose THEN RAISE WARNING '[ABORT] Ventana de mantenimiento excedida. Abortando fases restantes.'; END IF;
            EXIT; 
        END IF;

        v_current_stage := v_current_stage + 1;
    END LOOP;

    -- [BARRERA DE CIERRE FINAL]: Purga defensiva en v2.0 si estuviera disponible
    IF v_is_v2 THEN
        BEGIN
            EXECUTE 'SELECT public.pg_background_detach_all()';
        EXCEPTION WHEN OTHERS THEN
            NULL;
        END;
    END IF;

    IF EXISTS (SELECT 1 FROM maint.analyze_tasks WHERE job_id = v_job_id AND status = 'SKIPPED_TIME_LIMIT') THEN
        UPDATE maint.jobs SET status = 'COMPLETED_WITH_CUTOFF', ended_at = clock_timestamp(), tables_processed = v_success_count WHERE job_id = v_job_id;
    ELSE
        UPDATE maint.jobs SET status = 'COMPLETED', ended_at = clock_timestamp(), tables_processed = v_success_count WHERE job_id = v_job_id;
    END IF;

    IF NOT p_keep_history THEN
        DELETE FROM maint.analyze_tasks WHERE job_id = v_job_id;
        IF p_verbose THEN RAISE INFO '[PURGE] Purga ejecutada: Registros de maint.analyze_tasks eliminados para el Job %.', v_job_id; END IF;
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

REVOKE EXECUTE ON PROCEDURE maint.sp_orchestrate_analyze FROM PUBLIC;

COMMIT;
