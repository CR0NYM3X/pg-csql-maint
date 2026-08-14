BEGIN;

/* =========================================================================================
   DBA SQUAD: VANGUARD BLACK-OPS
   MÓDULO: DDL y Diccionario de Datos - ORQUESTADOR DE REINDEXACIÓN CONCURRENTE
   ========================================================================================= */

-- =========================================================================================
-- 1. TABLA DE TELEMETRÍA PREDICTIVA (El Radar de Índices)
-- =========================================================================================
CREATE TABLE IF NOT EXISTS public.index_bloat_triage (
    triage_id BIGSERIAL PRIMARY KEY,
    evaluation_week DATE NOT NULL DEFAULT date_trunc('week', current_date),
    schema_name VARCHAR(255) NOT NULL,
    table_name VARCHAR(255) NOT NULL,
    index_name VARCHAR(255) NOT NULL,
    index_size_bytes BIGINT,
    leaf_fragmentation_pct NUMERIC(5,2),       -- Porcentaje de hojas fragmentadas en el B-Tree
    empty_pages_pct NUMERIC(5,2),              -- Porcentaje de páginas completamente vacías
    evaluated_at TIMESTAMPTZ DEFAULT clock_timestamp(),
    CONSTRAINT uq_triage_week_index UNIQUE (evaluation_week, schema_name, index_name)
);

COMMENT ON TABLE public.index_bloat_triage IS 'Telemetría semanal de fragmentación de índices B-Tree obtenida vía pgstatindex para justificar reconstrucciones.';
COMMENT ON COLUMN public.index_bloat_triage.leaf_fragmentation_pct IS 'Porcentaje de fragmentación. Valores > 20-30% suelen indicar necesidad de REINDEX.';


-- =========================================================================================
-- 2. TABLA DE LA COLA TRANSACCIONAL (El Registro Forense)
-- =========================================================================================
CREATE TABLE IF NOT EXISTS public.mant_reindex_task (
    task_id SERIAL PRIMARY KEY,
    job_id INT NOT NULL REFERENCES public.maintenance_jobs(job_id) ON DELETE CASCADE,
    schema_name TEXT NOT NULL,
    table_name TEXT NOT NULL,
    index_name TEXT NOT NULL,
    index_size_bytes BIGINT,
    fragmentation_pct NUMERIC(5,2),            -- Heredado del triage
    is_invalid BOOLEAN DEFAULT FALSE,          -- [CRÍTICO] Indica si el índice estaba marcado como INVALID
    status VARCHAR(20) DEFAULT 'PENDING',      -- PENDING, RUNNING, SUCCESS, FAILED, SKIPPED_TIME_LIMIT
    child_pid INT,
    started_at TIMESTAMPTZ,
    ended_at TIMESTAMPTZ,
    error_log TEXT
);

COMMENT ON TABLE public.mant_reindex_task IS 'Cola transaccional y bitácora forense para la reconstrucción concurrente de índices.';
COMMENT ON COLUMN public.mant_reindex_task.is_invalid IS 'Flag de seguridad: Si es TRUE, el orquestador deberá ejecutar un DROP/REBUILD o alertar sobre el índice corrupto.';

-- 3. ÍNDICE OPERATIVO PARA EL MOTOR ASÍNCRONO
CREATE INDEX IF NOT EXISTS idx_reindex_tasks_job_status_id 
ON public.mant_reindex_task (job_id, status, task_id);

COMMENT ON INDEX public.idx_reindex_tasks_job_status_id IS 'Índice de despacho: Acelera UPDATEs del Cutoff Time y el LIMIT 1 de la cola asíncrona.';




/* =========================================================================================
   PROCEDIMIENTO: public.sp_populate_index_triage
   FUNCIÓN: Escáner físico de fragmentación B-Tree. Llena la telemetría predictiva.
   USO RECOMENDADO: Semanal (Ej. Sábados 01:00 AM) antes de la ventana de REINDEX.
========================================================================================= */
CREATE OR REPLACE PROCEDURE public.sp_populate_index_triage(
    p_scope VARCHAR DEFAULT 'ALL_USER',
    p_min_index_mb NUMERIC DEFAULT 50.00,        -- Ignora índices menores a X Megabytes
    p_frag_pct_threshold NUMERIC DEFAULT 20.00,  -- Gatillo para reportar fragmentación foliar
    p_verbose BOOLEAN DEFAULT FALSE
)
LANGUAGE plpgsql AS $$
DECLARE
    r_idx RECORD; r_stat RECORD;
    v_week DATE := date_trunc('week', current_date)::DATE;
    v_processed INT := 0; v_sniped INT := 0;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pgstattuple') THEN
        RAISE EXCEPTION 'CRÍTICO: La extensión "pgstattuple" no está instalada.';
    END IF;

    IF p_verbose THEN
        RAISE INFO '=========================================================';
        RAISE INFO '[DBA SQUAD] RADAR DE ÍNDICES (TRIAGE) INICIADO';
        RAISE INFO 'SCOPE: % | IGNORANDO ÍNDICES MENORES A: % MB', p_scope, p_min_index_mb;
        RAISE INFO '=========================================================';
    END IF;

    FOR r_idx IN (
        SELECT 
            i.indexrelid AS index_oid, 
            n.nspname AS schema_name, 
            t.relname AS table_name, 
            c.relname AS index_name,
            pg_relation_size(i.indexrelid) AS size_bytes,
            i.indisvalid
        FROM pg_index i
        JOIN pg_class c ON i.indexrelid = c.oid
        JOIN pg_class t ON i.indrelid = t.oid
        JOIN pg_namespace n ON c.relnamespace = n.oid
        LEFT JOIN public.maintenance_filters mf ON mf.schema_name = n.nspname AND mf.table_name = t.relname
        WHERE c.relkind = 'i' AND c.relam = (SELECT oid FROM pg_am WHERE amname = 'btree')
          AND n.nspname <> 'pg_toast'
          AND pg_relation_size(i.indexrelid) >= (p_min_index_mb * 1024 * 1024)
          AND (
              (p_scope = 'CUSTOM_LIST' AND mf.force_maintenance = TRUE) OR
              (p_scope IN ('SMART_USER', 'ALL_USER') AND n.nspname NOT IN ('pg_catalog', 'information_schema')) OR
              (p_scope IN ('SMART_SYSTEM_USER', 'ALL_SYSTEM_USER')) OR
              (p_scope = 'ALL_SYSTEM' AND n.nspname IN ('pg_catalog', 'information_schema'))
          )
    ) LOOP
        BEGIN
            -- Si el índice es inválido (zombi), lo registramos con 100% de fragmentación para forzar su reconstrucción
            IF NOT r_idx.indisvalid THEN
                INSERT INTO public.index_bloat_triage (
                    evaluation_week, schema_name, table_name, index_name, index_size_bytes, leaf_fragmentation_pct, empty_pages_pct
                ) VALUES (
                    v_week, r_idx.schema_name, r_idx.table_name, r_idx.index_name, r_idx.size_bytes, 100.00, 100.00
                ) ON CONFLICT (evaluation_week, schema_name, index_name) DO UPDATE SET
                    index_size_bytes = EXCLUDED.index_size_bytes, leaf_fragmentation_pct = 100.00, evaluated_at = clock_timestamp();
                
                v_sniped := v_sniped + 1;
            ELSE
                -- Escaneo físico del B-Tree (Alto I/O)
                SELECT * INTO r_stat FROM pgstatindex(r_idx.index_oid);

                IF r_stat.leaf_fragmentation >= p_frag_pct_threshold THEN
                    INSERT INTO public.index_bloat_triage (
                        evaluation_week, schema_name, table_name, index_name, index_size_bytes, leaf_fragmentation_pct, empty_pages_pct
                    ) VALUES (
                        v_week, r_idx.schema_name, r_idx.table_name, r_idx.index_name, r_idx.size_bytes, r_stat.leaf_fragmentation, r_stat.empty_pages
                    ) ON CONFLICT (evaluation_week, schema_name, index_name) DO UPDATE SET
                        index_size_bytes = EXCLUDED.index_size_bytes, leaf_fragmentation_pct = EXCLUDED.leaf_fragmentation_pct, 
                        empty_pages_pct = EXCLUDED.empty_pages_pct, evaluated_at = clock_timestamp();
                    
                    v_sniped := v_sniped + 1;
                END IF;
            END IF;
            v_processed := v_processed + 1;

        EXCEPTION WHEN OTHERS THEN
            IF p_verbose THEN RAISE WARNING 'Error analizando índice %.%: %', r_idx.schema_name, r_idx.index_name, SQLERRM; END IF;
        END;
        COMMIT;
    END LOOP;

    IF p_verbose THEN
        RAISE INFO '[✓] TRIAGE FINALIZADO. Índices evaluados: %, Índices fragmentados/inválidos: %', v_processed, v_sniped;
    END IF;
END;
$$;




/* =========================================================================================
   PROCEDIMIENTO: public.sp_orchestrate_reindex
   FUNCIÓN: Despacha workers asíncronos para reconstruir índices B-Tree sin bloquear tablas.
   USO RECOMENDADO: Ventanas de mantenimiento críticas (Ej. Sábados 02:00 AM).
========================================================================================= */
CREATE OR REPLACE PROCEDURE public.sp_orchestrate_reindex(
    p_scope VARCHAR DEFAULT 'SMART_USER',
    p_profile VARCHAR DEFAULT 'CONCURRENT',      -- 'CONCURRENT', 'ZOMBIE_HUNTER'
    p_parallel_workers INT DEFAULT 2,            -- Hilos paralelos (Controlar para no saturar I/O)
    p_cutoff_time TIME DEFAULT NULL,             -- [KILL SWITCH] Freno de emergencia
    p_verbose BOOLEAN DEFAULT FALSE,
    p_frag_pct NUMERIC DEFAULT 20.00             -- Umbral de fragmentación para reconstruir
)
LANGUAGE plpgsql AS $$
DECLARE
    v_job_id INT; v_task_id INT; v_schema TEXT; v_index TEXT; v_child_pid INT;
    v_active_workers INT; v_pending_tasks INT; v_total_tasks INT; v_raw_sql TEXT;
    v_start_time TIMESTAMPTZ := clock_timestamp(); r_finished RECORD;
    v_success_count INT := 0; 
BEGIN
    IF p_verbose THEN
        RAISE INFO '=========================================================';
        RAISE INFO '[DBA SQUAD] INICIANDO ORQUESTADOR REINDEX VANGUARD';
        RAISE INFO 'SCOPE: % | PERFIL: % | HILOS: % | CUTOFF: %', p_scope, p_profile, p_parallel_workers, COALESCE(p_cutoff_time::TEXT, 'SIN LÍMITE');
        RAISE INFO '=========================================================';
    END IF;

    -- 1. Crear Job Padre (Se asume la existencia de la columna tables_processed para métrica RAM)
    INSERT INTO public.maintenance_jobs (job_type, maintenance_action, threshold_pct, parallel_workers, status)
    VALUES (p_scope || '_' || p_profile, 'REINDEX', p_frag_pct, p_parallel_workers, 'RUNNING')
    RETURNING job_id INTO v_job_id;
    COMMIT;

    -- 2. POBLAR COLA DE TRABAJO (Cazador de Zombis + Triage Predictivo)
    INSERT INTO public.mant_reindex_task (job_id, schema_name, table_name, index_name, index_size_bytes, fragmentation_pct, is_invalid)
    SELECT 
        v_job_id, n.nspname, t.relname, c.relname, pg_relation_size(i.indexrelid),
        COALESCE(ibt.leaf_fragmentation_pct, 0.0), NOT i.indisvalid
    FROM pg_index i
    JOIN pg_class c ON i.indexrelid = c.oid
    JOIN pg_class t ON i.indrelid = t.oid
    JOIN pg_namespace n ON c.relnamespace = n.oid
    LEFT JOIN public.maintenance_filters mf ON mf.schema_name = n.nspname AND mf.table_name = t.relname
    LEFT JOIN public.index_bloat_triage ibt ON ibt.schema_name = n.nspname AND ibt.index_name = c.relname AND ibt.evaluation_week = date_trunc('week', current_date)::DATE
    WHERE c.relkind = 'i' AND c.relam = (SELECT oid FROM pg_am WHERE amname = 'btree')
      AND n.nspname <> 'pg_toast' AND COALESCE(mf.is_ignored, FALSE) = FALSE
      AND (
          (p_scope = 'CUSTOM_LIST' AND mf.force_maintenance = TRUE) OR
          (p_scope IN ('SMART_USER', 'ALL_USER') AND n.nspname NOT IN ('pg_catalog', 'information_schema'))
      )
      AND (
          (p_profile = 'ZOMBIE_HUNTER' AND i.indisvalid = FALSE) OR 
          (p_profile = 'CONCURRENT' AND (i.indisvalid = FALSE OR ibt.leaf_fragmentation_pct >= p_frag_pct))
      )
    ORDER BY 
        CASE WHEN i.indisvalid = FALSE THEN 0 ELSE 1 END ASC, -- [Prioridad 1] Zombis
        COALESCE(ibt.leaf_fragmentation_pct, 0) DESC,         -- [Prioridad 2] Mayor fragmentación
        pg_relation_size(i.indexrelid) DESC;
    COMMIT;

    SELECT COUNT(*) INTO v_total_tasks FROM public.mant_reindex_task WHERE job_id = v_job_id;

    IF v_total_tasks = 0 THEN
        UPDATE public.maintenance_jobs SET status = 'COMPLETED', ended_at = clock_timestamp(), tables_processed = 0 WHERE job_id = v_job_id;
        IF p_verbose THEN RAISE INFO '[✓] Sistema óptimo. Ningún índice requiere reconstrucción.'; END IF;
        COMMIT; RETURN;
    END IF;

    -- 3. BUCLE DE DESPACHO ASÍNCRONO
    LOOP
        -- A. RECOLECTOR FORENSE
        FOR r_finished IN 
            SELECT task_id, child_pid, schema_name, index_name FROM public.mant_reindex_task 
            WHERE job_id = v_job_id AND status = 'RUNNING' 
              AND child_pid NOT IN (SELECT pid FROM pg_stat_activity WHERE backend_type = 'pg_background')
        LOOP
            BEGIN
                -- Módulo Defensivo: Casteo estricto ::INT para evitar el fallo técnico de PIDs como BIGINT
                PERFORM * FROM public.pg_background_result(r_finished.child_pid::INT) AS (result TEXT);
                
                UPDATE public.mant_reindex_task SET status = 'SUCCESS', ended_at = clock_timestamp(), child_pid = NULL WHERE task_id = r_finished.task_id;
                v_success_count := v_success_count + 1;
                IF p_verbose THEN RAISE INFO '   [✓] ÉXITO -> Índice: %.%', r_finished.schema_name, r_finished.index_name; END IF;
            EXCEPTION WHEN OTHERS THEN
                UPDATE public.mant_reindex_task SET status = 'FAILED', ended_at = clock_timestamp(), error_log = SQLERRM, child_pid = NULL WHERE task_id = r_finished.task_id;
                IF p_verbose THEN RAISE WARNING '   [X] FALLO EN %.%: %', r_finished.schema_name, r_finished.index_name, SQLERRM; END IF;
            END;
            COMMIT;
        END LOOP;

        -- B. FRENO DE EMERGENCIA (KILL-SWITCH)
        IF p_cutoff_time IS NOT NULL AND LOCALTIME >= p_cutoff_time THEN
            UPDATE public.mant_reindex_task SET status = 'SKIPPED_TIME_LIMIT', error_log = 'Cutoff Time Reached' 
            WHERE job_id = v_job_id AND status = 'PENDING';
            COMMIT;
        END IF;

        -- C. EVALUACIÓN DE ESTADO
        SELECT COUNT(*) INTO v_active_workers FROM public.mant_reindex_task WHERE job_id = v_job_id AND status = 'RUNNING';
        SELECT COUNT(*) INTO v_pending_tasks FROM public.mant_reindex_task WHERE job_id = v_job_id AND status = 'PENDING';

        IF v_active_workers = 0 AND v_pending_tasks = 0 THEN EXIT; END IF;

        -- D. DESPACHADOR DE TAREAS
        WHILE v_active_workers < p_parallel_workers AND v_pending_tasks > 0 LOOP
            IF p_cutoff_time IS NOT NULL AND LOCALTIME >= p_cutoff_time THEN EXIT; END IF;

            SELECT task_id, schema_name, index_name INTO v_task_id, v_schema, v_index
            FROM public.mant_reindex_task
            WHERE job_id = v_job_id AND status = 'PENDING' 
            ORDER BY task_id ASC LIMIT 1;

            IF v_task_id IS NOT NULL THEN
                UPDATE public.mant_reindex_task SET status = 'RUNNING', started_at = clock_timestamp() WHERE task_id = v_task_id;
                COMMIT;

                -- Inyección de Fuerza Bruta en RAM por Hilo
                v_raw_sql := format('SET maintenance_work_mem = ''4GB''; REINDEX INDEX CONCURRENTLY %I.%I;', v_schema, v_index);

                v_child_pid := public.pg_background_launch(v_raw_sql);
                UPDATE public.mant_reindex_task SET child_pid = v_child_pid WHERE task_id = v_task_id;
                COMMIT;

                IF p_verbose THEN RAISE INFO '    [>] LANZANDO PID % -> %.%', v_child_pid, v_schema, v_index; END IF;
                v_active_workers := v_active_workers + 1; v_pending_tasks := v_pending_tasks - 1;
            END IF;
        END LOOP;
        PERFORM pg_sleep(1);
    END LOOP;

    -- 4. CIERRE Y MÉTRICAS
    IF EXISTS (SELECT 1 FROM public.mant_reindex_task WHERE job_id = v_job_id AND status = 'SKIPPED_TIME_LIMIT') THEN
        UPDATE public.maintenance_jobs SET status = 'COMPLETED_WITH_CUTOFF', ended_at = clock_timestamp(), tables_processed = v_success_count WHERE job_id = v_job_id;
    ELSE
        UPDATE public.maintenance_jobs SET status = 'COMPLETED', ended_at = clock_timestamp(), tables_processed = v_success_count WHERE job_id = v_job_id;
    END IF;
    COMMIT;

    IF p_verbose THEN
        RAISE INFO '---------------------------------------------------------';
        RAISE INFO '[DBA SQUAD] ORQUESTACIÓN REINDEX FINALIZADA. Índices reconstruidos: %', v_success_count;
        RAISE INFO 'Tiempo Total: %', (clock_timestamp() - v_start_time);
        RAISE INFO '=========================================================';
    END IF;
END;
$$;

COMMIT;
