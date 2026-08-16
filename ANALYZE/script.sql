BEGIN;

-- 1. TABLA PADRE: Orquestación Global
-- DROP TABLE IF EXISTS public.maintenance_jobs CASCADE;
-- TRUNCATE TABLE public.maintenance_jobs RESTART IDENTITY CASCADE ;
CREATE TABLE IF NOT EXISTS public.maintenance_jobs (
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


-- 2. DICCIONARIO DE DATOS NATIVO (pg_description)
COMMENT ON TABLE public.maintenance_jobs IS 'Cabecera maestra unificada que registra la ejecución global, estado, tipo de acción (ANALYZE/VACUUM) y métricas de cada ciclo de orquestación.';
COMMENT ON COLUMN public.maintenance_jobs.job_id IS 'Identificador único secuencial del trabajo maestro de mantenimiento.';
COMMENT ON COLUMN public.maintenance_jobs.job_type IS 'Modo o perfil de ejecución asignado al trabajo (ej. SMART, ALL, PRELOAD, SMART_USER_BALANCED).';
COMMENT ON COLUMN public.maintenance_jobs.maintenance_action IS 'Acción principal del motor de base de datos ejecutada (ej. ANALYZE, VACUUM).';
COMMENT ON COLUMN public.maintenance_jobs.threshold_pct IS 'Umbral porcentual de modificación (drift_pct) o tuplas muertas configurado para el disparo.';
COMMENT ON COLUMN public.maintenance_jobs.parallel_workers IS 'Límite de concurrencia de hilos/workers paralelos asignados al trabajo.';
COMMENT ON COLUMN public.maintenance_jobs.tables_processed IS 'Métrica de contador en memoria RAM del total de tablas analizadas o limpiadas con éxito.';
COMMENT ON COLUMN public.maintenance_jobs.status IS 'Estado global del trabajo (INITIALIZING, RUNNING, COMPLETED, COMPLETED_WITH_CUTOFF).';
COMMENT ON COLUMN public.maintenance_jobs.started_at IS 'Marca de tiempo (Timestamptz) de cuando inició el orquestador maestro.';
COMMENT ON COLUMN public.maintenance_jobs.ended_at IS 'Marca de tiempo (Timestamptz) de cuando concluyó la orquestación global.';

-- 3. ÍNDICE DE HERENCIA Y RENDIMIENTO
CREATE INDEX IF NOT EXISTS idx_maint_jobs_type_action_id 
ON public.maintenance_jobs (job_type, maintenance_action, job_id DESC);

COMMENT ON INDEX public.idx_maint_jobs_type_action_id IS 'Acelera la búsqueda del último trabajo ejecutado (MAX job_id) para herencias de estado en milisegundos.';

 
-- 2. TABLA HIJA: Trazabilidad Forense por Tabla (CON TELEMETRÍA Y SLOTS)
-- DROP TABLE IF EXISTS public.mant_analyze_task CASCADE;
-- TRUNCATE TABLE public.mant_analyze_task RESTART IDENTITY ;
CREATE TABLE IF NOT EXISTS public.mant_analyze_task (
    task_id SERIAL PRIMARY KEY,
    job_id INT NOT NULL REFERENCES public.maintenance_jobs(job_id) ON DELETE CASCADE,
    schema_name TEXT NOT NULL,
    table_name TEXT NOT NULL,
    total_filas BIGINT,                  
    filas_afectadas BIGINT,              
    drift_pct NUMERIC(5,2),              
    status VARCHAR(20) DEFAULT 'PENDING', 
    slot_id INT,                         
    child_pid INT,
    stage_number INT DEFAULT 1,
    started_at TIMESTAMPTZ,
    ended_at TIMESTAMPTZ,
    error_log TEXT
);

CREATE INDEX IF NOT EXISTS idx_analyze_task_active_queue 
ON public.mant_analyze_task (job_id, stage_number, task_id ASC)
WHERE status IN ('PENDING', 'RUNNING');

COMMENT ON INDEX public.idx_analyze_task_active_queue IS 'Índice Parcial de Despacho. Mantiene un B-Tree ultraligero exclusivo para tareas vivas, ignorando el historial muerto para un polling de latencia cero.';

CREATE INDEX IF NOT EXISTS idx_analyze_task_active_queue 
ON public.mant_analyze_task (job_id, stage_number, task_id ASC)
WHERE status IN ('PENDING', 'RUNNING');

COMMENT ON INDEX public.idx_analyze_task_active_queue IS 'Índice Parcial de Despacho. Mantiene un B-Tree ultraligero exclusivo para tareas vivas, ignorando el historial muerto para un polling de latencia cero.';


-- 2. DICCIONARIO DE DATOS NATIVO (DOCUMENTACIÓN CORPORATIVA)
COMMENT ON TABLE public.mant_analyze_task IS 'Cola transaccional y bitácora forense para la orquestación asíncrona de estadísticas (ANALYZE).';
COMMENT ON COLUMN public.mant_analyze_task.task_id IS 'Identificador único secuencial de la tarea individual por tabla.';
COMMENT ON COLUMN public.mant_analyze_task.job_id IS 'Llave foránea enlazada al registro maestro en maintenance_jobs (ON DELETE CASCADE).';
COMMENT ON COLUMN public.mant_analyze_task.schema_name IS 'Nombre del esquema de base de datos donde reside la tabla objetivo.';
COMMENT ON COLUMN public.mant_analyze_task.table_name IS 'Nombre de la tabla física objetivo de la actualización de estadísticas.';
COMMENT ON COLUMN public.mant_analyze_task.total_filas IS 'Tuplas vivas (n_live_tup) estimadas al momento de encolar la tarea.';
COMMENT ON COLUMN public.mant_analyze_task.filas_afectadas IS 'Tuplas modificadas (n_mod_since_analyze) detectadas al momento de encolar.';
COMMENT ON COLUMN public.mant_analyze_task.drift_pct IS 'Porcentaje de desfase estadístico calculado (filas_afectadas / total_filas).';
COMMENT ON COLUMN public.mant_analyze_task.status IS 'Estado de la tarea (PENDING, RUNNING, SUCCESS, FAILED, SKIPPED_TIME_LIMIT).';
COMMENT ON COLUMN public.mant_analyze_task.slot_id IS 'Identificador de la ranura de concurrencia asignada para la gestión estricta de hilos.';
COMMENT ON COLUMN public.mant_analyze_task.child_pid IS 'Identificador del proceso (PID) del worker de fondo lanzado en Linux.';
COMMENT ON COLUMN public.mant_analyze_task.stage_number IS 'Fase de ejecución actual (Vital para la orquestación escalonada del modo PRELOAD).';
COMMENT ON COLUMN public.mant_analyze_task.started_at IS 'Marca de tiempo del inicio de la ejecución individual de la tabla.';
COMMENT ON COLUMN public.mant_analyze_task.ended_at IS 'Marca de tiempo de finalización del análisis (éxito o fallo).';
COMMENT ON COLUMN public.mant_analyze_task.error_log IS 'Captura forense del mensaje nativo de error (SQLERRM) extraído de la memoria dinámica.';


-- 3. ÍNDICES DE ALTO RENDIMIENTO (LA ARMADURA DEL MOTOR)

-- Índice Operativo Principal: Cubre Integridad Referencial (CASCADE), Filtros de Fase, Estados y Ordenamiento del Despachador.
CREATE INDEX IF NOT EXISTS idx_analyze_tasks_job_stage_status_id 
ON public.mant_analyze_task (job_id, stage_number, status, task_id);

COMMENT ON INDEX public.idx_analyze_tasks_job_stage_status_id IS 'Índice central de despacho: Evita Seq Scans en DELETE CASCADE y optimiza radicalmente los bloqueos WHERE job_id = X AND stage_number = Y AND status = Z ORDER BY task_id LIMIT 1.';




CREATE OR REPLACE PROCEDURE public.sp_orchestrate_maintenance(
    p_job_type VARCHAR,                  -- 'SMART', 'ALL', 'PRELOAD'
    p_parallel_workers INT,              -- Cantidad de hilos paralelos
    p_verbose BOOLEAN DEFAULT FALSE,     -- Diagnóstico visual en tiempo real
    p_threshold_pct NUMERIC DEFAULT 0.05,-- Umbral de modificación (0.05 = 5%)
    p_min_rows INT DEFAULT 1000,         -- Límite mínimo absoluto de modificaciones
    p_cutoff_time TIME DEFAULT NULL      -- [NUEVO] Kill Switch Temporal
)
LANGUAGE plpgsql AS $$
DECLARE
    v_job_id INT; v_task_id INT; v_schema TEXT; v_table TEXT; v_child_pid INT;
    v_active_workers INT; v_pending_tasks INT; v_total_tasks INT; v_raw_sql TEXT;
    v_start_time TIMESTAMPTZ := clock_timestamp(); r_finished RECORD;
    v_current_stage INT := 1; v_max_stages INT := 1;
    v_success_count INT := 0;            -- [NUEVO] Métrica RAM O(1)
BEGIN
   PERFORM pg_catalog.set_config('client_min_messages', 'notice', false);
   -- configuracion de seguridad
   PERFORM pg_catalog.set_config('search_path', 'public, pg_temp', true);
    IF p_job_type = 'PRELOAD' THEN v_max_stages := 3; END IF;

    IF p_verbose THEN
        RAISE INFO '=========================================================';
        RAISE INFO '[DBA SQUAD] INICIANDO ORQUESTADOR ANALYZE VANGUARD';
        RAISE INFO 'TIPO: % | HILOS: % | FASES: % | CUTOFF: %', p_job_type, p_parallel_workers, v_max_stages, COALESCE(p_cutoff_time::TEXT, 'SIN LÍMITE');
        RAISE INFO '=========================================================';
    END IF;

    -- 1. Crear Job Padre
    INSERT INTO public.maintenance_jobs (job_type, maintenance_action, threshold_pct, parallel_workers, status)
    VALUES (p_job_type, 'ANALYZE', p_threshold_pct, p_parallel_workers, 'RUNNING')
    RETURNING job_id INTO v_job_id;
    COMMIT;

    -- 2. BUCLE GLOBAL DE FASES (Soporta PRELOAD)
    WHILE v_current_stage <= v_max_stages LOOP

        IF p_verbose THEN
            RAISE INFO '---------------------------------------------------------';
            RAISE INFO '>>> INICIANDO FASE % DE % <<<', v_current_stage, v_max_stages;
            RAISE INFO '---------------------------------------------------------';
        END IF;

        -- POBLAR COLA PARA LA FASE ACTUAL
        IF p_job_type = 'SMART' THEN
            INSERT INTO public.mant_analyze_task (job_id, schema_name, table_name, total_filas, filas_afectadas, drift_pct, stage_number)
            SELECT v_job_id, schemaname, relname, n_live_tup, COALESCE(n_mod_since_analyze, 0),
                   ROUND((COALESCE(n_mod_since_analyze, 0)::numeric / NULLIF(n_live_tup, 0)) * 100, 2), v_current_stage
            FROM pg_stat_user_tables
            WHERE COALESCE(n_mod_since_analyze, 0) >= p_min_rows
              AND (
                  (COALESCE(n_mod_since_analyze, 0)::numeric / NULLIF(n_live_tup, 0)) >= p_threshold_pct 
                  OR COALESCE(n_mod_since_analyze, 0) >= 50000 
              )
            ORDER BY COALESCE(n_mod_since_analyze, 0) DESC;
        ELSE
            -- ALL o PRELOAD
            INSERT INTO public.mant_analyze_task (job_id, schema_name, table_name, total_filas, filas_afectadas, drift_pct, stage_number)
            SELECT v_job_id, schemaname, relname, n_live_tup, COALESCE(n_mod_since_analyze, 0),
                   ROUND((COALESCE(n_mod_since_analyze, 0)::numeric / NULLIF(n_live_tup, 0)) * 100, 2), v_current_stage
            FROM pg_stat_user_tables
            ORDER BY COALESCE(n_mod_since_analyze, 0) DESC, n_live_tup DESC;
        END IF;
        COMMIT;

        SELECT COUNT(*) INTO v_total_tasks FROM public.mant_analyze_task WHERE job_id = v_job_id AND stage_number = v_current_stage;

        IF v_current_stage = 1 AND v_total_tasks = 0 THEN
            IF p_verbose THEN RAISE INFO '[✓] Sistema óptimo. Ninguna tabla superó los umbrales.'; END IF;
            UPDATE public.maintenance_jobs SET status = 'COMPLETED', ended_at = clock_timestamp(), tables_processed = 0 WHERE job_id = v_job_id;
            COMMIT; RETURN;
        END IF;

        -- 3. BUCLE DE DESPACHO ASÍNCRONO
        LOOP
            -- A. RECOLECTOR FORENSE
            FOR r_finished IN 
                SELECT task_id, child_pid, schema_name, table_name FROM public.mant_analyze_task 
                WHERE job_id = v_job_id AND stage_number = v_current_stage 
                  AND status = 'RUNNING' AND child_pid NOT IN (SELECT pid FROM pg_stat_activity WHERE backend_type = 'pg_background')
            LOOP
                BEGIN
                    PERFORM * FROM public.pg_background_result(r_finished.child_pid::INT) AS (result TEXT);

                    UPDATE public.mant_analyze_task SET status = 'SUCCESS', ended_at = clock_timestamp(), child_pid = NULL WHERE task_id = r_finished.task_id;
                    v_success_count := v_success_count + 1; -- [NUEVO] Incremento RAM
                    IF p_verbose THEN RAISE INFO '   [✓] ÉXITO (Fase %) -> %.%', v_current_stage, r_finished.schema_name, r_finished.table_name; END IF;
                EXCEPTION WHEN OTHERS THEN
                    UPDATE public.mant_analyze_task SET status = 'FAILED', ended_at = clock_timestamp(), error_log = SQLERRM, child_pid = NULL WHERE task_id = r_finished.task_id;
                    IF p_verbose THEN RAISE WARNING '   [X] FALLO EN %.%: %', r_finished.schema_name, r_finished.table_name, SQLERRM; END IF;
                END;
                COMMIT;
            END LOOP;

            -- B. [NUEVO] FRENO DE EMERGENCIA (KILL-SWITCH)
            IF p_cutoff_time IS NOT NULL AND LOCALTIME >= p_cutoff_time THEN
                UPDATE public.mant_analyze_task SET status = 'SKIPPED_TIME_LIMIT', error_log = 'Cutoff Time Reached' 
                WHERE job_id = v_job_id AND stage_number = v_current_stage AND status = 'PENDING';
                COMMIT;
            END IF;

            -- C. EVALUACIÓN DE ESTADO
            SELECT COUNT(*) INTO v_active_workers FROM public.mant_analyze_task WHERE job_id = v_job_id AND stage_number = v_current_stage AND status = 'RUNNING';
            SELECT COUNT(*) INTO v_pending_tasks FROM public.mant_analyze_task WHERE job_id = v_job_id AND stage_number = v_current_stage AND status = 'PENDING';

            IF v_active_workers = 0 AND v_pending_tasks = 0 THEN 
                EXIT; -- Terminó la Fase actual, sale del bucle interno
            END IF;

            -- D. DESPACHADOR DE TAREAS
            WHILE v_active_workers < p_parallel_workers AND v_pending_tasks > 0 LOOP
                IF p_cutoff_time IS NOT NULL AND LOCALTIME >= p_cutoff_time THEN EXIT; END IF;

                SELECT task_id, schema_name, table_name INTO v_task_id, v_schema, v_table
                FROM public.mant_analyze_task
                WHERE job_id = v_job_id AND stage_number = v_current_stage AND status = 'PENDING' 
                ORDER BY task_id ASC LIMIT 1;

                IF v_task_id IS NOT NULL THEN
                    UPDATE public.mant_analyze_task SET status = 'RUNNING', started_at = clock_timestamp() WHERE task_id = v_task_id;
                    COMMIT;

                    v_raw_sql := 'SET maintenance_work_mem = ''8GB''; SET vacuum_cost_delay = 0; ';

                    IF p_job_type = 'PRELOAD' THEN
                        IF v_current_stage = 1 THEN v_raw_sql := v_raw_sql || format('SET default_statistics_target = 1; ANALYZE %I.%I; ', v_schema, v_table);
                        ELSIF v_current_stage = 2 THEN v_raw_sql := v_raw_sql || format('SET default_statistics_target = 10; ANALYZE %I.%I; ', v_schema, v_table);
                        ELSE v_raw_sql := v_raw_sql || format('RESET default_statistics_target; ANALYZE %I.%I; ', v_schema, v_table); END IF;
                    ELSE
                        v_raw_sql := v_raw_sql || format('ANALYZE %I.%I; ', v_schema, v_table);
                    END IF;

                    v_child_pid := public.pg_background_launch(v_raw_sql);
                    UPDATE public.mant_analyze_task SET child_pid = v_child_pid WHERE task_id = v_task_id;
                    COMMIT;

                    IF p_verbose THEN RAISE INFO '    [>] LANZANDO (Fase %) PID % -> %.%', v_current_stage, v_child_pid, v_schema, v_table; END IF;
                    v_active_workers := v_active_workers + 1; v_pending_tasks := v_pending_tasks - 1;
                END IF;
            END LOOP;
            PERFORM pg_sleep(1);
        END LOOP;

        -- [NUEVO] ABORTO DE FASES SUBSECUENTES SI SE EXCEDIO EL TIEMPO
        IF p_cutoff_time IS NOT NULL AND LOCALTIME >= p_cutoff_time THEN
            IF p_verbose THEN RAISE WARNING '[!] Ventana de mantenimiento excedida. Abortando fases restantes.'; END IF;
            EXIT; 
        END IF;

        v_current_stage := v_current_stage + 1;
    END LOOP;

    -- 4. CIERRE CON MÉTRICAS INTEGRADAS
    IF EXISTS (SELECT 1 FROM public.mant_analyze_task WHERE job_id = v_job_id AND status = 'SKIPPED_TIME_LIMIT') THEN
        UPDATE public.maintenance_jobs SET status = 'COMPLETED_WITH_CUTOFF', ended_at = clock_timestamp(), tables_processed = v_success_count WHERE job_id = v_job_id;
    ELSE
        UPDATE public.maintenance_jobs SET status = 'COMPLETED', ended_at = clock_timestamp(), tables_processed = v_success_count WHERE job_id = v_job_id;
    END IF;
    COMMIT;

    IF p_verbose THEN
        RAISE INFO '---------------------------------------------------------';
        RAISE INFO '[DBA SQUAD] ORQUESTACIÓN FINALIZADA. Tablas procesadas: %', v_success_count;
        RAISE INFO 'Tiempo Total: %', (clock_timestamp() - v_start_time);
        RAISE INFO '=========================================================';
    END IF;
END;
$$;



REVOKE EXECUTE ON PROCEDURE public.sp_orchestrate_maintenance FROM PUBLIC;

COMMIT;
