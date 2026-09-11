/* =========================================================================================
   ██████╗ ██████╗  █████╗     ███████╗ ██████╗ ██╗   ██╗ █████╗ ██████╗ 
   ██╔══██╗██╔══██╗██╔══██╗    ██╔════╝██╔═══██╗██║   ██║██╔══██╗██╔══██╗
   ██║  ██║██████╔╝███████║    ███████╗██║   ██║██║   ██║███████║██║  ██║
   ██║  ██║██╔══██╗██╔══██║    ╚════██║██║▄▄ ██║██║   ██║██╔══██║██║  ██║
   ██████╔╝██████╔╝██║  ██║    ███████║╚██████╔╝╚██████╔╝██║  ██║██████╔╝
   ╚═════╝ ╚═════╝ ╚═╝  ╚═╝    ╚══════╝ ╚══▀▀═╝  ╚═════╝ ╚═╝  ╚═╝╚═════╝ 
                               VANGUARD BLACK-OPS
                               
   MÓDULO: Suite Completa de Mantenimiento Asíncrono (REINDEX CONCURRENTLY)
   Compatibilidad : Universal (<= pg_background 1.4 y >= 2.0 / Cloud SQL & On-Premise)
   VERSIÓN: V3.6.0 (Grado Diamante - Dynamic Parameter Interception, Multi-DB Disk Shield, Triada AND/OR & Checksum)
   ARQUITECTURA: Multi-hilo, Resiliente, Forense, Libre de Subtransacciones.
========================================================================================= */
BEGIN;

CREATE SCHEMA IF NOT EXISTS maint;

-- =========================================================================================
-- [FASE 1]: EXTENSIONES 
-- =========================================================================================
CREATE EXTENSION IF NOT EXISTS pgstattuple;
CREATE EXTENSION IF NOT EXISTS pg_background;

-- =========================================================================================
-- [NUEVO V3.6.0] 0. TABLA DE CONFIGURACIÓN DINÁMICA DE INSTANCIA
-- =========================================================================================
CREATE TABLE IF NOT EXISTS maint.config (
    config_id SERIAL PRIMARY KEY,
    name VARCHAR(255) NOT NULL UNIQUE,
    setting VARCHAR(255) NOT NULL,
    unit VARCHAR(50) NULL,
    setting_desc TEXT NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

-- Inserción idempotente de parámetros operativos, ámbito Multi-DB e interruptores de seguridad
INSERT INTO maint.config (name, setting, unit, setting_desc) 
VALUES 
  ('max_parallel_reindex_workers', '4', 'workers', 'Límite máximo dinámico de workers concurrentes para REINDEX'),
  ('disk_total_size_gb', '-1', 'GB', 'Capacidad total de disco. El valor -1 desactiva la pre-validación de espacio'),
  ('disk_safety_margin_gb', '30', 'GB', 'Margen de seguridad intocable en disco (Techo de Acero)'),
  ('wal_amplification_factor', '2.0', 'ratio', 'Factor de amplificación WAL (2.0 GCP/On-Premise, 1.0 Aurora/Decoupled)'),
  ('target_databases_for_disk_check', '-1', 'text', 'Bases de datos a sumar para espacio: -1 (Todas), current_database (Solo actual), o lista separada por comas (db1,db2)')
ON CONFLICT (name) DO NOTHING;

COMMENT ON TABLE maint.config IS 'Configuración maestra de la instancia para límites de I/O, Workers, Ámbito Multi-DB y Seguridad en Disco.';

-- =========================================================================================
-- 1. TABLA PADRE: Orquestación Global de Trabajos (Maestra Unificada)
-- =========================================================================================
CREATE TABLE IF NOT EXISTS maint.jobs (
    job_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    job_type VARCHAR(50) NOT NULL,              -- Ej. 'SMART_USER_CONCURRENT', 'CUSTOM_LIST_FORCE_SURGERY'
    maintenance_action VARCHAR(20) NOT NULL,    -- 'ANALYZE', 'VACUUM', 'VACUUM_FULL', 'REINDEX'
    orchestrator_pid INT NOT NULL,              -- PID del proceso principal (Padre) para Self-Healing
    execution_params JSONB NOT NULL,             -- Fotografía inmutable de los parámetros
    status VARCHAR(30) NOT NULL DEFAULT 'RUNNING',-- 'RUNNING', 'COMPLETED', 'COMPLETED_WITH_CUTOFF', 'ABORTED_ORPHAN'
    tables_processed INT DEFAULT 0,             -- Cantidad real de índices intervenidos exitosamente
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
-- 3. TABLA DE TELEMETRÍA PREDICTIVA (Radar de Índices B-Tree V3.4.1)
-- =========================================================================================
DROP TABLE IF EXISTS maint.pgstatindex CASCADE;
CREATE TABLE IF NOT EXISTS maint.pgstatindex (
    triage_id BIGSERIAL PRIMARY KEY,
    evaluation_date DATE NOT NULL DEFAULT current_date,
    schema_name VARCHAR(255) NOT NULL,
    table_name VARCHAR(255) NOT NULL,
    index_name VARCHAR(255) NOT NULL,
    
    index_size_kb NUMERIC(20,2) NOT NULL DEFAULT 0.00,
    leaf_fragmentation_pct NUMERIC(12,2) NOT NULL DEFAULT 0.00,
    avg_leaf_density_pct NUMERIC(12,2) NOT NULL DEFAULT 0.00,
    empty_pages_pct NUMERIC(12,2) NOT NULL DEFAULT 0.00,
    
    total_bloat_kb NUMERIC(20,2) NOT NULL DEFAULT 0.00,
    total_bloat_pct NUMERIC(12,2) NOT NULL DEFAULT 0.00, -- Porcentaje de espacio libre recuperable
    is_invalid BOOLEAN NOT NULL DEFAULT FALSE,
    requieres_reindex BOOLEAN NOT NULL DEFAULT FALSE,
    
    CONSTRAINT uq_pgstatindex_date_schema_index UNIQUE (evaluation_date, schema_name, index_name)
);

COMMENT ON TABLE maint.pgstatindex IS 'Radar periódico de fragmentación B-Tree y estimación de bloat físico en índices.';
COMMENT ON COLUMN maint.pgstatindex.is_invalid IS 'Bandera roja (Zombi): Índices que fallaron al construirse y necesitan reconstrucción obligatoria.';
COMMENT ON COLUMN maint.pgstatindex.total_bloat_kb IS 'Cálculo estimado del espacio desperdiciado en disco derivado de la densidad foliar.';
COMMENT ON COLUMN maint.pgstatindex.total_bloat_pct IS 'Porcentaje de espacio desperdiciado (100 - avg_leaf_density_pct).';

-- =========================================================================================
-- 4. TABLA DE COLA TRANSACCIONAL (Módulo Reindex V3.4.2 - Inyección Anti-PID Reuse v2.0)
-- =========================================================================================
DROP TABLE IF EXISTS maint.reindex_tasks CASCADE;
CREATE TABLE IF NOT EXISTS maint.reindex_tasks (
    task_id BIGSERIAL PRIMARY KEY,
    job_id BIGINT NOT NULL REFERENCES maint.jobs(job_id) ON DELETE CASCADE,
    schema_name VARCHAR(255) NOT NULL,
    table_name VARCHAR(255) NOT NULL,
    index_name VARCHAR(255) NOT NULL,
    
    frag_pct NUMERIC(5,2) NOT NULL,
    bloat_pct NUMERIC(5,2) NOT NULL, -- Auditoría forense del % de bloat al encolar
    bloat_kb NUMERIC(14,2) NOT NULL,
    is_invalid BOOLEAN NOT NULL DEFAULT FALSE,
    
    old_relfilenode BIGINT,               -- Checksum Físico de validación (Antes)
    new_relfilenode BIGINT,               -- Checksum Físico de validación (Después)
    status VARCHAR(50) DEFAULT 'PENDING',
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
        WHERE table_schema = 'maint' AND table_name = 'reindex_tasks' AND column_name = 'child_cookie'
    ) THEN 
        ALTER TABLE maint.reindex_tasks ADD COLUMN child_cookie BIGINT; 
    END IF; 
END $$;

COMMENT ON TABLE maint.reindex_tasks IS 'Cola transaccional individual para la orquestación de REINDEX CONCURRENTLY.';

CREATE INDEX IF NOT EXISTS idx_reindex_tasks_job_status_id 
ON maint.reindex_tasks (job_id, status, task_id);

-- =========================================================================================
-- 5. PROCEDIMIENTO: RADAR DE ÍNDICES (maint.sp_pgstatindex V3.6.0 - TRIADA DE CONTROL)
-- =========================================================================================
CREATE OR REPLACE PROCEDURE maint.sp_pgstatindex(
    p_scope VARCHAR DEFAULT 'SMART_USER',
    p_frag_pct_threshold NUMERIC DEFAULT 40.00,
    p_bloat_pct_threshold NUMERIC DEFAULT 20.00, -- Umbral de % de Bloat (Espacio Libre)
    p_bloat_mb_threshold NUMERIC DEFAULT 1024.00,
    p_threshold_operator VARCHAR DEFAULT 'OR',  
    p_min_index_mb NUMERIC DEFAULT 10.00,
    p_force_frag_pct NUMERIC DEFAULT NULL,      -- Bypass por daño estructural
    p_force_bloat_mb NUMERIC DEFAULT NULL,      -- Bypass por tamaño masivo
    p_verbose BOOLEAN DEFAULT FALSE
)
LANGUAGE plpgsql AS $$
DECLARE
    r_idx RECORD; r_stat RECORD;
    v_today DATE := current_date; 
    v_processed INT := 0; v_sniped INT := 0;
    v_threshold_kb NUMERIC(14,2) := (p_bloat_mb_threshold * 1024.0);
    v_force_bloat_kb NUMERIC(14,2) := CASE WHEN p_force_bloat_mb IS NOT NULL THEN (p_force_bloat_mb * 1024.0) ELSE NULL END;
    v_requieres_reindex BOOLEAN := FALSE;
    v_op_upper VARCHAR := UPPER(p_threshold_operator);
    
    v_leaf_frag NUMERIC(5,2); v_avg_density NUMERIC(5,2); v_empty_pages NUMERIC(5,2);
    v_size_kb NUMERIC(14,2); v_est_bloat_kb NUMERIC(14,2); v_total_bloat_pct NUMERIC(5,2);
BEGIN
    PERFORM pg_catalog.set_config('client_min_messages', 'notice', false);
    PERFORM pg_catalog.set_config('search_path', 'maint, public, pg_temp', true);

    IF v_op_upper NOT IN ('AND', 'OR') THEN RAISE EXCEPTION 'CRITICAL: p_threshold_operator solo admite ''AND'' u ''OR''.'; END IF;

    IF p_verbose THEN
        RAISE INFO '=========================================================';
        RAISE INFO '[DBA SQUAD] RADAR DE ÍNDICES V3.6.0 (LOGIC: % | FRAG: %%% | BLOAT: %%% / % MB | FORCE_MB: %)', 
                   v_op_upper, p_frag_pct_threshold, p_bloat_pct_threshold, p_bloat_mb_threshold, COALESCE(p_force_bloat_mb::TEXT, 'OFF');
        RAISE INFO '=========================================================';
    END IF;

    FOR r_idx IN (
        SELECT i.indexrelid AS index_oid, n.nspname AS schema_name, t.relname AS table_name, c.relname AS index_name,
               pg_relation_size(i.indexrelid) AS size_bytes, NOT i.indisvalid AS is_invalid
        FROM pg_index i
        JOIN pg_class c ON i.indexrelid = c.oid JOIN pg_class t ON i.indrelid = t.oid JOIN pg_namespace n ON c.relnamespace = n.oid
        LEFT JOIN maint.filters mf ON mf.schema_name = n.nspname AND mf.table_name = t.relname AND mf.maintenance_action IN ('ALL', 'REINDEX')
        WHERE c.relkind = 'i' AND c.relam = (SELECT oid FROM pg_am WHERE amname = 'btree')
          AND n.nspname <> 'pg_toast' AND n.nspname <> 'maint' -- ESCUDO ACTIVO
          AND pg_relation_size(i.indexrelid) >= (p_min_index_mb * 1024 * 1024)
          AND ((p_scope = 'CUSTOM_LIST' AND mf.force_maintenance = TRUE) OR (p_scope = 'SMART_USER' AND n.nspname NOT IN ('pg_catalog', 'information_schema')) OR (p_scope = 'SMART_SYSTEM_USER') OR (p_scope = 'SMART_SYSTEM' AND n.nspname IN ('pg_catalog', 'information_schema')))
    ) LOOP
        BEGIN
            v_size_kb := ROUND((r_idx.size_bytes / 1024.0)::numeric, 2);
            v_processed := v_processed + 1;

            -- Evaluador Zombi
            IF r_idx.is_invalid THEN
                v_leaf_frag := 100.00; v_avg_density := 0.00; v_empty_pages := 100.00; v_est_bloat_kb := v_size_kb; v_total_bloat_pct := 100.00;
                v_requieres_reindex := TRUE; 
            ELSE
                -- Evaluador Físico B-Tree (pgstatindex)
                SELECT * INTO r_stat FROM pgstatindex(r_idx.index_oid);
                v_leaf_frag   := CASE WHEN r_stat.leaf_fragmentation = 'NaN'::numeric THEN 0.00 ELSE COALESCE(r_stat.leaf_fragmentation, 0.00) END;
                v_avg_density := CASE WHEN r_stat.avg_leaf_density = 'NaN'::numeric THEN 0.00 ELSE COALESCE(r_stat.avg_leaf_density, 0.00) END;
                v_empty_pages := CASE WHEN r_stat.empty_pages = 'NaN'::numeric THEN 0.00 ELSE COALESCE(r_stat.empty_pages, 0.00) END;
                
                v_total_bloat_pct := ROUND((100.00 - v_avg_density)::numeric, 2);
                v_est_bloat_kb := ROUND((v_size_kb * (v_total_bloat_pct / 100.0))::numeric, 2);

                -- EVALUACIÓN MATEMÁTICA RESTRUCTURADA (TRIADA V4.0.0 / V3.6.0)
                IF (p_force_frag_pct IS NOT NULL AND v_leaf_frag >= p_force_frag_pct) OR (v_force_bloat_kb IS NOT NULL AND v_est_bloat_kb >= v_force_bloat_kb) THEN
                    -- Vía 1: Bypass de Fuerza Bruta (Garantiza el rescate de índices destruidos)
                    v_requieres_reindex := TRUE;
                ELSIF v_op_upper = 'AND' THEN
                    -- Vía 2: Regla AND Estricta que vincula las 3 variables simultáneamente
                    v_requieres_reindex := (
                        v_leaf_frag >= p_frag_pct_threshold 
                        AND v_total_bloat_pct >= p_bloat_pct_threshold 
                        AND v_est_bloat_kb >= v_threshold_kb
                    );
                ELSE
                    -- Vía 3: Regla OR Flexible
                    v_requieres_reindex := (
                        v_leaf_frag >= p_frag_pct_threshold 
                        OR v_total_bloat_pct >= p_bloat_pct_threshold 
                        OR v_est_bloat_kb >= v_threshold_kb
                    );
                END IF;
            END IF;

            INSERT INTO maint.pgstatindex (
                evaluation_date, schema_name, table_name, index_name, index_size_kb, leaf_fragmentation_pct, avg_leaf_density_pct, empty_pages_pct, total_bloat_kb, total_bloat_pct, is_invalid, requieres_reindex
            ) VALUES (
                v_today, r_idx.schema_name, r_idx.table_name, r_idx.index_name, v_size_kb, v_leaf_frag, v_avg_density, v_empty_pages, v_est_bloat_kb, v_total_bloat_pct, r_idx.is_invalid, v_requieres_reindex
            ) ON CONFLICT (evaluation_date, schema_name, index_name) DO UPDATE SET
                index_size_kb = EXCLUDED.index_size_kb, leaf_fragmentation_pct = EXCLUDED.leaf_fragmentation_pct, avg_leaf_density_pct = EXCLUDED.avg_leaf_density_pct, empty_pages_pct = EXCLUDED.empty_pages_pct, total_bloat_kb = EXCLUDED.total_bloat_kb, total_bloat_pct = EXCLUDED.total_bloat_pct, is_invalid = EXCLUDED.is_invalid, requieres_reindex = EXCLUDED.requieres_reindex;
            
            IF v_requieres_reindex THEN v_sniped := v_sniped + 1; END IF;

        EXCEPTION WHEN OTHERS THEN
            IF p_verbose THEN RAISE WARNING 'Error analizando %.%: %', r_idx.schema_name, r_idx.index_name, SQLERRM; END IF;
        END;
        COMMIT; 
    END LOOP;

    IF p_verbose THEN RAISE INFO '[✓] TRIAGE FINALIZADO. Evaluados: %, requieresn REINDEX: %', v_processed, v_sniped; END IF;
END;
$$;

REVOKE EXECUTE ON PROCEDURE maint.sp_pgstatindex FROM PUBLIC;

-- =========================================================================================
-- 6. ORQUESTADOR QUIRÚRGICO: maint.sp_orchestrate_reindex V3.6.0 (Multi-DB Universal)
-- =========================================================================================
CREATE OR REPLACE PROCEDURE maint.sp_orchestrate_reindex(
    p_scope VARCHAR DEFAULT 'SMART_USER',
    p_profile VARCHAR DEFAULT 'CONCURRENT',     
    p_parallel_workers INT DEFAULT 2,           -- Verificado contra maint.config dinámicamente
    p_cutoff_time TIME DEFAULT NULL,
    p_verbose BOOLEAN DEFAULT FALSE,
    p_frag_pct_threshold NUMERIC DEFAULT 40.00,
    p_bloat_pct_threshold NUMERIC DEFAULT 20.00,
    p_bloat_mb_threshold NUMERIC DEFAULT 1024.00,
    p_threshold_operator VARCHAR DEFAULT 'OR',
    p_min_index_mb NUMERIC DEFAULT 10.00,
    p_force_frag_pct NUMERIC DEFAULT NULL,      
    p_force_bloat_mb NUMERIC DEFAULT NULL,      
    p_rebuild_invalid BOOLEAN DEFAULT TRUE,     
    p_keep_history BOOLEAN DEFAULT TRUE
)
LANGUAGE plpgsql AS $$
DECLARE
    v_job_id BIGINT; v_task_id BIGINT; v_schema TEXT; v_table TEXT; v_index TEXT; v_child_pid INT; v_child_cookie BIGINT;
    v_bloat_kb_eval NUMERIC(14,2); v_frag_pct_eval NUMERIC(5,2); v_bloat_pct_eval NUMERIC(5,2); v_raw_sql TEXT;
    r_idx RECORD; r_finished RECORD;
    v_active_workers INT := 0; v_pending_tasks INT := 0; v_total_tasks INT := 0; v_success_count INT := 0;
    v_healed_count INT := 0;
    v_profile_upper VARCHAR := UPPER(p_profile); v_op_upper VARCHAR := UPPER(p_threshold_operator);
    v_start_time TIMESTAMPTZ := clock_timestamp(); v_execution_params JSONB; v_orphaned_job RECORD;
    v_old_node BIGINT; v_new_node BIGINT;
    v_bloat_kb_threshold NUMERIC(14,2) := (p_bloat_mb_threshold * 1024.0);
    v_force_bloat_kb NUMERIC(14,2) := CASE WHEN p_force_bloat_mb IS NOT NULL THEN (p_force_bloat_mb * 1024.0) ELSE NULL END;
    v_force_bypass BOOLEAN := FALSE;
    
    -- Variables para el Interceptor de Sesión
    v_param RECORD;
    v_changed_params TEXT[] := '{}';

    -- [INYECCIÓN POLIMÓRFICA]: Control dinámico de versión sin pg_background_handle
    v_is_v2 BOOLEAN := FALSE;
    v_ext_version TEXT;

    -- [NUEVO V3.6.0]: Variables Dinámicas, Ámbito Multi-DB y Pre-validación de Espacio en Disco para REINDEX
    v_max_allowed_workers INT;
    v_disk_total_size_gb NUMERIC;
    v_disk_safety_margin_gb NUMERIC;
    v_wal_amplification_factor NUMERIC;
    v_target_dbs_setting TEXT;
    v_target_dbs_array TEXT[];
    v_formatted_dbs_log TEXT;
    v_index_oid OID;
    v_max_indexes_gb NUMERIC;
    v_peak_required_gb NUMERIC;
    v_db_size_gb NUMERIC;
    v_free_disk_gb NUMERIC;
BEGIN
    PERFORM pg_catalog.set_config('client_min_messages', 'notice', false);
    PERFORM pg_catalog.set_config('search_path', 'maint, public, pg_temp', true);

    -- 0. Detección Dinámica de Versión en pg_extension
    SELECT extversion INTO v_ext_version FROM pg_extension WHERE extname = 'pg_background';
    IF v_ext_version IS NOT NULL AND SPLIT_PART(v_ext_version, '.', 1)::INT >= 2 THEN
        v_is_v2 := TRUE;
    END IF;

    -- 0.1 Lectura de Configuración de Instancia Multi-DB (V3.6.0)
    SELECT setting::INT INTO v_max_allowed_workers FROM maint.config WHERE name = 'max_parallel_reindex_workers';
    SELECT setting::NUMERIC INTO v_disk_total_size_gb FROM maint.config WHERE name = 'disk_total_size_gb';
    SELECT setting::NUMERIC INTO v_disk_safety_margin_gb FROM maint.config WHERE name = 'disk_safety_margin_gb';
    SELECT setting::NUMERIC INTO v_wal_amplification_factor FROM maint.config WHERE name = 'wal_amplification_factor';
    SELECT COALESCE(setting, '-1') INTO v_target_dbs_setting FROM maint.config WHERE name = 'target_databases_for_disk_check';

    -- =====================================================================
    -- 0. PRE-FLIGHT CHECK: INTERCEPCIÓN DINÁMICA DE RAM Y RECURSOS
    -- =====================================================================
    FOR v_param IN (
        SELECT name, setting 
        FROM pg_settings 
        WHERE name IN ('max_parallel_maintenance_workers', 'maintenance_work_mem')
          AND setting IS DISTINCT FROM reset_val
    ) LOOP
        EXECUTE format('ALTER ROLE %I SET %I = %L', current_user, v_param.name, v_param.setting);
        v_changed_params := array_append(v_changed_params, v_param.name);
    END LOOP;

    IF array_length(v_changed_params, 1) > 0 THEN
        COMMIT; -- Forzamos commit para que los workers (pg_background) lean la RAM asignada
    END IF;

    -- Validaciones Fail-Fast de Infraestructura
    IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_background') THEN 
        RAISE EXCEPTION 'CRITICAL [INFRAESTRUCTURA]: Extensión "pg_background" ausente.'; 
    END IF;

    IF (SELECT current_setting('max_worker_processes')::INT) < p_parallel_workers THEN 
        RAISE EXCEPTION 'CRITICAL [RECURSOS]: El parámetro max_worker_processes (%) del servidor es menor a los hilos solicitados (%).', 
                        current_setting('max_worker_processes'), p_parallel_workers; 
    END IF;

    -- [NUEVO V3.6.0]: Validación Dinámica de Paralelismo
    IF p_parallel_workers < 1 OR p_parallel_workers > v_max_allowed_workers THEN 
        RAISE EXCEPTION 'ALERTA SEGURIDAD I/O: Solicitados % hilos para REINDEX. El tope estricto configurado en maint.config es %.', p_parallel_workers, v_max_allowed_workers; 
    END IF;

    IF v_profile_upper NOT IN ('CONCURRENT', 'FORCE_SURGERY') THEN RAISE EXCEPTION 'CRITICAL: Perfil inválido.'; END IF;
    IF UPPER(p_scope) NOT IN ('SMART_USER', 'SMART_SYSTEM', 'SMART_SYSTEM_USER', 'CUSTOM_LIST') THEN RAISE EXCEPTION 'CRITICAL: Ámbito inválido.'; END IF;
    IF v_profile_upper = 'FORCE_SURGERY' AND UPPER(p_scope) <> 'CUSTOM_LIST' THEN RAISE EXCEPTION 'ALERTA ROJA: FORCE_SURGERY requieres CUSTOM_LIST.'; END IF;

    -- =====================================================================
    -- 1. SELF-HEALING Y RECONCILIACIÓN ESTRUCTURAL
    -- =====================================================================
    FOR v_orphaned_job IN (
        SELECT j.job_id FROM maint.jobs j WHERE j.status = 'RUNNING' AND j.maintenance_action = 'REINDEX'
          AND NOT EXISTS (SELECT 1 FROM pg_stat_activity a WHERE a.pid = j.orchestrator_pid AND a.pid != pg_backend_pid() AND a.state != 'idle')
          AND NOT EXISTS (SELECT 1 FROM maint.reindex_tasks t JOIN pg_stat_activity a ON a.pid = t.child_pid WHERE t.job_id = j.job_id AND t.status = 'RUNNING' AND a.backend_type = 'pg_background')
        FOR UPDATE OF j SKIP LOCKED
    ) LOOP
        UPDATE maint.reindex_tasks SET status = 'ABORTED_ORPHAN', ended_at = clock_timestamp(), error_log = 'Orchestrator process died.' WHERE job_id = v_orphaned_job.job_id AND status IN ('PENDING', 'RUNNING');
        UPDATE maint.jobs SET status = 'ABORTED_ORPHAN', ended_at = clock_timestamp(), tables_processed = (SELECT COUNT(*) FROM maint.reindex_tasks WHERE job_id = v_orphaned_job.job_id AND status = 'SUCCESS') WHERE job_id = v_orphaned_job.job_id;
        v_healed_count := v_healed_count + 1;
        IF p_verbose THEN RAISE NOTICE '[SELF-HEALING] Job % detectado como huérfano. Abortado.', v_orphaned_job.job_id; END IF;
    END LOOP;
    COMMIT;

    -- =====================================================================
    -- 2. TRIAGE SÍNCRONO DEL RADAR
    -- =====================================================================
    IF v_profile_upper = 'CONCURRENT' THEN
        IF p_verbose THEN RAISE INFO '[RADAR] Ejecutando sp_pgstatindex síncronamente...'; END IF;
        CALL maint.sp_pgstatindex(p_scope, p_frag_pct_threshold, p_bloat_pct_threshold, p_bloat_mb_threshold, p_threshold_operator, p_min_index_mb, p_force_frag_pct, p_force_bloat_mb, p_verbose);
    END IF;

    IF p_verbose THEN
        RAISE INFO '=========================================================';
        RAISE INFO '[DBA SQUAD] INICIANDO ORQUESTACIÓN REINDEX VANGUARD (V3.6.0 - EXT: %)', COALESCE(v_ext_version, 'v1.x');
        RAISE INFO 'ALCANCE: % | HILOS: % | CUTOFF: % | REBUILD ZOMBIS: %', p_scope, p_parallel_workers, COALESCE(p_cutoff_time::TEXT, 'SIN LIMITE'), p_rebuild_invalid;
        RAISE INFO 'PRE-VALIDACIÓN DISCO: % GB | MARGEN: % GB | WAL_FACTOR: % | TARGET_DBS: %', 
                   CASE WHEN v_disk_total_size_gb <= 0 THEN 'DESACTIVADO (-1)' ELSE v_disk_total_size_gb::TEXT END, 
                   v_disk_safety_margin_gb, v_wal_amplification_factor, v_target_dbs_setting;
        RAISE INFO '=========================================================';
    END IF;

    v_execution_params := jsonb_build_object(
        'scope', p_scope, 
        'profile', v_profile_upper, 
        'parallel_workers', p_parallel_workers, 
        'frag_pct_threshold', p_frag_pct_threshold, 
        'bloat_pct_threshold', p_bloat_pct_threshold, 
        'bloat_mb_threshold', p_bloat_mb_threshold, 
        'threshold_operator', v_op_upper, 
        'force_frag_pct', p_force_frag_pct, 
        'force_bloat_mb', p_force_bloat_mb, 
        'rebuild_invalid', p_rebuild_invalid, 
        'keep_history', p_keep_history, 
        'pg_background_version', COALESCE(v_ext_version, '1.x'),
        'disk_total_size_gb', v_disk_total_size_gb,
        'disk_safety_margin_gb', v_disk_safety_margin_gb,
        'wal_amplification_factor', v_wal_amplification_factor,
        'target_databases_for_disk_check', v_target_dbs_setting
    );

    INSERT INTO maint.jobs (job_type, maintenance_action, orchestrator_pid, execution_params, status)
    VALUES (p_scope || '_' || v_profile_upper, 'REINDEX', pg_backend_pid(), v_execution_params, 'RUNNING') RETURNING job_id INTO v_job_id;
    
    -- LIBERACIÓN CRÍTICA 1: Cierra el snapshot de la creación del Job
    COMMIT; 

    -- =====================================================================
    -- 3. POBLAR COLA SILENCIOSAMENTE (Con Escudo Maint y Triada V4.0.0)
    -- =====================================================================
    FOR r_idx IN (
        SELECT t.schema_name, t.table_name, t.index_name, t.total_bloat_kb, t.total_bloat_pct, t.leaf_fragmentation_pct, t.is_invalid
        FROM maint.pgstatindex t
        LEFT JOIN maint.filters mf ON mf.schema_name = t.schema_name AND mf.table_name = t.table_name AND mf.maintenance_action IN ('ALL', 'REINDEX')
        WHERE t.evaluation_date = CURRENT_DATE AND t.schema_name <> 'maint' AND COALESCE(mf.is_ignored, FALSE) = FALSE
          AND ((p_scope = 'CUSTOM_LIST' AND mf.force_maintenance = TRUE) OR (p_scope = 'SMART_USER' AND t.schema_name NOT IN ('pg_catalog', 'information_schema')) OR (p_scope = 'SMART_SYSTEM_USER') OR (p_scope = 'SMART_SYSTEM' AND t.schema_name IN ('pg_catalog', 'information_schema')))
    ) LOOP

        IF v_profile_upper = 'FORCE_SURGERY' THEN
            INSERT INTO maint.reindex_tasks (job_id, schema_name, table_name, index_name, frag_pct, bloat_pct, bloat_kb, is_invalid, status) 
            VALUES (v_job_id, r_idx.schema_name, r_idx.table_name, r_idx.index_name, LEAST(r_idx.leaf_fragmentation_pct, 999999999.99), LEAST(r_idx.total_bloat_pct, 999999999.99), r_idx.total_bloat_kb, r_idx.is_invalid, 'PENDING');
            v_total_tasks := v_total_tasks + 1;
        ELSE
            v_force_bypass := ((p_force_frag_pct IS NOT NULL AND r_idx.leaf_fragmentation_pct >= p_force_frag_pct) OR (v_force_bloat_kb IS NOT NULL AND r_idx.total_bloat_kb >= v_force_bloat_kb));

            -- EVALUACIÓN MATEMÁTICA EN POBLADO DE COLA (SIMETRÍA TOTAL CON TRIADA V4.0.0)
            IF (r_idx.is_invalid AND p_rebuild_invalid) OR v_force_bypass OR (
                (v_op_upper = 'AND' AND r_idx.leaf_fragmentation_pct >= p_frag_pct_threshold AND r_idx.total_bloat_pct >= p_bloat_pct_threshold AND r_idx.total_bloat_kb >= v_bloat_kb_threshold) OR
                (v_op_upper = 'OR'  AND (r_idx.leaf_fragmentation_pct >= p_frag_pct_threshold OR r_idx.total_bloat_pct >= p_bloat_pct_threshold OR r_idx.total_bloat_kb >= v_bloat_kb_threshold))
            ) THEN
                INSERT INTO maint.reindex_tasks (job_id, schema_name, table_name, index_name, frag_pct, bloat_pct, bloat_kb, is_invalid, status) 
                VALUES (v_job_id, r_idx.schema_name, r_idx.table_name, r_idx.index_name, LEAST(r_idx.leaf_fragmentation_pct, 999999999.99), LEAST(r_idx.total_bloat_pct, 999999999.99), r_idx.total_bloat_kb, r_idx.is_invalid, 'PENDING');
                v_total_tasks := v_total_tasks + 1;
            END IF;
        END IF;

    END LOOP;
    
    -- LIBERACIÓN CRÍTICA 2: Cierra el snapshot del encolado
    COMMIT; 

    -- SALIDA TEMPRANA
    IF v_total_tasks = 0 THEN
        UPDATE maint.jobs SET status = 'COMPLETED', ended_at = clock_timestamp(), tables_processed = 0 WHERE job_id = v_job_id;
        IF array_length(v_changed_params, 1) > 0 THEN FOR i IN 1 .. array_length(v_changed_params, 1) LOOP EXECUTE format('ALTER ROLE %I RESET %I', current_user, v_changed_params[i]); END LOOP; END IF;
        COMMIT; IF p_verbose THEN RAISE INFO '[✓] ORQUESTACION FINALIZADA. Job % | Procesados: 0 / 0', v_job_id; END IF; RETURN;
    END IF;

    -- =====================================================================
    -- 5. BUCLE DE DESPACHO ASÍNCRONO POLIMÓRFICO Y CHECKSUM (Libre de Snapshots)
    -- =====================================================================
    LOOP
        FOR r_finished IN 
            SELECT task_id, child_pid, child_cookie, schema_name, index_name, old_relfilenode 
            FROM maint.reindex_tasks 
            WHERE job_id = v_job_id AND status = 'RUNNING' 
              AND child_pid NOT IN (SELECT pid FROM pg_stat_activity WHERE backend_type = 'pg_background')
        LOOP
            BEGIN
                -- Consumo de Resultado (Realiza Auto-Detach Nativo en Flujo de Éxito declarando la firma AS (result text))
                IF v_is_v2 THEN
                    EXECUTE 'SELECT 1 FROM public.pg_background_result($1, $2) AS (result text)' USING r_finished.child_pid, r_finished.child_cookie;
                ELSE
                    EXECUTE 'SELECT 1 FROM public.pg_background_result($1) AS (result text)' USING r_finished.child_pid;
                END IF;

                SELECT c.relfilenode INTO v_new_node 
                FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace 
                WHERE n.nspname = r_finished.schema_name AND c.relname = r_finished.index_name;
                
                IF v_new_node = r_finished.old_relfilenode THEN
                    UPDATE maint.reindex_tasks SET status = 'FAILED_SILENT_ANOMALY', ended_at = clock_timestamp(), new_relfilenode = v_new_node, error_log = 'Engine returned success, but relfilenode did not change.' WHERE task_id = r_finished.task_id;
                    IF p_verbose THEN RAISE WARNING '    [ANOMALY] %.% terminó, pero relfilenode (%) NO CAMBIÓ.', r_finished.schema_name, r_finished.index_name, v_new_node; END IF;
                ELSE
                    UPDATE maint.reindex_tasks SET status = 'SUCCESS', ended_at = clock_timestamp(), new_relfilenode = v_new_node WHERE task_id = r_finished.task_id;
                    v_success_count := v_success_count + 1; 
                    IF p_verbose THEN RAISE INFO '    [✓] CIRUGIA CONFIRMADA -> %.% (NODE: % -> %)', r_finished.schema_name, r_finished.index_name, r_finished.old_relfilenode, v_new_node; END IF;
                END IF;

            EXCEPTION WHEN OTHERS THEN
                UPDATE maint.reindex_tasks SET status = 'FAILED', ended_at = clock_timestamp(), error_log = SQLERRM WHERE task_id = r_finished.task_id;
                IF p_verbose THEN RAISE WARNING '    [ERROR] FALLO CRITICO EN %.%: %', r_finished.schema_name, r_finished.index_name, SQLERRM; END IF;

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
        LOOP_END;
        END LOOP;

        IF p_cutoff_time IS NOT NULL AND LOCALTIME >= p_cutoff_time THEN
            UPDATE maint.reindex_tasks SET status = 'SKIPPED_TIME_LIMIT', error_log = 'Cutoff Time Reached' WHERE job_id = v_job_id AND status = 'PENDING'; COMMIT;
        END IF;

        SELECT COUNT(*) INTO v_active_workers FROM maint.reindex_tasks WHERE job_id = v_job_id AND status = 'RUNNING';
        SELECT COUNT(*) INTO v_pending_tasks FROM maint.reindex_tasks WHERE job_id = v_job_id AND status = 'PENDING';
        IF v_active_workers = 0 AND v_pending_tasks = 0 THEN EXIT; END IF;

        WHILE v_active_workers < p_parallel_workers AND v_pending_tasks > 0 LOOP
            IF p_cutoff_time IS NOT NULL AND LOCALTIME >= p_cutoff_time THEN EXIT; END IF;

            SELECT task_id, schema_name, table_name, index_name, bloat_kb, bloat_pct, frag_pct, is_invalid 
            INTO v_task_id, v_schema, v_table, v_index, v_bloat_kb_eval, v_bloat_pct_eval, v_frag_pct_eval, r_idx.is_invalid 
            FROM maint.reindex_tasks WHERE job_id = v_job_id AND status = 'PENDING' ORDER BY is_invalid DESC, bloat_kb ASC, task_id ASC LIMIT 1;
            
            IF v_task_id IS NOT NULL THEN
                SELECT c.oid, c.relfilenode INTO v_index_oid, v_old_node 
                FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace 
                WHERE n.nspname = v_schema AND c.relname = v_index;

                -- =====================================================================================
                -- [NUEVO V3.6.0] PRE-VALIDACIÓN MULTI-DB DE ESPACIO EN DISCO PARA REINDEX (TECHO DE ACERO)
                -- =====================================================================================
                IF v_disk_total_size_gb > 0 THEN
                    -- 1. Calcular tamaño del índice únicamente (en GB)
                    v_max_indexes_gb   := pg_relation_size(v_index_oid) / (1024.0 * 1024.0 * 1024.0);
                    v_peak_required_gb := v_max_indexes_gb * v_wal_amplification_factor;

                    -- 2. Cálculo dinámico de ocupación de bases de datos según configuración target_databases_for_disk_check
                    IF TRIM(v_target_dbs_setting) = '-1' THEN
                        -- Modo -1: Suma el tamaño de TODAS las bases de datos conectables de la instancia
                        SELECT COALESCE(SUM(pg_database_size(oid)), 0) / (1024.0 * 1024.0 * 1024.0) 
                        INTO v_db_size_gb 
                        FROM pg_database 
                        WHERE datallowconn = TRUE;
                    ELSIF LOWER(TRIM(v_target_dbs_setting)) = 'current_database' THEN
                        -- Modo current_database: Evalúa únicamente la base de datos actual
                        v_db_size_gb := pg_database_size(current_database()) / (1024.0 * 1024.0 * 1024.0);
                    ELSE
                        -- Modo Lista Explicita: Parsea la lista separada por comas y sanitiza espacios
                        SELECT array_agg(TRIM(db_name)) INTO v_target_dbs_array
                        FROM unnest(string_to_array(v_target_dbs_setting, ',')) AS db_name;

                        -- Validar si al menos una base de datos existe en el clúster
                        IF NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = ANY(v_target_dbs_array)) THEN
                            RAISE EXCEPTION 'CRITICAL [CONFIGURACIÓN]: Ninguna de las bases de datos especificadas en target_databases_for_disk_check (%) existe en esta instancia.', v_target_dbs_setting;
                        END IF;

                        SELECT COALESCE(SUM(pg_database_size(datname)), 0) / (1024.0 * 1024.0 * 1024.0) 
                        INTO v_db_size_gb 
                        FROM pg_database 
                        WHERE datname = ANY(v_target_dbs_array);
                    END IF;

                    v_free_disk_gb := v_disk_total_size_gb - v_db_size_gb;

                    -- 3. Validación contra el margen de seguridad
                    IF (v_free_disk_gb - v_peak_required_gb) < v_disk_safety_margin_gb THEN
                        -- Formateo inteligente para evitar saturación de logs con cientos de DBs
                        IF TRIM(v_target_dbs_setting) = '-1' THEN
                            v_formatted_dbs_log := 'ALL (-1)';
                        ELSIF LOWER(TRIM(v_target_dbs_setting)) = 'current_database' THEN
                            v_formatted_dbs_log := 'Current DB Only';
                        ELSE
                            v_formatted_dbs_log := format('%s DB(s) [%s%s]', 
                                cardinality(v_target_dbs_array),
                                array_to_string(v_target_dbs_array[1:3], ', '),
                                CASE WHEN cardinality(v_target_dbs_array) > 3 THEN ', ...' ELSE '' END
                            );
                        END IF;

                        UPDATE maint.reindex_tasks 
                        SET status = 'SKIPPED_INSUFFICIENT_DISK_SPACE', 
                            ended_at = clock_timestamp(), 
                            error_log = format('SKIPPED: Insufficient disk space for %I.%I. Peak required (Index+WAL): %s GB. Available after operation: %s GB. Required safety margin: %s GB. Checked DBs: %s.',
                                               v_schema, 
                                               v_index, 
                                               ROUND(v_peak_required_gb, 2), 
                                               ROUND(v_free_disk_gb - v_peak_required_gb, 2), 
                                               ROUND(v_disk_safety_margin_gb, 2), 
                                               v_formatted_dbs_log)
                        WHERE task_id = v_task_id;
                        COMMIT;

                        IF p_verbose THEN 
                            RAISE WARNING '    [X] DISK SHIELD (OMITIDO): %.% | Formula: (Index: % GB * WAL: %) = % GB Req. | Disponible tras op: % GB', 
                                          v_schema, 
                                          v_index, 
                                          ROUND(v_max_indexes_gb, 2),
                                          ROUND(v_wal_amplification_factor, 1),
                                          ROUND(v_peak_required_gb, 2), 
                                          ROUND(v_free_disk_gb - v_peak_required_gb, 2); 
                        END IF;

                        v_pending_tasks := v_pending_tasks - 1;
                        CONTINUE; -- Bypass quirúrgico: saltar al siguiente índice en la cola
                    END IF;
                END IF;
                -- =====================================================================================

                UPDATE maint.reindex_tasks SET status = 'RUNNING', started_at = clock_timestamp(), old_relfilenode = v_old_node WHERE task_id = v_task_id; 
                
                -- LIBERACIÓN CRÍTICA 3: Cierra la transacción antes del lanzamiento
                COMMIT; 

                v_raw_sql := format('REINDEX INDEX CONCURRENTLY %I.%I;', v_schema, v_index);

                -- [LANZAMIENTO DINÁMICO POLIMÓRFICO]: Extracción limpia directamente en la cláusula INTO
                IF v_is_v2 THEN
                    EXECUTE 'SELECT pid, cookie FROM public.pg_background_launch($1)' 
                    INTO v_child_pid, v_child_cookie 
                    USING v_raw_sql;
                ELSE
                    EXECUTE 'SELECT public.pg_background_launch($1)' 
                    INTO v_child_pid 
                    USING v_raw_sql;
                    
                    v_child_cookie := NULL;
                END IF;

                UPDATE maint.reindex_tasks 
                SET child_pid = v_child_pid, child_cookie = v_child_cookie 
                WHERE task_id = v_task_id; 
                
                -- LIBERACIÓN CRÍTICA 4: Cierra la transacción inmediatamente para que los trabajadores no esperen al Padre
                COMMIT; 

                IF p_verbose THEN RAISE INFO '    [>] LANZANDO [REINDEX] PID % -> %.% (OLD NODE: %) | Frag: %%% | Bloat: %%% / % KB', v_child_pid, v_schema, v_index, v_old_node, v_frag_pct_eval, v_bloat_pct_eval, v_bloat_kb_eval; END IF;
                v_active_workers := v_active_workers + 1; v_pending_tasks := v_pending_tasks - 1;
            END IF;
        END LOOP;

        -- LIBERACIÓN CRÍTICA 5: Mantiene la sesión del orquestador libre de snapshots viejos en la espera
        COMMIT;
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

    IF EXISTS (SELECT 1 FROM maint.reindex_tasks WHERE job_id = v_job_id AND status = 'SKIPPED_TIME_LIMIT') THEN
        UPDATE maint.jobs SET status = 'COMPLETED_WITH_CUTOFF', ended_at = clock_timestamp(), tables_processed = v_success_count WHERE job_id = v_job_id;
    ELSE
        UPDATE maint.jobs SET status = 'COMPLETED', ended_at = clock_timestamp(), tables_processed = v_success_count WHERE job_id = v_job_id;
    END IF;
    
    IF NOT p_keep_history THEN DELETE FROM maint.reindex_tasks WHERE job_id = v_job_id; END IF;

    IF array_length(v_changed_params, 1) > 0 THEN FOR i IN 1 .. array_length(v_changed_params, 1) LOOP EXECUTE format('ALTER ROLE %I RESET %I', current_user, v_changed_params[i]); END LOOP; END IF;
    COMMIT;

    IF p_verbose THEN 
        RAISE INFO '---------------------------------------------------------';
        RAISE INFO '[✓] ORQUESTACION REINDEX FINALIZADA. Job % | Procesados: % / %', v_job_id, v_success_count, v_total_tasks;
        RAISE INFO 'Tiempo Total: %', (clock_timestamp() - v_start_time);
        RAISE INFO '=========================================================';
    END IF;
END;
$$;

REVOKE EXECUTE ON PROCEDURE maint.sp_orchestrate_reindex FROM PUBLIC;

COMMIT;
