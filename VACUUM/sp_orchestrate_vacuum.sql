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
CREATE TABLE IF NOT EXISTS maint.jobs (
    job_id SERIAL PRIMARY KEY,                                 
    job_type VARCHAR(50) NOT NULL,                             
    maintenance_action VARCHAR(20) NOT NULL,                   
    threshold_pct NUMERIC DEFAULT 0.05,                        
    parallel_workers INT NOT NULL,                             
    tables_processed INT NOT NULL DEFAULT 0,                   
    status VARCHAR(30) DEFAULT 'INITIALIZING',                 
    started_at TIMESTAMPTZ DEFAULT clock_timestamp(),          
    ended_at TIMESTAMPTZ                                       
);

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
CREATE TABLE IF NOT EXISTS maint.filters (
    filter_id SERIAL PRIMARY KEY,                              
    schema_name VARCHAR(255) NOT NULL,                         
    table_name VARCHAR(255) NOT NULL,                          
    is_ignored BOOLEAN NOT NULL DEFAULT FALSE,                 
    force_maintenance BOOLEAN NOT NULL DEFAULT FALSE,          
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(), 
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(), 
    updated_by VARCHAR(100) DEFAULT current_user,              
    CONSTRAINT uq_maintenance_filters_schema_table UNIQUE (schema_name, table_name)
);

COMMENT ON TABLE maint.filters IS 'Panel de control de seguridad para exclusión obligatoria (Kill Switch) o priorización VIP de tablas.';
COMMENT ON COLUMN maint.filters.filter_id IS 'Identificador único de la regla de filtrado de mantenimiento.';
COMMENT ON COLUMN maint.filters.schema_name IS 'Nombre del esquema aplicable a la regla de filtrado.';
COMMENT ON COLUMN maint.filters.table_name IS 'Nombre de la tabla aplicable a la regla de filtrado.';
COMMENT ON COLUMN maint.filters.is_ignored IS 'Flag de exclusión total (Kill Switch). Si es TRUE, la tabla es inmune al orquestador.';
COMMENT ON COLUMN maint.filters.force_maintenance IS 'Flag de priorización VIP. Si es TRUE, la tabla se incluye en el scope CUSTOM_LIST.';
COMMENT ON COLUMN maint.filters.created_at IS 'Marca de tiempo del registro original del filtro en el sistema.';
COMMENT ON COLUMN maint.filters.updated_at IS 'Marca de tiempo del último cambio aplicado a la regla de filtrado.';
COMMENT ON COLUMN maint.filters.updated_by IS 'Nombre del usuario/rol de PostgreSQL que configuró o modificó la regla.';


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
CREATE OR REPLACE PROCEDURE maint.sp_orchestrate_vacuum(
    p_scope VARCHAR DEFAULT 'SMART_USER',
    p_profile VARCHAR DEFAULT 'BALANCED',
    p_parallel_workers INT DEFAULT 4,
    p_cutoff_time TIME DEFAULT NULL,
    p_verbose BOOLEAN DEFAULT FALSE,
    p_threshold_pct NUMERIC DEFAULT 5.00,
    p_min_dead_tup INT DEFAULT 5000
)
LANGUAGE plpgsql AS $$
DECLARE
    v_job_id INT; v_task_id INT; v_schema TEXT; v_table TEXT; v_child_pid INT;
    v_active_workers INT; v_pending_tasks INT; v_total_tasks INT; v_raw_sql TEXT;
    v_effective_workers INT := p_parallel_workers; r_finished RECORD; v_last_job_id INT;
    v_success_count INT := 0; 
BEGIN
    PERFORM pg_catalog.set_config('client_min_messages', 'notice', false);
    PERFORM pg_catalog.set_config('search_path', 'maint, public, pg_temp', true);
    
    IF p_profile IN ('VACUUM_FULL', 'SMART_VACUUM_FULL') THEN v_effective_workers := 1; END IF;

    INSERT INTO maint.jobs (job_type, maintenance_action, threshold_pct, parallel_workers, status)
    VALUES (p_scope || '_' || p_profile, 'VACUUM', p_threshold_pct, v_effective_workers, 'RUNNING') RETURNING job_id INTO v_job_id;
    COMMIT;

    SELECT MAX(job_id) INTO v_last_job_id FROM maint.jobs WHERE job_type = (p_scope || '_' || p_profile) AND maintenance_action = 'VACUUM' AND job_id < v_job_id;

    -- INSERCIÓN CON COALESCE 0.00 CORREGIDO Y LEEYENDO MAINT.PGSTATTUPLE
    INSERT INTO maint.vacuum_tasks (job_id, schema_name, table_name, n_live_tup, n_dead_tup, dead_pct)
    SELECT v_job_id, st.schemaname, st.relname, st.n_live_tup, st.n_dead_tup, ROUND(COALESCE(vft.deep_free_percent, vft.approx_free_percent, (st.n_dead_tup::numeric / NULLIF(st.n_live_tup + st.n_dead_tup, 0)) * 100, 0.00), 2)
    FROM pg_stat_all_tables st
    LEFT JOIN maint.vacuum_tasks prev_t ON prev_t.job_id = v_last_job_id AND prev_t.schema_name = st.schemaname AND prev_t.table_name = st.relname
    LEFT JOIN maint.filters mf ON mf.schema_name = st.schemaname AND mf.table_name = st.relname
    LEFT JOIN maint.pgstattuple vft ON vft.schema_name = st.schemaname AND vft.table_name = st.relname AND vft.evaluation_week = date_trunc('week', current_date)::DATE
    WHERE st.schemaname <> 'pg_toast' AND COALESCE(mf.is_ignored, FALSE) = FALSE
      AND (
          (p_scope = 'CUSTOM_LIST' AND mf.force_maintenance = TRUE) OR
          (p_scope IN ('SMART_USER', 'ALL_USER') AND st.schemaname NOT IN ('pg_catalog', 'information_schema')) OR
          (p_scope IN ('SMART_SYSTEM_USER', 'ALL_SYSTEM_USER')) OR
          (p_scope = 'ALL_SYSTEM' AND st.schemaname IN ('pg_catalog', 'information_schema'))
      )
      AND (
          -- V3: EL ORQUESTADOR SOLO LEE EL FLAG UNIFICADO
          (p_profile = 'SMART_VACUUM_FULL' AND vft.requiere_vf = TRUE) OR
          (p_profile <> 'SMART_VACUUM_FULL' AND p_scope LIKE 'SMART%' AND st.n_dead_tup >= p_min_dead_tup AND ( (st.n_dead_tup::numeric / NULLIF(st.n_live_tup + st.n_dead_tup, 0) ) >= (p_threshold_pct / 100.0) OR st.n_dead_tup >= 100000)) OR
          (p_profile <> 'SMART_VACUUM_FULL' AND p_scope NOT LIKE 'SMART%')
      )
    ORDER BY CASE WHEN prev_t.status = 'SKIPPED_TIME_LIMIT' THEN 0 ELSE 1 END ASC, CASE WHEN p_profile = 'SMART_VACUUM_FULL' THEN COALESCE(vft.deep_free_percent, vft.approx_free_percent, 0) ELSE 0 END DESC, COALESCE(st.last_vacuum, '1970-01-01'::timestamptz) ASC, st.n_dead_tup DESC;
    COMMIT;

    SELECT COUNT(*) INTO v_total_tasks FROM maint.vacuum_tasks WHERE job_id = v_job_id;
    IF v_total_tasks = 0 THEN
        UPDATE maint.jobs SET status = 'COMPLETED', ended_at = clock_timestamp(), tables_processed = 0 WHERE job_id = v_job_id;
        IF p_verbose THEN RAISE INFO '[!] No hay tablas candidatas que cumplan los filtros actuales.'; END IF;
        COMMIT; RETURN;
    END IF;

    LOOP
        FOR r_finished IN (
            SELECT task_id, child_pid, schema_name, table_name 
            FROM maint.vacuum_tasks 
            WHERE job_id = v_job_id AND status = 'RUNNING' 
            AND child_pid NOT IN (SELECT pid FROM pg_stat_activity WHERE backend_type = 'pg_background')
        ) LOOP
            BEGIN
                PERFORM * FROM public.pg_background_result(r_finished.child_pid) AS (result TEXT);
                UPDATE maint.vacuum_tasks SET status = 'SUCCESS', ended_at = clock_timestamp(), child_pid = NULL WHERE task_id = r_finished.task_id;
                v_success_count := v_success_count + 1; 
                IF p_verbose THEN RAISE INFO '    [✓] TAREA COMPLETADA -> %.%', r_finished.schema_name, r_finished.table_name; END IF;
            EXCEPTION WHEN OTHERS THEN
                UPDATE maint.vacuum_tasks SET status = 'FAILED', ended_at = clock_timestamp(), error_log = SQLERRM, child_pid = NULL WHERE task_id = r_finished.task_id;
                IF p_verbose THEN RAISE WARNING '    [X] FALLO EN %.%: %', r_finished.schema_name, r_finished.table_name, SQLERRM; END IF;
            END;
            COMMIT; 
        END LOOP;

        IF p_cutoff_time IS NOT NULL AND LOCALTIME >= p_cutoff_time THEN
            UPDATE maint.vacuum_tasks SET status = 'SKIPPED_TIME_LIMIT', error_log = 'Cutoff Time' WHERE job_id = v_job_id AND status = 'PENDING'; 
            COMMIT;
        END IF;

        SELECT COUNT(*) INTO v_active_workers FROM maint.vacuum_tasks WHERE job_id = v_job_id AND status = 'RUNNING';
        SELECT COUNT(*) INTO v_pending_tasks FROM maint.vacuum_tasks WHERE job_id = v_job_id AND status = 'PENDING';
        
        IF v_active_workers = 0 AND v_pending_tasks = 0 THEN EXIT; END IF;

        WHILE v_active_workers < v_effective_workers AND v_pending_tasks > 0 LOOP
            IF p_cutoff_time IS NOT NULL AND LOCALTIME >= p_cutoff_time THEN EXIT; END IF;

            SELECT task_id, schema_name, table_name INTO v_task_id, v_schema, v_table FROM maint.vacuum_tasks WHERE job_id = v_job_id AND status = 'PENDING' ORDER BY task_id ASC LIMIT 1;
            
            IF v_task_id IS NOT NULL THEN
                UPDATE maint.vacuum_tasks SET status = 'RUNNING', started_at = clock_timestamp() WHERE task_id = v_task_id; COMMIT;

                IF p_profile = 'LIGHT' THEN v_raw_sql := format('VACUUM (SKIP_LOCKED ON, INDEX_CLEANUP OFF) %I.%I;', v_schema, v_table);
                ELSIF p_profile = 'BALANCED' THEN v_raw_sql := format('VACUUM (INDEX_CLEANUP AUTO) %I.%I;', v_schema, v_table);
                ELSIF p_profile = 'AGGRESSIVE' THEN v_raw_sql := format('VACUUM (INDEX_CLEANUP AUTO, PARALLEL 4, ANALYZE) %I.%I;', v_schema, v_table);
                ELSIF p_profile IN ('VACUUM_FULL', 'SMART_VACUUM_FULL') THEN v_raw_sql := format('VACUUM FULL %I.%I;', v_schema, v_table); END IF;

                v_child_pid := public.pg_background_launch(v_raw_sql);
                UPDATE maint.vacuum_tasks SET child_pid = v_child_pid WHERE task_id = v_task_id; COMMIT;

                IF p_verbose THEN RAISE INFO '    [>] LANZANDO [%] PID % -> %.%', p_profile, v_child_pid, v_schema, v_table; END IF;
                v_active_workers := v_active_workers + 1; v_pending_tasks := v_pending_tasks - 1;
            END IF;
        END LOOP;
        
        PERFORM pg_sleep(1);
    END LOOP;

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
REVOKE EXECUTE ON PROCEDURE maint.sp_pgstattuple FROM PUBLIC;

COMMIT;
