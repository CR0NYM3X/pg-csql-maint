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





-- =========================================================================================
-- 4. TABLA DE TELEMETRÍA RENOMBRADA: maint.pgstattuple
-- =========================================================================================
-- DROP TABLE IF EXISTS maint.pgstattuple CASCADE;
CREATE TABLE maint.pgstattuple (
    triage_id BIGSERIAL PRIMARY KEY, 
    evaluation_date DATE NOT NULL DEFAULT current_date, 
    schema_name VARCHAR(255) NOT NULL, 
    table_name VARCHAR(255) NOT NULL, 
    
    -- Fase 1: Control y Salida Nativa de pgstattuple_approx
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
    
    -- Fase 2: Control y Salida Nativa de pgstattuple (Profundo)
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
    
    -- Ecuación Unificada de Bloat (Total)
    total_bloat_mb NUMERIC(12,2) NOT NULL DEFAULT 0.00,
    total_bloat_pct NUMERIC(12,2) NOT NULL DEFAULT 0.00,
    
    -- Semáforo de Orquestación
    requiere_vf BOOLEAN NOT NULL DEFAULT FALSE, 

    CONSTRAINT uq_triage_date_schema_table UNIQUE (evaluation_date, schema_name, table_name)
);




-- Comentarios exhaustivos de la tabla de Triage requeridos.
COMMENT ON TABLE maint.pgstattuple IS 'Histórico diario de telemetría física. Registra la salida cruda de pgstattuple y la Ecuación Unificada de Bloat.';
COMMENT ON COLUMN maint.pgstattuple.total_bloat_pct IS 'Suma matemática de espacio libre % + tuplas muertas %. Mide el bloat real independientemente de si pasó autovacuum o no.';
COMMENT ON COLUMN maint.pgstattuple.total_bloat_mb IS 'Suma matemática en Megabytes del espacio libre interno + bytes de tuplas muertas.';
COMMENT ON COLUMN maint.pgstattuple.triage_id IS 'Llave primaria. Identificador único de cada escaneo realizado a una tabla.';
COMMENT ON COLUMN maint.pgstattuple.evaluation_date IS 'Fecha exacta (Año-Mes-Día). Evita duplicados el mismo día y permite crear un historial de crecimiento diario del Bloat.';
COMMENT ON COLUMN maint.pgstattuple.schema_name IS 'Nombre del esquema donde reside la tabla evaluada.';
COMMENT ON COLUMN maint.pgstattuple.table_name IS 'Nombre de la tabla evaluada.';
COMMENT ON COLUMN maint.pgstattuple.approx_scanned IS 'Fase 1: Indica en TRUE si la tabla pasó por el escaneo ultrarrápido (pgstattuple_approx) sin leer todos los bloques del disco.';
COMMENT ON COLUMN maint.pgstattuple.approx_evaluated_at IS 'Fase 1: Timestamp exacto de cuándo se realizó la evaluación superficial.';
COMMENT ON COLUMN maint.pgstattuple.approx_table_len IS 'Fase 1: Tamaño total de la tabla en bytes detectado por el escaneo superficial.';
COMMENT ON COLUMN maint.pgstattuple.approx_dead_tuple_percent IS 'Fase 1: Porcentaje de registros muertos/eliminados detectado de forma aproximada.';
COMMENT ON COLUMN maint.pgstattuple.approx_free_percent IS 'Fase 1: El porcentaje de "aire" (espacio libre interno) que tiene la tabla y que podría recuperarse.';
COMMENT ON COLUMN maint.pgstattuple.approx_scanned_percent IS 'Fase 1: Porcentaje del disco que el motor leyó para deducir esta aproximación (generalmente un porcentaje muy bajo).';
COMMENT ON COLUMN maint.pgstattuple.deep_scanned IS 'Fase 2: Indica en TRUE si se activó el escáner agresivo bloque bloque (pgstattuple profundo) porque la tabla superó el umbral en la Fase 1 y el parámetro de escaneo estaba encendido.';
COMMENT ON COLUMN maint.pgstattuple.deep_evaluated_at IS 'Fase 2: Timestamp exacto de cuándo se realizó la evaluación profunda y costosa de I/O.';
COMMENT ON COLUMN maint.pgstattuple.deep_table_len IS 'Fase 2: Tamaño real y exacto en bytes de la tabla validado leyendo el 100% de los bloques.';
COMMENT ON COLUMN maint.pgstattuple.deep_dead_tuple_percent IS 'Fase 2: Porcentaje matemático real y exacto de tuplas muertas en disco.';
COMMENT ON COLUMN maint.pgstattuple.deep_free_percent IS 'Fase 2: Porcentaje de aire real. Este es el espacio libre exacto que un VACUUM FULL le devolverá al sistema operativo.';
COMMENT ON COLUMN maint.pgstattuple.requiere_vf IS 'Semáforo de orquestación. Si está en TRUE (por superar los umbrales en Fase 1 o Fase 2), el orquestador tiene luz verde para aplicar VACUUM FULL sin tener que hacer matemáticas complejas en la madrugada.';






CREATE   TABLE  IF NOT EXISTS maint.vacuum_full_tasks (
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






 
/* =========================================================================================
   PROCEDIMIENTO: maint.sp_pgstattuple (Renombrado y Actualizado)
   FUNCIÓN: Escáner forense con Feature Toggle. Evalúa fragmentación (Aprox o Profundo).
========================================================================================= */
CREATE OR REPLACE PROCEDURE maint.sp_pgstattuple(
    p_scope VARCHAR DEFAULT 'ALL_USER',
    p_bloat_pct_threshold NUMERIC DEFAULT 25.00,
    p_bloat_mb_threshold NUMERIC DEFAULT 1024.00,
    p_threshold_operator VARCHAR DEFAULT 'OR',  -- [NUEVO] Compuerta Lógica ('OR' / 'AND') PARA p_bloat_pct_threshold, p_bloat_mb_threshold
    p_min_table_mb NUMERIC DEFAULT 0.00,
    p_enable_deep_scan BOOLEAN DEFAULT FALSE,
    p_verbose BOOLEAN DEFAULT FALSE
)
LANGUAGE plpgsql AS $$
DECLARE
    r_table RECORD; r_approx RECORD; r_deep RECORD;
    v_today DATE := current_date; 
    v_processed INT := 0; v_sniped INT := 0;
    v_total_bloat_pct NUMERIC(5,2); v_total_bloat_mb NUMERIC;
    v_requiere_vf BOOLEAN := FALSE;
    v_op_upper VARCHAR := UPPER(p_threshold_operator);
BEGIN
    PERFORM pg_catalog.set_config('client_min_messages', 'notice', false);
    PERFORM pg_catalog.set_config('search_path', 'maint, public, pg_temp', true);

    -- [QA] Validación estricta del operador lógico
    IF v_op_upper NOT IN ('AND', 'OR') THEN
        RAISE EXCEPTION 'CRÍTICO: El parámetro p_threshold_operator solo admite ''AND'' u ''OR''. Valor recibido: %', p_threshold_operator;
    END IF;

    IF p_verbose THEN
        RAISE INFO '=========================================================';
        RAISE INFO '[DBA SQUAD] RADAR DE TRIAGE DIARIO (V3.3 - LOGIC: %)', v_op_upper;
        RAISE INFO '=========================================================';
    END IF;

    FOR r_table IN (
        SELECT c.oid AS table_oid, n.nspname AS schema_name, c.relname AS table_name
        FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
        LEFT JOIN maint.filters mf ON mf.schema_name = n.nspname AND mf.table_name = c.relname
        WHERE c.relkind IN ('r', 'm') AND n.nspname <> 'pg_toast'
          AND pg_relation_size(c.oid) >= (p_min_table_mb * 1024 * 1024)
          AND (
              (p_scope = 'CUSTOM_LIST' AND mf.force_maintenance = TRUE) OR
              (p_scope IN ('SMART_USER', 'ALL_USER') AND n.nspname NOT IN ('pg_catalog', 'information_schema')) OR
              (p_scope IN ('SMART_SYSTEM_USER', 'ALL_SYSTEM_USER')) OR
              (p_scope = 'ALL_SYSTEM' AND n.nspname IN ('pg_catalog', 'information_schema'))
          )
    ) LOOP
        BEGIN
            -- FASE 1
            SELECT * INTO r_approx FROM pgstattuple_approx(r_table.table_oid);
            v_processed := v_processed + 1;

            v_total_bloat_pct := COALESCE(r_approx.approx_free_percent, 0.00) + COALESCE(r_approx.dead_tuple_percent, 0.00);
            v_total_bloat_mb  := ROUND(((COALESCE(r_approx.approx_free_space, 0) + COALESCE(r_approx.dead_tuple_len, 0)) / 1024.0 / 1024.0), 2);

            -- Evaluación Dinámica del Operador Lógico
            IF v_op_upper = 'AND' THEN
                v_requiere_vf := (v_total_bloat_pct >= p_bloat_pct_threshold AND v_total_bloat_mb >= p_bloat_mb_threshold);
            ELSE
                v_requiere_vf := (v_total_bloat_pct >= p_bloat_pct_threshold OR v_total_bloat_mb >= p_bloat_mb_threshold);
            END IF;

            -- FASE 2
            IF p_enable_deep_scan AND v_requiere_vf THEN
                SELECT * INTO r_deep FROM pgstattuple(r_table.table_oid);
                
                v_total_bloat_pct := COALESCE(r_deep.free_percent, 0.00) + COALESCE(r_deep.dead_tuple_percent, 0.00);
                v_total_bloat_mb  := ROUND(((COALESCE(r_deep.free_space, 0) + COALESCE(r_deep.dead_tuple_len, 0)) / 1024.0 / 1024.0), 2);
                
                IF v_op_upper = 'AND' THEN
                    v_requiere_vf := (v_total_bloat_pct >= p_bloat_pct_threshold AND v_total_bloat_mb >= p_bloat_mb_threshold);
                ELSE
                    v_requiere_vf := (v_total_bloat_pct >= p_bloat_pct_threshold OR v_total_bloat_mb >= p_bloat_mb_threshold);
                END IF;

                INSERT INTO maint.pgstattuple (
                    evaluation_date, schema_name, table_name, 
                    approx_scanned, approx_evaluated_at, approx_table_len, approx_scanned_percent, approx_tuple_count, approx_tuple_len, approx_tuple_percent, approx_dead_tuple_count, approx_dead_tuple_len, approx_dead_tuple_percent, approx_free_space, approx_free_percent,
                    deep_scanned, deep_evaluated_at, deep_table_len, deep_tuple_count, deep_tuple_len, deep_tuple_percent, deep_dead_tuple_count, deep_dead_tuple_len, deep_dead_tuple_percent, deep_free_space, deep_free_percent,
                    total_bloat_mb, total_bloat_pct, requiere_vf
                ) VALUES (
                    v_today, r_table.schema_name, r_table.table_name, 
                    TRUE, clock_timestamp(), COALESCE(r_approx.table_len, 0), COALESCE(r_approx.scanned_percent, 0.00), COALESCE(r_approx.approx_tuple_count, 0), COALESCE(r_approx.approx_tuple_len, 0), COALESCE(r_approx.approx_tuple_percent, 0.00), COALESCE(r_approx.dead_tuple_count, 0), COALESCE(r_approx.dead_tuple_len, 0), COALESCE(r_approx.dead_tuple_percent, 0.00), COALESCE(r_approx.approx_free_space, 0), COALESCE(r_approx.approx_free_percent, 0.00),
                    TRUE, clock_timestamp(), COALESCE(r_deep.table_len, 0), COALESCE(r_deep.tuple_count, 0), COALESCE(r_deep.tuple_len, 0), COALESCE(r_deep.tuple_percent, 0.00), COALESCE(r_deep.dead_tuple_count, 0), COALESCE(r_deep.dead_tuple_len, 0), COALESCE(r_deep.dead_tuple_percent, 0.00), COALESCE(r_deep.free_space, 0), COALESCE(r_deep.free_percent, 0.00),
                    v_total_bloat_mb, v_total_bloat_pct, v_requiere_vf
                ) ON CONFLICT (evaluation_date, schema_name, table_name) DO UPDATE SET
                    approx_scanned = TRUE, approx_evaluated_at = clock_timestamp(), approx_table_len = EXCLUDED.approx_table_len, approx_scanned_percent = EXCLUDED.approx_scanned_percent, approx_tuple_count = EXCLUDED.approx_tuple_count, approx_tuple_len = EXCLUDED.approx_tuple_len, approx_tuple_percent = EXCLUDED.approx_tuple_percent, approx_dead_tuple_count = EXCLUDED.approx_dead_tuple_count, approx_dead_tuple_len = EXCLUDED.approx_dead_tuple_len, approx_dead_tuple_percent = EXCLUDED.approx_dead_tuple_percent, approx_free_space = EXCLUDED.approx_free_space, approx_free_percent = EXCLUDED.approx_free_percent,
                    deep_scanned = TRUE, deep_evaluated_at = clock_timestamp(), deep_table_len = EXCLUDED.deep_table_len, deep_tuple_count = EXCLUDED.deep_tuple_count, deep_tuple_len = EXCLUDED.deep_tuple_len, deep_tuple_percent = EXCLUDED.deep_tuple_percent, deep_dead_tuple_count = EXCLUDED.deep_dead_tuple_count, deep_dead_tuple_len = EXCLUDED.deep_dead_tuple_len, deep_dead_tuple_percent = EXCLUDED.deep_dead_tuple_percent, deep_free_space = EXCLUDED.deep_free_space, deep_free_percent = EXCLUDED.deep_free_percent,
                    total_bloat_mb = EXCLUDED.total_bloat_mb, total_bloat_pct = EXCLUDED.total_bloat_pct, requiere_vf = EXCLUDED.requiere_vf;
                
                v_sniped := v_sniped + 1;
            ELSE
                INSERT INTO maint.pgstattuple (
                    evaluation_date, schema_name, table_name, 
                    approx_scanned, approx_evaluated_at, approx_table_len, approx_scanned_percent, approx_tuple_count, approx_tuple_len, approx_tuple_percent, approx_dead_tuple_count, approx_dead_tuple_len, approx_dead_tuple_percent, approx_free_space, approx_free_percent,
                    total_bloat_mb, total_bloat_pct, requiere_vf
                ) VALUES (
                    v_today, r_table.schema_name, r_table.table_name, 
                    TRUE, clock_timestamp(), COALESCE(r_approx.table_len, 0), COALESCE(r_approx.scanned_percent, 0.00), COALESCE(r_approx.approx_tuple_count, 0), COALESCE(r_approx.approx_tuple_len, 0), COALESCE(r_approx.approx_tuple_percent, 0.00), COALESCE(r_approx.dead_tuple_count, 0), COALESCE(r_approx.dead_tuple_len, 0), COALESCE(r_approx.dead_tuple_percent, 0.00), COALESCE(r_approx.approx_free_space, 0), COALESCE(r_approx.approx_free_percent, 0.00),
                    v_total_bloat_mb, v_total_bloat_pct, v_requiere_vf
                ) ON CONFLICT (evaluation_date, schema_name, table_name) DO UPDATE SET
                    approx_scanned = TRUE, approx_evaluated_at = clock_timestamp(), approx_table_len = EXCLUDED.approx_table_len, approx_scanned_percent = EXCLUDED.approx_scanned_percent, approx_tuple_count = EXCLUDED.approx_tuple_count, approx_tuple_len = EXCLUDED.approx_tuple_len, approx_tuple_percent = EXCLUDED.approx_tuple_percent, approx_dead_tuple_count = EXCLUDED.approx_dead_tuple_count, approx_dead_tuple_len = EXCLUDED.approx_dead_tuple_len, approx_dead_tuple_percent = EXCLUDED.approx_dead_tuple_percent, approx_free_space = EXCLUDED.approx_free_space, approx_free_percent = EXCLUDED.approx_free_percent,
                    total_bloat_mb = EXCLUDED.total_bloat_mb, total_bloat_pct = EXCLUDED.total_bloat_pct, requiere_vf = EXCLUDED.requiere_vf;
            END IF;

        EXCEPTION WHEN OTHERS THEN
            IF p_verbose THEN RAISE WARNING 'Error analizando %.%: %', r_table.schema_name, r_table.table_name, SQLERRM; END IF;
        END;
        COMMIT; 
    END LOOP;

    IF p_verbose THEN RAISE INFO '[✓] TRIAGE FINALIZADO. Evaluadas: %, Deep Scans: %', v_processed, v_sniped; END IF;
END;
$$;



REVOKE EXECUTE ON PROCEDURE maint.sp_pgstattuple FROM PUBLIC;


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


REVOKE EXECUTE ON PROCEDURE  maint.sp_orchestrate_vacuum_full FROM PUBLIC;


