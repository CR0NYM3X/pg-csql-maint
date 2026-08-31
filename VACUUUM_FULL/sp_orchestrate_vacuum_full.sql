/* =========================================================================================
   ██████╗ ██████╗  █████╗     ███████╗ ██████╗ ██╗   ██╗ █████╗ ██████╗ 
   ██╔══██╗██╔══██╗██╔══██╗    ██╔════╝██╔═══██╗██║   ██║██╔══██╗██╔══██╗
   ██║  ██║██████╔╝███████║    ███████╗██║   ██║██║   ██║███████║██║  ██║
   ██║  ██║██╔══██╗██╔══██║    ╚════██║██║▄▄ ██║██║   ██║██╔══██║██║  ██║
   ██████╔╝██████╔╝██║  ██║    ███████║╚██████╔╝╚██████╔╝██║  ██║██████╔╝
   ╚═════╝ ╚═════╝ ╚═╝  ╚═╝    ╚══════╝ ╚══▀▀═╝  ╚═════╝ ╚═╝  ╚═╝╚═════╝ 
                               VANGUARD BLACK-OPS
                               
   MÓDULO: Suite Completa de Mantenimiento Asíncrono (VACUUM FULL)
   Compatibilidad : Universal (<= pg_background 1.4 y >= 2.0 / Cloud SQL & On-Premise)
   VERSIÓN: 3.4.9 (Grado Diamante - relfilenode Checksum & Universal Late Binding)
   ARQUITECTURA: Multi-hilo, Resiliente, Forense, Libre de Subtransacciones.
========================================================================================= */
BEGIN;

CREATE SCHEMA IF NOT EXISTS maint;

-- =========================================================================================
-- [FASE 1]: EXTENSIONES DEL KERNEL DE POSTGRESQL
-- =========================================================================================
CREATE EXTENSION IF NOT EXISTS pgstattuple;
CREATE EXTENSION IF NOT EXISTS pg_background;

-- =========================================================================================
-- 1. TABLA PADRE: Orquestación Global de Trabajos (Maestra Unificada)
-- =========================================================================================
CREATE TABLE IF NOT EXISTS maint.jobs (
    job_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    job_type VARCHAR(50) NOT NULL,              -- Ej. 'ALL_USER_BALANCED', 'CUSTOM_LIST_FORCE_SURGERY'
    maintenance_action VARCHAR(20) NOT NULL,    -- 'ANALYZE', 'VACUUM', 'VACUUM_FULL', 'REINDEX'
    orchestrator_pid INT NOT NULL,              -- PID del proceso principal (Padre) para Self-Healing
    execution_params JSONB NOT NULL,             -- Fotografía inmutable de los parámetros
    status VARCHAR(30) NOT NULL DEFAULT 'RUNNING',-- 'RUNNING', 'COMPLETED', 'COMPLETED_WITH_CUTOFF', 'ABORTED_ORPHAN'
    tables_processed INT DEFAULT 0,             -- Cantidad real de tablas intervenidas exitosamente
    started_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    ended_at TIMESTAMPTZ                        -- Sello de tiempo final
);

CREATE INDEX IF NOT EXISTS idx_jobs_status_action 
ON maint.jobs (status, maintenance_action) 
WHERE status = 'RUNNING';

CREATE INDEX IF NOT EXISTS idx_maint_jobs_type_action_id 
ON maint.jobs (job_type, maintenance_action, job_id DESC);

COMMENT ON TABLE maint.jobs IS 'Cabecera maestra unificada que registra la ejecución global, estado y parámetros JSONB de cada ciclo de orquestación.';

-- =========================================================================================
-- 2. TABLA DE CONTROL: Reglas y Filtros de Seguridad (Blacklist / Whitelist)
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
-- 3. PERFILES DE VACUUM ORDINARIO
-- =========================================================================================
CREATE TABLE IF NOT EXISTS maint.vacuum_profiles (
    profile_name VARCHAR(50) PRIMARY KEY,
    description TEXT,
    is_analyze BOOLEAN DEFAULT FALSE,
    is_freeze BOOLEAN DEFAULT FALSE,
    skip_locked BOOLEAN DEFAULT TRUE,
    is_verbose BOOLEAN DEFAULT FALSE,
    index_cleanup VARCHAR(10) DEFAULT 'AUTO',
    truncate_pages BOOLEAN DEFAULT TRUE,
    parallel_workers INT DEFAULT 0,
    created_at TIMESTAMPTZ DEFAULT clock_timestamp(),
    updated_by VARCHAR(100) DEFAULT current_user,
    
    CONSTRAINT chk_index_cleanup CHECK (index_cleanup IN ('AUTO', 'ON', 'OFF')),
    CONSTRAINT chk_parallel_limit CHECK (parallel_workers BETWEEN 0 AND 32)
);

INSERT INTO maint.vacuum_profiles (profile_name, description, skip_locked, index_cleanup, is_analyze, parallel_workers) 
VALUES 
('LIGHT', 'Perfil inofensivo. Salta bloqueos y no limpia índices.', TRUE, 'OFF', FALSE, 0),
('BALANCED', 'Perfil estándar. Limpia índices automáticamente.', FALSE, 'AUTO', FALSE, 0),
('AGGRESSIVE', 'Perfil profundo. Fuerza hilos paralelos y actualiza estadísticas.', FALSE, 'AUTO', TRUE, 4)
ON CONFLICT (profile_name) DO NOTHING;

-- =========================================================================================
-- 4. TABLA DE TELEMETRÍA FÍSICA: maint.pgstattuple (Granularidad en Kilobytes)
-- =========================================================================================
CREATE TABLE IF NOT EXISTS maint.pgstattuple (
    triage_id BIGSERIAL PRIMARY KEY, 
    evaluation_date DATE NOT NULL DEFAULT current_date, 
    schema_name VARCHAR(255) NOT NULL, 
    table_name VARCHAR(255) NOT NULL, 
    
    approx_scanned BOOLEAN NOT NULL DEFAULT FALSE, 
    approx_evaluated_at TIMESTAMPTZ, 
    approx_table_len BIGINT, 
    approx_scanned_percent NUMERIC(5,2),
    approx_tuple_count BIGINT,
    approx_tuple_len BIGINT,
    approx_tuple_percent NUMERIC(5,2),
    approx_dead_tuple_count BIGINT,
    approx_dead_tuple_len BIGINT,
    approx_dead_tuple_percent NUMERIC(5,2),
    approx_free_space BIGINT,
    approx_free_percent NUMERIC(5,2),
    
    deep_scanned BOOLEAN NOT NULL DEFAULT FALSE, 
    deep_evaluated_at TIMESTAMPTZ, 
    deep_table_len BIGINT, 
    deep_tuple_count BIGINT,
    deep_tuple_len BIGINT,
    deep_tuple_percent NUMERIC(5,2),
    deep_dead_tuple_count BIGINT,
    deep_dead_tuple_len BIGINT,
    deep_dead_tuple_percent NUMERIC(5,2),
    deep_free_space BIGINT,
    deep_free_percent NUMERIC(5,2),
    
    total_bloat_kb NUMERIC(14,2) NOT NULL DEFAULT 0.00,
    total_bloat_pct NUMERIC(12,2) NOT NULL DEFAULT 0.00,
    requiere_vf BOOLEAN NOT NULL DEFAULT FALSE, 

    CONSTRAINT uq_triage_date_schema_table UNIQUE (evaluation_date, schema_name, table_name)
);

COMMENT ON TABLE maint.pgstattuple IS 'Histórico diario de telemetría física en Kilobytes. Registra el bloat real independientemente de Autovacuum.';

CREATE TABLE IF NOT EXISTS maint.vacuum_full_tasks (
    task_id BIGSERIAL PRIMARY KEY,
    job_id BIGINT NOT NULL REFERENCES maint.jobs(job_id) ON DELETE CASCADE,
    schema_name VARCHAR(255) NOT NULL,
    table_name VARCHAR(255) NOT NULL,
    bloat_pct_evaluado NUMERIC(5,2) NOT NULL,
    bloat_kb_evaluado NUMERIC(14,2) NOT NULL,
    sustained_days_met INT NOT NULL, 
    old_relfilenode BIGINT,               -- Checksum Físico: Inodo de archivo ANTES de la cirugía
    new_relfilenode BIGINT,               -- Checksum Físico: Inodo de archivo DESPUÉS de la cirugía
    status VARCHAR(30) DEFAULT 'PENDING',
    child_pid INT,
    child_cookie BIGINT,                          -- [HOMOLOGACIÓN UNIVERSAL]: Token de seguridad v2.0
    started_at TIMESTAMPTZ,
    ended_at TIMESTAMPTZ,
    error_log TEXT
);

-- Migración idempotente en caso de que la tabla ya existiera previamente
DO $$ 
BEGIN 
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_schema = 'maint' AND table_name = 'vacuum_full_tasks' AND column_name = 'child_cookie'
    ) THEN 
        ALTER TABLE maint.vacuum_full_tasks ADD COLUMN child_cookie BIGINT; 
    END IF; 
END $$;

COMMENT ON COLUMN maint.vacuum_full_tasks.old_relfilenode IS 'Firma física del archivo en disco antes del VACUUM FULL.';
COMMENT ON COLUMN maint.vacuum_full_tasks.new_relfilenode IS 'Firma física del archivo en disco después del VACUUM FULL. Debe cambiar obligatoriamente para certificar el éxito.';

-- =========================================================================================
-- 6. PROCEDIMIENTO: RADAR DE TRIAGE (maint.sp_pgstattuple)
-- =========================================================================================
CREATE OR REPLACE PROCEDURE maint.sp_pgstattuple(
    p_scope VARCHAR DEFAULT 'ALL_USER',
    p_bloat_pct_threshold NUMERIC DEFAULT 25.00,
    p_bloat_mb_threshold NUMERIC DEFAULT 1024.00,
    p_threshold_operator VARCHAR DEFAULT 'OR',  
    p_min_table_mb NUMERIC DEFAULT 0.00,
    p_force_bloat_mb NUMERIC DEFAULT NULL,      -- [NUEVO]: Bypass de emergencia en MB para el Radar
    p_enable_deep_scan BOOLEAN DEFAULT FALSE,
    p_verbose BOOLEAN DEFAULT FALSE
)
LANGUAGE plpgsql AS $$
DECLARE
    r_table RECORD; r_approx RECORD; r_deep RECORD;
    v_today DATE := current_date; 
    v_processed INT := 0; v_sniped INT := 0;
    v_requiere_vf_count INT := 0;
    v_total_bloat_pct NUMERIC(5,2); 
    v_total_bloat_kb NUMERIC(14,2);
    v_threshold_kb NUMERIC(14,2) := (p_bloat_mb_threshold * 1024.0);
    v_force_bloat_kb NUMERIC(14,2) := CASE WHEN p_force_bloat_mb IS NOT NULL THEN (p_force_bloat_mb * 1024.0) ELSE NULL END;
    v_requiere_vf BOOLEAN := FALSE;
    v_op_upper VARCHAR := UPPER(p_threshold_operator);
BEGIN
    PERFORM pg_catalog.set_config('client_min_messages', 'notice', false);
    PERFORM pg_catalog.set_config('search_path', 'maint, public, pg_temp', true);

    IF v_op_upper NOT IN ('AND', 'OR') THEN
        RAISE EXCEPTION 'CRÍTICO: El parámetro p_threshold_operator solo admite ''AND'' u ''OR''. Valor recibido: %', p_threshold_operator;
    END IF;

    IF p_verbose THEN
        RAISE INFO '=========================================================';
        RAISE INFO '[DBA SQUAD] RADAR DE TRIAGE DIARIO (V3.4.9 - LOGIC: % | THRESHOLD: % KB | FORCE: %)', 
                   v_op_upper, v_threshold_kb, COALESCE(v_force_bloat_kb::TEXT || ' KB', 'DESACTIVADO');
        RAISE INFO '=========================================================';
    END IF;

    -- Evaluamos TODAS las tablas del ámbito para dar visibilidad total al DBA
    FOR r_table IN (
        SELECT c.oid AS table_oid, n.nspname AS schema_name, c.relname AS table_name
        FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
        LEFT JOIN maint.filters mf ON mf.schema_name = n.nspname AND mf.table_name = c.relname
          AND mf.maintenance_action IN ('ALL', 'VACUUM_FULL')
        WHERE c.relkind IN ('r', 'm') AND n.nspname <> 'pg_toast'
          AND pg_relation_size(c.oid) >= (p_min_table_mb * 1024 * 1024)
          AND (
              (p_scope = 'CUSTOM_LIST' AND mf.force_maintenance = TRUE) OR
              (p_scope = 'ALL_USER' AND n.nspname NOT IN ('pg_catalog', 'information_schema')) OR
              (p_scope = 'ALL_SYSTEM_USER') OR
              (p_scope = 'ALL_SYSTEM' AND n.nspname IN ('pg_catalog', 'information_schema'))
          )
    ) LOOP
        BEGIN
            SELECT * INTO r_approx FROM pgstattuple_approx(r_table.table_oid);
            v_processed := v_processed + 1;

            v_total_bloat_pct := COALESCE(r_approx.approx_free_percent, 0.00) + COALESCE(r_approx.dead_tuple_percent, 0.00);
            v_total_bloat_kb  := ROUND(((COALESCE(r_approx.approx_free_space, 0) + COALESCE(r_approx.dead_tuple_len, 0)) / 1024.0), 2);

            -- EVALUACIÓN MATEMÁTICA CON TRIPLE VÍA (BYPASS / AND / OR)
            IF v_force_bloat_kb IS NOT NULL AND v_total_bloat_kb >= v_force_bloat_kb THEN
                v_requiere_vf := TRUE; -- BYPASS DIRECTO POR TAMAÑO MASIVO
            ELSIF v_op_upper = 'AND' THEN
                v_requiere_vf := (v_total_bloat_pct >= p_bloat_pct_threshold AND v_total_bloat_kb >= v_threshold_kb);
            ELSE
                v_requiere_vf := (v_total_bloat_pct >= p_bloat_pct_threshold OR v_total_bloat_kb >= v_threshold_kb);
            END IF;

            IF p_enable_deep_scan AND v_requiere_vf THEN
                SELECT * INTO r_deep FROM pgstattuple(r_table.table_oid);
                
                v_total_bloat_pct := COALESCE(r_deep.free_percent, 0.00) + COALESCE(r_deep.dead_tuple_percent, 0.00);
                v_total_bloat_kb  := ROUND(((COALESCE(r_deep.free_space, 0) + COALESCE(r_deep.dead_tuple_len, 0)) / 1024.0), 2);
                
                IF v_force_bloat_kb IS NOT NULL AND v_total_bloat_kb >= v_force_bloat_kb THEN
                    v_requiere_vf := TRUE;
                ELSIF v_op_upper = 'AND' THEN
                    v_requiere_vf := (v_total_bloat_pct >= p_bloat_pct_threshold AND v_total_bloat_kb >= v_threshold_kb);
                ELSE
                    v_requiere_vf := (v_total_bloat_pct >= p_bloat_pct_threshold OR v_total_bloat_kb >= v_threshold_kb);
                END IF;

                INSERT INTO maint.pgstattuple (
                    evaluation_date, schema_name, table_name, 
                    approx_scanned, approx_evaluated_at, approx_table_len, approx_scanned_percent, approx_tuple_count, approx_tuple_len, approx_tuple_percent, approx_dead_tuple_count, approx_dead_tuple_len, approx_dead_tuple_percent, approx_free_space, approx_free_percent,
                    deep_scanned, deep_evaluated_at, deep_table_len, deep_tuple_count, deep_tuple_len, deep_tuple_percent, deep_dead_tuple_count, deep_dead_tuple_len, deep_dead_tuple_percent, deep_free_space, deep_free_percent,
                    total_bloat_kb, total_bloat_pct, requiere_vf
                ) VALUES (
                    v_today, r_table.schema_name, r_table.table_name, 
                    TRUE, clock_timestamp(), COALESCE(r_approx.table_len, 0), COALESCE(r_approx.scanned_percent, 0.00), COALESCE(r_approx.approx_tuple_count, 0), COALESCE(r_approx.approx_tuple_len, 0), COALESCE(r_approx.approx_tuple_percent, 0.00), COALESCE(r_approx.dead_tuple_count, 0), COALESCE(r_approx.dead_tuple_len, 0), COALESCE(r_approx.dead_tuple_percent, 0.00), COALESCE(r_approx.approx_free_space, 0), COALESCE(r_approx.approx_free_percent, 0.00),
                    TRUE, clock_timestamp(), COALESCE(r_deep.table_len, 0), COALESCE(r_deep.tuple_count, 0), COALESCE(r_deep.tuple_len, 0), COALESCE(r_deep.tuple_percent, 0.00), COALESCE(r_deep.dead_tuple_count, 0), COALESCE(r_deep.dead_tuple_len, 0), COALESCE(r_deep.dead_tuple_percent, 0.00), COALESCE(r_deep.free_space, 0), COALESCE(r_deep.free_percent, 0.00),
                    v_total_bloat_kb, v_total_bloat_pct, v_requiere_vf
                ) ON CONFLICT (evaluation_date, schema_name, table_name) DO UPDATE SET
                    approx_scanned = TRUE, approx_evaluated_at = clock_timestamp(), approx_table_len = EXCLUDED.approx_table_len, approx_scanned_percent = EXCLUDED.approx_scanned_percent, approx_tuple_count = EXCLUDED.approx_tuple_count, approx_tuple_len = EXCLUDED.approx_tuple_len, approx_tuple_percent = EXCLUDED.approx_tuple_percent, approx_dead_tuple_count = EXCLUDED.approx_dead_tuple_count, approx_dead_tuple_len = EXCLUDED.approx_dead_tuple_len, approx_dead_tuple_percent = EXCLUDED.approx_dead_tuple_percent, approx_free_space = EXCLUDED.approx_free_space, approx_free_percent = EXCLUDED.approx_free_percent,
                    deep_scanned = TRUE, deep_evaluated_at = clock_timestamp(), deep_table_len = EXCLUDED.deep_table_len, deep_tuple_count = EXCLUDED.deep_tuple_count, deep_tuple_len = EXCLUDED.deep_tuple_len, deep_tuple_percent = EXCLUDED.deep_tuple_percent, deep_dead_tuple_count = EXCLUDED.deep_dead_tuple_count, deep_dead_tuple_len = EXCLUDED.deep_dead_tuple_len, deep_dead_tuple_percent = EXCLUDED.deep_dead_tuple_percent, deep_free_space = EXCLUDED.deep_free_space, deep_free_percent = EXCLUDED.deep_free_percent,
                    total_bloat_kb = EXCLUDED.total_bloat_kb, total_bloat_pct = EXCLUDED.total_bloat_pct, requiere_vf = EXCLUDED.requiere_vf;
                
                v_sniped := v_sniped + 1;
            ELSE
                INSERT INTO maint.pgstattuple (
                    evaluation_date, schema_name, table_name, 
                    approx_scanned, approx_evaluated_at, approx_table_len, approx_scanned_percent, approx_tuple_count, approx_tuple_len, approx_tuple_percent, approx_dead_tuple_count, approx_dead_tuple_len, approx_dead_tuple_percent, approx_free_space, approx_free_percent,
                    total_bloat_kb, total_bloat_pct, requiere_vf
                ) VALUES (
                    v_today, r_table.schema_name, r_table.table_name, 
                    TRUE, clock_timestamp(), COALESCE(r_approx.table_len, 0), COALESCE(r_approx.scanned_percent, 0.00), COALESCE(r_approx.approx_tuple_count, 0), COALESCE(r_approx.approx_tuple_len, 0), COALESCE(r_approx.approx_tuple_percent, 0.00), COALESCE(r_approx.dead_tuple_count, 0), COALESCE(r_approx.dead_tuple_len, 0), COALESCE(r_approx.dead_tuple_percent, 0.00), COALESCE(r_approx.approx_free_space, 0), COALESCE(r_approx.approx_free_percent, 0.00),
                    v_total_bloat_kb, v_total_bloat_pct, v_requiere_vf
                ) ON CONFLICT (evaluation_date, schema_name, table_name) DO UPDATE SET
                    approx_scanned = TRUE, approx_evaluated_at = clock_timestamp(), approx_table_len = EXCLUDED.approx_table_len, approx_scanned_percent = EXCLUDED.approx_scanned_percent, approx_tuple_count = EXCLUDED.approx_tuple_count, approx_tuple_len = EXCLUDED.approx_tuple_len, approx_tuple_percent = EXCLUDED.approx_tuple_percent, approx_dead_tuple_count = EXCLUDED.approx_dead_tuple_count, approx_dead_tuple_len = EXCLUDED.approx_dead_tuple_len, approx_dead_tuple_percent = EXCLUDED.approx_dead_tuple_percent, approx_free_space = EXCLUDED.approx_free_space, approx_free_percent = EXCLUDED.approx_free_percent,
                    total_bloat_kb = EXCLUDED.total_bloat_kb, total_bloat_pct = EXCLUDED.total_bloat_pct, requiere_vf = EXCLUDED.requiere_vf;
            END IF;

            IF v_requiere_vf THEN
                v_requiere_vf_count := v_requiere_vf_count + 1;
            END IF;

        EXCEPTION WHEN OTHERS THEN
            IF p_verbose THEN RAISE WARNING 'Error analizando %.%: %', r_table.schema_name, r_table.table_name, SQLERRM; END IF;
        END;
        COMMIT; 
    END LOOP;

    IF p_verbose THEN 
        RAISE INFO '[✓] TRIAGE FINALIZADO. Evaluadas: %, Deep Scans: %, Requiere VF: %', v_processed, v_sniped, v_requiere_vf_count; 
    END IF;
END;
$$;

REVOKE EXECUTE ON PROCEDURE maint.sp_pgstattuple FROM PUBLIC;

-- =========================================================================================
-- 7. ORQUESTADOR QUIRÚRGICO: maint.sp_orchestrate_vacuum_full (V3.4.9 Polimórfico Universal)
-- =========================================================================================
CREATE OR REPLACE PROCEDURE maint.sp_orchestrate_vacuum_full(
    p_scope VARCHAR DEFAULT 'ALL_USER',         -- 'ALL_USER', 'ALL_SYSTEM', 'ALL_SYSTEM_USER', 'CUSTOM_LIST'
    p_profile VARCHAR DEFAULT 'SMART',          -- 'SMART' (Radar+Histórico), 'FORCE_SURGERY' (Ciego)
    p_parallel_workers INT DEFAULT 1,           -- Rango estricto permitido: 1 a 2
    p_cutoff_time TIME DEFAULT NULL,
    p_verbose BOOLEAN DEFAULT FALSE,
    p_bloat_pct_threshold NUMERIC DEFAULT 25.00,
    p_bloat_mb_threshold NUMERIC DEFAULT 1024.00,
    p_threshold_operator VARCHAR DEFAULT 'OR',
    p_sustained_days INT DEFAULT 5,
    p_min_table_mb NUMERIC DEFAULT 50.00,
    p_force_bloat_mb NUMERIC DEFAULT NULL,      -- Bypass de emergencia en MB
    p_enable_deep_scan BOOLEAN DEFAULT FALSE,
    p_keep_history BOOLEAN DEFAULT TRUE
)
LANGUAGE plpgsql AS $$
DECLARE
    v_job_id BIGINT; v_task_id BIGINT; v_schema TEXT; v_table TEXT; v_child_pid INT; v_child_cookie BIGINT;
    v_bloat_kb_eval NUMERIC(14,2); v_days_met INT;
    r_table RECORD; r_finished RECORD;
    v_hist_total INT; v_hist_true INT;
    v_active_workers INT := 0; v_pending_tasks INT; v_total_tasks INT := 0; v_success_count INT := 0;
    v_healed_count INT := 0;
    v_profile_upper VARCHAR := UPPER(p_profile);
    v_op_upper VARCHAR := UPPER(p_threshold_operator);
    v_start_time TIMESTAMPTZ := clock_timestamp();
    v_execution_params JSONB;
    v_orphaned_job RECORD;
    v_old_node BIGINT; v_new_node BIGINT;
    
    v_bloat_kb_threshold NUMERIC(14,2) := (p_bloat_mb_threshold * 1024.0);
    v_force_bloat_kb NUMERIC(14,2) := CASE WHEN p_force_bloat_mb IS NOT NULL THEN (p_force_bloat_mb * 1024.0) ELSE NULL END;
    v_force_bypass BOOLEAN := FALSE;
    
    -- [INYECCIÓN POLIMÓRFICA]: Control dinámico de versión sin pg_background_handle
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

    -- Pre-flight checks
    IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_background') THEN
        RAISE EXCEPTION 'CRÍTICO [INFRAESTRUCTURA]: La extensión "pg_background" no está instalada en la base de datos.';
    END IF;

    IF (SELECT current_setting('max_worker_processes')::INT) < p_parallel_workers THEN
        RAISE EXCEPTION 'CRÍTICO [RECURSOS]: El parámetro max_worker_processes (%) del servidor es menor a los hilos solicitados (%).', 
                        current_setting('max_worker_processes'), p_parallel_workers;
    END IF;

    IF p_parallel_workers < 1 OR p_parallel_workers > 2 THEN
        RAISE EXCEPTION 'ALERTA DE SEGURIDAD I/O [RECHAZADO]: Solicitados % hilos para VACUUM FULL. El tope estricto de seguridad permitido es entre 1 y 2 hilos paralelos.', p_parallel_workers;
    END IF;

    IF v_profile_upper NOT IN ('SMART', 'FORCE_SURGERY') THEN
        RAISE EXCEPTION 'CRÍTICO: El perfil solo admite ''SMART'' o ''FORCE_SURGERY''.';
    END IF;

    IF UPPER(p_scope) NOT IN ('ALL_USER', 'ALL_SYSTEM', 'ALL_SYSTEM_USER', 'CUSTOM_LIST') THEN
        RAISE EXCEPTION 'CRÍTICO: El ámbito (p_scope) "%" no es válido. Use ALL_USER, ALL_SYSTEM, ALL_SYSTEM_USER o CUSTOM_LIST.', p_scope;
    END IF;

    IF v_profile_upper = 'FORCE_SURGERY' AND UPPER(p_scope) <> 'CUSTOM_LIST' THEN
        RAISE EXCEPTION 'ALERTA DE SEGURIDAD (CÓDIGO ROJO): No puedes forzar una cirugía mayor ciega (FORCE_SURGERY) sin especificar p_scope = ''CUSTOM_LIST''.';
    END IF;

    -- 1. Self-Healing
    FOR v_orphaned_job IN (
        SELECT j.job_id 
        FROM maint.jobs j
        WHERE j.status = 'RUNNING' 
          AND j.maintenance_action = 'VACUUM_FULL'
          AND NOT EXISTS (
              SELECT 1 FROM pg_stat_activity a 
              WHERE a.pid = j.orchestrator_pid 
                AND a.pid != pg_backend_pid()
                AND a.state != 'idle'
          )
          AND NOT EXISTS (
              SELECT 1 FROM maint.vacuum_full_tasks t
              JOIN pg_stat_activity a ON a.pid = t.child_pid
              WHERE t.job_id = j.job_id 
                AND t.status = 'RUNNING'
                AND a.backend_type = 'pg_background'
          )
        FOR UPDATE OF j SKIP LOCKED
    ) LOOP
        UPDATE maint.vacuum_full_tasks 
        SET status = 'ABORTED_ORPHAN', ended_at = clock_timestamp(), error_log = 'Orchestrator process died or was superseded.' 
        WHERE job_id = v_orphaned_job.job_id AND status IN ('PENDING', 'RUNNING');

        UPDATE maint.jobs 
        SET status = 'ABORTED_ORPHAN', ended_at = clock_timestamp(),
            tables_processed = (SELECT COUNT(*) FROM maint.vacuum_full_tasks WHERE job_id = v_orphaned_job.job_id AND status = 'SUCCESS') 
        WHERE job_id = v_orphaned_job.job_id;

        v_healed_count := v_healed_count + 1;
        IF p_verbose THEN RAISE NOTICE '[SELF-HEALING] Job % detectado como huérfano. Estado actualizado a ABORTED_ORPHAN.', v_orphaned_job.job_id; END IF;
    END LOOP;

    IF v_healed_count > 0 THEN RAISE NOTICE '[SELF-HEALING] Se auto-sanaron y cerraron % trabajo(s) huérfano(s) en maint.jobs.', v_healed_count; END IF;
    COMMIT;

    -- 2. Triage
    IF v_profile_upper = 'SMART' THEN
        IF p_verbose THEN RAISE INFO '[RADAR] Ejecutando sp_pgstattuple síncronamente para refrescar telemetría...'; END IF;
        CALL maint.sp_pgstattuple(
            p_scope                => p_scope,
            p_bloat_pct_threshold  => p_bloat_pct_threshold,
            p_bloat_mb_threshold   => p_bloat_mb_threshold,
            p_threshold_operator  => p_threshold_operator,
            p_min_table_mb         => p_min_table_mb,
            p_enable_deep_scan     => p_enable_deep_scan,
            p_verbose              => p_verbose
        );
    END IF;

    IF p_verbose THEN
        RAISE INFO '=========================================================';
        RAISE INFO '[DBA SQUAD] INICIANDO CIRUGIA MAYOR (VACUUM FULL V3.4.9 - EXT: %)', COALESCE(v_ext_version, 'v1.x');
        RAISE INFO 'ALCANCE: % | MODO: % | HILOS: % | CUTOFF: % | FORCE_MB: %', 
                   p_scope, v_profile_upper, p_parallel_workers, COALESCE(p_cutoff_time::TEXT, 'SIN LIMITE'), COALESCE(p_force_bloat_mb::TEXT, 'DESACTIVADO');
        RAISE INFO '=========================================================';
    END IF;

    v_execution_params := jsonb_build_object(
        'scope', p_scope, 
        'profile', v_profile_upper, 
        'parallel_workers', p_parallel_workers, 
        'bloat_pct_threshold', p_bloat_pct_threshold, 
        'bloat_mb_threshold', p_bloat_mb_threshold, 
        'bloat_kb_threshold_calc', v_bloat_kb_threshold, 
        'threshold_operator', v_op_upper, 
        'sustained_days', p_sustained_days, 
        'force_bloat_mb', p_force_bloat_mb, 
        'force_bloat_kb_calc', v_force_bloat_kb, 
        'enable_deep_scan', p_enable_deep_scan, 
        'cutoff_time', p_cutoff_time, 
        'keep_history', p_keep_history,
        'pg_background_version', COALESCE(v_ext_version, '1.x')
    );

    INSERT INTO maint.jobs (job_type, maintenance_action, orchestrator_pid, execution_params, status)
    VALUES (p_scope || '_' || v_profile_upper, 'VACUUM_FULL', pg_backend_pid(), v_execution_params, 'RUNNING') 
    RETURNING job_id INTO v_job_id;
    COMMIT;

    -- 3. Poblar Cola
    FOR r_table IN (
        SELECT t.schema_name, t.table_name, t.total_bloat_kb, t.total_bloat_pct
        FROM maint.pgstattuple t
        LEFT JOIN maint.filters mf ON mf.schema_name = t.schema_name AND mf.table_name = t.table_name AND mf.maintenance_action IN ('ALL', 'VACUUM_FULL')
        WHERE t.evaluation_date = CURRENT_DATE
          AND t.schema_name <> 'maint' -- [ESCUDO ACTIVO]: El orquestador JAMÁS encola sus propias tablas para cirugía mayor.
          AND COALESCE(mf.is_ignored, FALSE) = FALSE
          AND (
              (p_scope = 'CUSTOM_LIST' AND mf.force_maintenance = TRUE) OR
              (p_scope = 'ALL_USER' AND t.schema_name NOT IN ('pg_catalog', 'information_schema')) OR
              (p_scope = 'ALL_SYSTEM_USER') OR
              (p_scope = 'ALL_SYSTEM' AND t.schema_name IN ('pg_catalog', 'information_schema'))
          )
    ) LOOP
        IF v_profile_upper = 'FORCE_SURGERY' THEN
            INSERT INTO maint.vacuum_full_tasks (job_id, schema_name, table_name, bloat_pct_evaluado, bloat_kb_evaluado, sustained_days_met, status) 
            VALUES (v_job_id, r_table.schema_name, r_table.table_name, r_table.total_bloat_pct, r_table.total_bloat_kb, 0, 'PENDING');
            v_total_tasks := v_total_tasks + 1;
        ELSE
            v_force_bypass := (v_force_bloat_kb IS NOT NULL AND r_table.total_bloat_kb >= v_force_bloat_kb);

            IF v_force_bypass THEN
                INSERT INTO maint.vacuum_full_tasks (job_id, schema_name, table_name, bloat_pct_evaluado, bloat_kb_evaluado, sustained_days_met, status) 
                VALUES (v_job_id, r_table.schema_name, r_table.table_name, r_table.total_bloat_pct, r_table.total_bloat_kb, 0, 'PENDING');
                v_total_tasks := v_total_tasks + 1;
            ELSIF (
                (v_op_upper = 'AND' AND r_table.total_bloat_pct >= p_bloat_pct_threshold AND r_table.total_bloat_kb >= v_bloat_kb_threshold) OR
                (v_op_upper = 'OR'  AND (r_table.total_bloat_pct >= p_bloat_pct_threshold OR r_table.total_bloat_kb >= v_bloat_kb_threshold))
            ) THEN
                SELECT COUNT(*), COALESCE(SUM(CASE WHEN requiere_vf THEN 1 ELSE 0 END), 0) 
                INTO v_hist_total, v_hist_true 
                FROM (
                    SELECT requiere_vf FROM maint.pgstattuple 
                    WHERE schema_name = r_table.schema_name AND table_name = r_table.table_name 
                    ORDER BY evaluation_date DESC LIMIT p_sustained_days
                ) sub;

                IF v_hist_total >= p_sustained_days AND v_hist_total = v_hist_true THEN
                    INSERT INTO maint.vacuum_full_tasks (job_id, schema_name, table_name, bloat_pct_evaluado, bloat_kb_evaluado, sustained_days_met, status) 
                    VALUES (v_job_id, r_table.schema_name, r_table.table_name, r_table.total_bloat_pct, r_table.total_bloat_kb, v_hist_total, 'PENDING');
                    v_total_tasks := v_total_tasks + 1;
                END IF;
            END IF;
        END IF;
    END LOOP;
    COMMIT;

    -- 4. Salida Temprana
    IF v_total_tasks = 0 THEN
        UPDATE maint.jobs SET status = 'COMPLETED', ended_at = clock_timestamp(), tables_processed = 0 WHERE job_id = v_job_id;
        COMMIT; 
        IF p_verbose THEN RAISE INFO '[✓] ORQUESTACION FINALIZADA. Job % | Procesadas: 0 / 0 (Sin tablas que requieran cirugia)', v_job_id; END IF; 
        RETURN;
    END IF;

    -- 5. Bucle de Despacho Asíncrono Polimórfico con Checksum Físico y Detach Defensivo
    LOOP
        FOR r_finished IN 
            SELECT task_id, child_pid, child_cookie, schema_name, table_name, old_relfilenode 
            FROM maint.vacuum_full_tasks 
            WHERE job_id = v_job_id AND status = 'RUNNING' 
              AND child_pid NOT IN (SELECT pid FROM pg_stat_activity WHERE backend_type = 'pg_background')
        LOOP
            BEGIN
                -- 1. Validación Lógica y Lectura de Resultado declarando la firma AS (result text)
                IF v_is_v2 THEN
                    EXECUTE 'SELECT 1 FROM public.pg_background_result($1, $2) AS (result text)' USING r_finished.child_pid, r_finished.child_cookie;
                ELSE
                    EXECUTE 'SELECT 1 FROM public.pg_background_result($1) AS (result text)' USING r_finished.child_pid;
                END IF;

                -- 2. Validación Física: Captura del Inodo del Archivo en Disco
                SELECT c.relfilenode INTO v_new_node 
                FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace 
                WHERE n.nspname = r_finished.schema_name AND c.relname = r_finished.table_name;

                -- 3. Checksum Físico
                IF v_new_node = r_finished.old_relfilenode THEN
                    UPDATE maint.vacuum_full_tasks 
                    SET status = 'FAILED_SILENT_ANOMALY', ended_at = clock_timestamp(), new_relfilenode = v_new_node, 
                        error_log = 'Engine returned success, but relfilenode did not change. Physical rewrite failed.' 
                    WHERE task_id = r_finished.task_id;
                    IF p_verbose THEN RAISE WARNING '    [ANOMALÍA] %.% terminó, pero relfilenode (%) NO CAMBIÓ.', r_finished.schema_name, r_finished.table_name, v_new_node; END IF;
                ELSE
                    UPDATE maint.vacuum_full_tasks 
                    SET status = 'SUCCESS', ended_at = clock_timestamp(), new_relfilenode = v_new_node 
                    WHERE task_id = r_finished.task_id;
                    v_success_count := v_success_count + 1; 
                    IF p_verbose THEN RAISE INFO '    [✓] CIRUGIA CONFIRMADA -> %.% (NODE: % -> %)', r_finished.schema_name, r_finished.table_name, r_finished.old_relfilenode, v_new_node; END IF;
                END IF;

            EXCEPTION WHEN OTHERS THEN
                UPDATE maint.vacuum_full_tasks SET status = 'FAILED', ended_at = clock_timestamp(), error_log = SQLERRM WHERE task_id = r_finished.task_id;
                IF p_verbose THEN RAISE WARNING '    [ERROR] FALLO CRITICO EN %.%: %', r_finished.schema_name, r_finished.table_name, SQLERRM; END IF;

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
            UPDATE maint.vacuum_full_tasks SET status = 'SKIPPED_TIME_LIMIT', error_log = 'Cutoff Time Reached' WHERE job_id = v_job_id AND status = 'PENDING'; 
            COMMIT;
        END IF;

        SELECT COUNT(*) INTO v_active_workers FROM maint.vacuum_full_tasks WHERE job_id = v_job_id AND status = 'RUNNING';
        SELECT COUNT(*) INTO v_pending_tasks FROM maint.vacuum_full_tasks WHERE job_id = v_job_id AND status = 'PENDING';
        
        IF v_active_workers = 0 AND v_pending_tasks = 0 THEN EXIT; END IF;

        -- D. DESPACHADOR ENRIQUECIDO POLIMÓRFICO
        WHILE v_active_workers < p_parallel_workers AND v_pending_tasks > 0 LOOP
            IF p_cutoff_time IS NOT NULL AND LOCALTIME >= p_cutoff_time THEN EXIT; END IF;

            SELECT task_id, schema_name, table_name, bloat_kb_evaluado, sustained_days_met 
            INTO v_task_id, v_schema, v_table, v_bloat_kb_eval, v_days_met 
            FROM maint.vacuum_full_tasks WHERE job_id = v_job_id AND status = 'PENDING' ORDER BY task_id ASC LIMIT 1;
            
            IF v_task_id IS NOT NULL THEN
                -- Captura del relfilenode actual en el milisegundo previo al lanzamiento
                SELECT c.relfilenode INTO v_old_node 
                FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace 
                WHERE n.nspname = v_schema AND c.relname = v_table;

                UPDATE maint.vacuum_full_tasks 
                SET status = 'RUNNING', started_at = clock_timestamp(), old_relfilenode = v_old_node 
                WHERE task_id = v_task_id; 
                COMMIT;

                -- [LANZAMIENTO DINÁMICO POLIMÓRFICO]: Extracción limpia directamente en la cláusula INTO
                IF v_is_v2 THEN
                    EXECUTE 'SELECT pid, cookie FROM public.pg_background_launch($1)' 
                    INTO v_child_pid, v_child_cookie 
                    USING format('VACUUM FULL %I.%I;', v_schema, v_table);
                ELSE
                    EXECUTE 'SELECT public.pg_background_launch($1)' 
                    INTO v_child_pid 
                    USING format('VACUUM FULL %I.%I;', v_schema, v_table);
                    
                    v_child_cookie := NULL;
                END IF;

                UPDATE maint.vacuum_full_tasks 
                SET child_pid = v_child_pid, child_cookie = v_child_cookie 
                WHERE task_id = v_task_id; 
                COMMIT;

                IF p_verbose THEN 
                    RAISE INFO '    [>] LANZANDO [VACUUM FULL] PID % -> %.% (OLD NODE: %) | Bloat: % KB | Dias: %', v_child_pid, v_schema, v_table, v_old_node, v_bloat_kb_eval, v_days_met; 
                END IF;
                v_active_workers := v_active_workers + 1; v_pending_tasks := v_pending_tasks - 1;
            END IF;
        END LOOP;
        PERFORM pg_sleep(2);
    END LOOP;

    -- [BARRERA DE CIERRE FINAL]: Purga defensiva en v2.0 si estuviera disponible
    IF v_is_v2 THEN
        BEGIN
            EXECUTE 'SELECT public.pg_background_detach_all()';
        EXCEPTION WHEN OTHERS THEN
            NULL;
        END;
    END IF;

    -- 6. Cierre normal de Job
    IF EXISTS (SELECT 1 FROM maint.vacuum_full_tasks WHERE job_id = v_job_id AND status = 'SKIPPED_TIME_LIMIT') THEN
        UPDATE maint.jobs SET status = 'COMPLETED_WITH_CUTOFF', ended_at = clock_timestamp(), tables_processed = v_success_count WHERE job_id = v_job_id;
    ELSE
        UPDATE maint.jobs SET status = 'COMPLETED', ended_at = clock_timestamp(), tables_processed = v_success_count WHERE job_id = v_job_id;
    END IF;

    IF NOT p_keep_history THEN DELETE FROM maint.vacuum_full_tasks WHERE job_id = v_job_id; END IF;
    COMMIT;

    IF p_verbose THEN 
        RAISE INFO '---------------------------------------------------------';
        RAISE INFO '[✓] ORQUESTACION QUIRURGICA FINALIZADA. Job % | Procesadas: % / %', v_job_id, v_success_count, v_total_tasks;
        RAISE INFO 'Tiempo Total: %', (clock_timestamp() - v_start_time);
        RAISE INFO '=========================================================';
    END IF;
END;
$$;

REVOKE EXECUTE ON PROCEDURE maint.sp_orchestrate_vacuum_full FROM PUBLIC;

COMMIT;
