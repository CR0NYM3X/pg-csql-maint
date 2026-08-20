


CREATE TABLE maint.vacuum_full_tasks (
    task_id BIGSERIAL PRIMARY KEY,
    job_id INT NOT NULL,
    schema_name VARCHAR(255) NOT NULL,
    table_name VARCHAR(255) NOT NULL,
    
    -- Evidencia Forense de la Decisión
    bloat_pct_evaluado NUMERIC(5,2) NOT NULL,
    bloat_mb_evaluado NUMERIC(12,2) NOT NULL,
    sustained_days_met INT NOT NULL, -- Cuántos días consecutivos demostró estar fragmentada
    
    -- Control de Ejecución (Igual que la original, pero aislada)
    status VARCHAR(50) DEFAULT 'PENDING',
    child_pid INT,
    started_at TIMESTAMPTZ,
    ended_at TIMESTAMPTZ,
    error_log TEXT
);


CREATE OR REPLACE PROCEDURE maint.sp_orchestrate_vacuum_full(
    p_scope VARCHAR DEFAULT 'SMART_USER',
    p_profile VARCHAR DEFAULT 'SMART',      -- [NUEVO] Modos: 'SMART' (JIT+Historial) o 'FORCE_SURGERY' (Ciego)
    p_parallel_workers INT DEFAULT 1,
    p_cutoff_time TIME DEFAULT NULL,
    p_verbose BOOLEAN DEFAULT FALSE,
    p_bloat_pct_threshold NUMERIC DEFAULT 25.00,
    p_bloat_mb_threshold NUMERIC DEFAULT 1024.00,
    p_threshold_operator VARCHAR DEFAULT 'OR',
    p_sustained_days INT DEFAULT 5,
    p_min_table_mb NUMERIC DEFAULT 50.00
)
LANGUAGE plpgsql AS $$
DECLARE
    v_job_id INT; v_task_id INT; v_schema TEXT; v_table TEXT; v_child_pid INT;
    r_table RECORD; r_approx RECORD; r_finished RECORD;
    v_jit_pct NUMERIC(5,2); v_jit_mb NUMERIC(12,2); v_jit_qualifies BOOLEAN;
    v_hist_total INT; v_hist_true INT;
    v_active_workers INT := 0; v_pending_tasks INT; v_total_tasks INT := 0; v_success_count INT := 0;
    v_op_upper VARCHAR := UPPER(p_threshold_operator);
    v_profile_upper VARCHAR := UPPER(p_profile);
BEGIN
    PERFORM pg_catalog.set_config('client_min_messages', 'notice', false);
    PERFORM pg_catalog.set_config('search_path', 'maint, public, pg_temp', true);

    -- [QA] Validación de Parámetros
    IF v_op_upper NOT IN ('AND', 'OR') THEN
        RAISE EXCEPTION 'CRÍTICO: El operador debe ser AND u OR.';
    END IF;
    
    IF v_profile_upper NOT IN ('SMART', 'FORCE_SURGERY') THEN
        RAISE EXCEPTION 'CRÍTICO: El perfil solo admite ''SMART'' o ''FORCE_SURGERY''.';
    END IF;

    -- [GATEKEEPER] Compuerta de Seguridad: Bloqueo de Destrucción Masiva
    IF v_profile_upper = 'FORCE_SURGERY' AND UPPER(p_scope) <> 'CUSTOM_LIST' THEN
        RAISE EXCEPTION 'ALERTA DE SEGURIDAD (CÓDIGO ROJO): No puedes forzar una cirugía mayor ciega (FORCE_SURGERY) sin especificar p_scope = ''CUSTOM_LIST''. Reducir el radio de impacto a las tablas especificadas en maint.filters es obligatorio para proteger el clúster.';
    END IF;

    -- 1. Crear Job Header
    INSERT INTO maint.jobs (job_type, maintenance_action, threshold_pct, parallel_workers, status)
    VALUES (p_scope || '_' || v_profile_upper || '_SURGERY', 'VACUUM_FULL', p_bloat_pct_threshold, p_parallel_workers, 'RUNNING') 
    RETURNING job_id INTO v_job_id;
    COMMIT;

    IF p_verbose THEN RAISE INFO '=== [DBA SQUAD] INICIANDO CIRUGÍA MAYOR (JOB % | MODO: %) ===', v_job_id, v_profile_upper; END IF;

    -- 2. Triage de Tablas
    FOR r_table IN (
        SELECT c.oid AS table_oid, n.nspname AS schema_name, c.relname AS table_name
        FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
        LEFT JOIN maint.filters mf ON mf.schema_name = n.nspname AND mf.table_name = c.relname
        WHERE c.relkind IN ('r', 'm') AND n.nspname NOT IN ('pg_toast', 'pg_catalog', 'information_schema')
          AND (
              -- Si es CUSTOM_LIST, ignoramos el tamaño mínimo y el is_ignored general. Manda force_maintenance.
              (p_scope = 'CUSTOM_LIST' AND mf.force_maintenance = TRUE) 
              OR
              -- Para los demás, rige el filtro de tamaño y exclusiones.
              (p_scope IN ('SMART_USER', 'ALL_USER') 
               AND pg_relation_size(c.oid) >= (p_min_table_mb * 1024 * 1024) 
               AND COALESCE(mf.is_ignored, FALSE) = FALSE)
          )
    ) LOOP
        
        -- RUTA A: MODO FRANCOTIRADOR CIEGO (FORCE_SURGERY)
        IF v_profile_upper = 'FORCE_SURGERY' THEN
            INSERT INTO maint.vacuum_full_tasks (job_id, schema_name, table_name, bloat_pct_evaluado, bloat_mb_evaluado, sustained_days_met, status)
            VALUES (v_job_id, r_table.schema_name, r_table.table_name, 0.00, 0.00, 0, 'PENDING');
            v_total_tasks := v_total_tasks + 1;
            IF p_verbose THEN RAISE INFO '[EJECUCIÓN FORZADA] %.% encolada sin evaluación.', r_table.schema_name, r_table.table_name; END IF;

        -- RUTA B: MODO INTELIGENTE (SMART - JIT + Historial)
        ELSE
            -- Evaluación Just-In-Time
            SELECT * INTO r_approx FROM pgstattuple_approx(r_table.table_oid);
            
            v_jit_pct := COALESCE(r_approx.approx_free_percent, 0.00) + COALESCE(r_approx.dead_tuple_percent, 0.00);
            v_jit_mb  := ROUND(((COALESCE(r_approx.approx_free_space, 0) + COALESCE(r_approx.dead_tuple_len, 0)) / 1024.0 / 1024.0), 2);

            IF v_op_upper = 'AND' THEN v_jit_qualifies := (v_jit_pct >= p_bloat_pct_threshold AND v_jit_mb >= p_bloat_mb_threshold);
            ELSE v_jit_qualifies := (v_jit_pct >= p_bloat_pct_threshold OR v_jit_mb >= p_bloat_mb_threshold); END IF;

            IF v_jit_qualifies THEN
                -- Evaluación Forense (Historial)
                SELECT COUNT(*), COALESCE(SUM(CASE WHEN requiere_vf THEN 1 ELSE 0 END), 0)
                INTO v_hist_total, v_hist_true
                FROM (
                    SELECT requiere_vf FROM maint.pgstattuple
                    WHERE schema_name = r_table.schema_name AND table_name = r_table.table_name
                    ORDER BY evaluation_date DESC LIMIT p_sustained_days
                ) sub;

                IF v_hist_total >= p_sustained_days AND v_hist_total = v_hist_true THEN
                    INSERT INTO maint.vacuum_full_tasks (job_id, schema_name, table_name, bloat_pct_evaluado, bloat_mb_evaluado, sustained_days_met, status)
                    VALUES (v_job_id, r_table.schema_name, r_table.table_name, v_jit_pct, v_jit_mb, v_hist_total, 'PENDING');
                    v_total_tasks := v_total_tasks + 1;
                    IF p_verbose THEN RAISE INFO '[BLANCO CONFIRMADO] %.% | Bloat: % MB | Días: %', r_table.schema_name, r_table.table_name, v_jit_mb, v_hist_total; END IF;
                ELSE
                    IF p_verbose THEN RAISE INFO '[FALSO POSITIVO IGNORADO] %.% | Supera JIT, pero historial es inestable (%/%).', r_table.schema_name, r_table.table_name, v_hist_true, p_sustained_days; END IF;
                END IF;
            END IF;
        END IF;
    END LOOP;
    COMMIT;

    -- 3. Ejecución de Cirugía (Si hay tareas)
    IF v_total_tasks = 0 THEN
        UPDATE maint.jobs SET status = 'COMPLETED', ended_at = clock_timestamp(), tables_processed = 0 WHERE job_id = v_job_id;
        IF p_verbose THEN RAISE INFO '[✓] No hay tablas que requieran cirugía mayor.'; END IF;
        COMMIT; RETURN;
    END IF;

    LOOP
        FOR r_finished IN (SELECT task_id, child_pid, schema_name, table_name FROM maint.vacuum_full_tasks WHERE job_id = v_job_id AND status = 'RUNNING' AND child_pid NOT IN (SELECT pid FROM pg_stat_activity WHERE backend_type = 'pg_background')) LOOP
            BEGIN
                PERFORM * FROM public.pg_background_result(r_finished.child_pid) AS (result TEXT);
                UPDATE maint.vacuum_full_tasks SET status = 'SUCCESS', ended_at = clock_timestamp(), child_pid = NULL WHERE task_id = r_finished.task_id;
                v_success_count := v_success_count + 1; 
                IF p_verbose THEN RAISE INFO '    [✓] CIRUGÍA COMPLETADA -> %.%', r_finished.schema_name, r_finished.table_name; END IF;
            EXCEPTION WHEN OTHERS THEN
                UPDATE maint.vacuum_full_tasks SET status = 'FAILED', ended_at = clock_timestamp(), error_log = SQLERRM, child_pid = NULL WHERE task_id = r_finished.task_id;
                IF p_verbose THEN RAISE WARNING '    [X] FALLO CRÍTICO EN %.%: %', r_finished.schema_name, r_finished.table_name, SQLERRM; END IF;
            END;
            COMMIT; 
        END LOOP;

        IF p_cutoff_time IS NOT NULL AND LOCALTIME >= p_cutoff_time THEN
            UPDATE maint.vacuum_full_tasks SET status = 'SKIPPED_TIME_LIMIT', error_log = 'Cutoff Time Reached' WHERE job_id = v_job_id AND status = 'PENDING'; COMMIT;
        END IF;

        SELECT COUNT(*) INTO v_active_workers FROM maint.vacuum_full_tasks WHERE job_id = v_job_id AND status = 'RUNNING';
        SELECT COUNT(*) INTO v_pending_tasks FROM maint.vacuum_full_tasks WHERE job_id = v_job_id AND status = 'PENDING';
        
        IF v_active_workers = 0 AND v_pending_tasks = 0 THEN EXIT; END IF;

        WHILE v_active_workers < p_parallel_workers AND v_pending_tasks > 0 LOOP
            IF p_cutoff_time IS NOT NULL AND LOCALTIME >= p_cutoff_time THEN EXIT; END IF;

            SELECT task_id, schema_name, table_name INTO v_task_id, v_schema, v_table FROM maint.vacuum_full_tasks WHERE job_id = v_job_id AND status = 'PENDING' ORDER BY task_id ASC LIMIT 1;
            
            IF v_task_id IS NOT NULL THEN
                UPDATE maint.vacuum_full_tasks SET status = 'RUNNING', started_at = clock_timestamp() WHERE task_id = v_task_id; COMMIT;
                v_child_pid := public.pg_background_launch(format('VACUUM FULL %I.%I;', v_schema, v_table));
                UPDATE maint.vacuum_full_tasks SET child_pid = v_child_pid WHERE task_id = v_task_id; COMMIT;

                IF p_verbose THEN RAISE INFO '    [>] LANZANDO [VACUUM FULL] PID % -> %.%', v_child_pid, v_schema, v_table; END IF;
                v_active_workers := v_active_workers + 1; v_pending_tasks := v_pending_tasks - 1;
            END IF;
        END LOOP;
        PERFORM pg_sleep(2);
    END LOOP;

    UPDATE maint.jobs SET status = 'COMPLETED', ended_at = clock_timestamp(), tables_processed = v_success_count WHERE job_id = v_job_id; COMMIT;
    IF p_verbose THEN RAISE INFO '[✓] ORQUESTACIÓN QUIRÚRGICA FINALIZADA. Procesadas: % / %', v_success_count, v_total_tasks; END IF;
END;
$$;



