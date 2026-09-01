-- =========================================================================================
--               DBA SQUAD: VANGUARD BLACK-OPS - SUITE DE MANTENIMIENTO
-- =========================================================================================
-- CONFIGURACIÓN DE PROGRAMACIÓN NATIVA CON EXTENSIÓN pg_cron
-- Ubicación de pg_cron : postgres (Base de datos del sistema)
-- Base de Datos Destino : db_mantos (Donde reside el esquema maint)
-- Usuario S.O. / DB     : postgres
-- Ventana Nocturna      : 01:00 AM - 06:00 AM
-- =========================================================================================


-- -----------------------------------------------------------------------------------------
-- 1. 📡 MÓDULO TRIAGE RADAR (Construcción de Telemetría Sostenida - DIARIO Y HOMOLOGADO)
-- -----------------------------------------------------------------------------------------
-- Recolecta la métrica de bloat diario sin realizar mantenimiento. Necesario para alimentar 
-- la tabla maint.pgstattuple y validar la regla p_sustained_days del VACUUM FULL.
-- NOTA DE ARQUITECTURA: Parámetros 100% HOMOLOGADOS con el Módulo 4 (VACUUM FULL).

SELECT cron.schedule_in_database(
    'maint_pgstattuple_diario',
    '0 0 * * *',                               -- Todos los días a las 00:00 AM (Apertura de ventana)
    $$CALL maint.sp_pgstattuple(
        p_scope               => 'SMART_USER', -- Alcance: Evalúa las tablas de esquemas de usuario
        p_bloat_pct_threshold => 45.00,        -- HOMOLOGADO: Exige 45% de bloat (Igual que Vacuum Full)
        p_bloat_mb_threshold  => 5120.00,      -- HOMOLOGADO: Exige 5 GB de espacio libre (Igual que Vacuum Full)
        p_threshold_operator  => 'AND',        -- HOMOLOGADO: Exige cumplir AMBAS condiciones (Igual que Vacuum Full)
        p_min_table_mb        => 500.00,       -- HOMOLOGADO: Solo evalúa tablas de 1 GB o superiores
        p_force_bloat_mb      => 20480.00,         -- Bypass por tamaño extremo (Desactivado en Radar)
        p_enable_deep_scan    => FALSE,        -- Desactivado para no saturar I/O (Usa aproximación rápida)
        p_verbose             => FALSE         -- Ejecución silenciosa para logs del cron
    );$$,
    'db_mantos',                           -- Base de datos destino explícita
    'postgres',                                -- Usuario con privilegios de ejecución
    TRUE
);


-- -----------------------------------------------------------------------------------------
-- 2. 🧹 MÓDULO VACUUM (Limpieza Asíncrona Non-Blocking)
-- -----------------------------------------------------------------------------------------
-- Recupera espacio libre de tuplas muertas sin bloquear lecturas ni escrituras. 
-- Calibrado con valores bajos para ejecución diaria constante.

SELECT cron.schedule_in_database(
    'maint_vacuum_lunes_a_viernes',
    '0 1 * * 1-5',                             -- Lunes a Viernes a la 01:00 AM
    $$CALL maint.sp_orchestrate_vacuum(
        p_scope            => 'SMART_USER',     -- Alcance: Evalúa las tablas de usuario con inteligencia
        p_profile          => 'BALANCED',       -- Perfil: Balance ideal entre limpieza e I/O
        p_parallel_workers => 4,                -- Concurrencia: 4 hilos para barrido rápido en segundo plano
        p_cutoff_time      => '05:00:00'::TIME, -- Freno de emergencia: Detener si llega a las 05:00 AM
        p_verbose          => FALSE,            -- Diagnóstico: Desactivado para ejecución silenciosa en Cron
        
        -- UMBRALES INTERMEDIO-CRÍTICO (Tranquilo/Bajo para barrido diario):
        p_threshold_pct    => 20.00,            -- Mínimo de basura porcentual (20% de tuplas muertas)
        p_min_dead_rows    => 1000,             -- Filtro anti-morralla (Ignora tablas con < 1,000 tuplas muertas)
        p_force_dead_rows  => 50000,            -- Bypass de emergencia: Fuerza ejecución si supera 50,000 muertas
        
        p_keep_history     => TRUE              -- Auditoría: Conservar historial en maint.vacuum_tasks
    );$$,
    'db_mantos',                           -- Base de datos destino explícita
    'postgres',                                -- Usuario con privilegios de ejecución
    TRUE
);


-- -----------------------------------------------------------------------------------------
-- 3. 📊 MÓDULO ANALYZE (Preparación Diaria de Optimizador)
-- -----------------------------------------------------------------------------------------
-- Refresca el mapa estadístico del planificador de consultas de PostgreSQL.
-- Excluye los Sábados para evitar redundancia con el Analyze masivo post-cirugía.

SELECT cron.schedule_in_database(
    'maint_analyze_madrugada_diario',
    '0 4 * * 0-5',                             -- Domingo a Viernes a las 04:00 AM (Excluye Sábados)
    $$CALL maint.sp_orchestrate_analyze(
        p_scope            => 'SMART_USER',     -- Alcance: Estadísticas de esquemas de usuario
        p_profile          => 'NORMAL',         -- Perfil: Analiza con muestra estándar del sistema
        p_parallel_workers => 4,                -- Concurrencia: Actualiza 4 tablas de forma simultánea
        p_verbose          => FALSE,            -- Diagnóstico: Silencioso
        
        -- UMBRALES INTERMEDIO-CRÍTICO (Tranquilo/Bajo para planificador fresco):
        p_threshold_pct    => 10.00,            -- Actúa si el 10% de la tabla ha sufrido modificaciones
        p_min_chg_rows     => 1000,             -- Requiere al menos 1,000 cambios reales para actuar
        p_force_chg_rows   => 50000,            -- Bypass: Si cambian 50,000 filas, actualiza de inmediato
        
        p_cutoff_time      => '06:00:00'::TIME, -- Límite horario para no solapar procesos matutinos
        p_keep_history     => TRUE              -- Auditoría: Conservar log de ejecuciones
    );$$,
    'db_mantos',                           -- Base de datos destino explícita
    'postgres',                                -- Usuario con privilegios de ejecución
    TRUE
);


-- -----------------------------------------------------------------------------------------
-- 4. 🏥 MÓDULO VACUUM FULL (Cirugía Mayor y Actualización Total en Bloque Secuencial)
-- -----------------------------------------------------------------------------------------
-- El único módulo que aplica bloqueos exclusivos (AccessExclusiveLock).
-- Encapsulado en un bloque DO $$ para forzar la actualización masiva de estadísticas al finalizar.

SELECT cron.schedule_in_database(
    'maint_vacuum_full_mayor_sabados',
    '0 1 * * 6',                               -- Sábados a la 01:00 AM
    $$
    DO $block$
    BEGIN
        -- PASO 1: Cirugía Mayor Quirúrgica (Solo las tablas que el Radar evaluó durante 5 días)
        CALL maint.sp_orchestrate_vacuum_full(
            p_scope               => 'SMART_USER',     -- Alcance: Tablas de usuario a evaluación estricta
            p_profile             => 'SMART',          -- Perfil: Basado en histórico de telemetría sostenida
            p_parallel_workers    => 1,                -- Máxima seguridad: 1 solo hilo (Bloqueo Total)
            p_cutoff_time         => '05:50:00'::TIME, -- Límite estricto de finalización para liberar sistema
            p_kill_active_on_cutoff => TRUE,           -- Cierra procesos RUNNING al alcanzar el tiempo en p_cutoff_time.            
            p_verbose             => FALSE,            -- Diagnóstico: Silencioso
            
            -- UMBRALES INTERMEDIO-CRÍTICO (Extremo/Agresivo para EVITAR el bloqueo innecesario):
            p_bloat_pct_threshold => 45.00,            -- Exige que la tabla esté inflada al menos un 45%
            p_bloat_mb_threshold  => 5120.00,          -- Exige que la tabla tenga al menos 5 GB recuperables
            p_threshold_operator  => 'AND',             -- DEBE cumplir ambas condiciones para aplicar (Súper estricto)
            p_sustained_days      => 5,               -- La anomalía debe persistir 5 días seguidos en el Radar
            p_min_table_mb        => 500.00,          -- Solo evalúa tablas que pesan 1 GB o más
            p_force_bloat_mb      => 20480.00,         -- Bypass de Rescate: Si la tabla tiene 20 GB de bloat, entra de golpe
            p_enable_deep_scan    => FALSE,            -- Desactiva escaneo de bloque lento (Usa aproximación rápida)
            
            p_keep_history        => TRUE              -- Auditoría: Registro obligatorio en maint.vacuum_full_tasks
        );

        -- PASO 2: Regeneración del Cerebro Matemático del Motor (pg_statistic)
        -- Fuerza Bruta (ALL_USER): Obliga a leer todo el catálogo para preparar los planes del Lunes.
        CALL maint.sp_orchestrate_analyze(
            p_scope            => 'ALL_USER',          -- Alcance: Barrido Ciego Total sobre esquemas de usuario
            p_profile          => 'NORMAL',            -- Perfil: Muestra estándar del motor
            p_parallel_workers => 4,                   -- Concurrencia: 4 hilos paralelos
            p_verbose          => FALSE,               -- Diagnóstico: Silencioso
            
            -- UMBRALES ANULADOS (Fuerza Bruta para actualizar tablas operadas y sanas):
            p_threshold_pct    => 0.00,                -- Sin umbral de porcentaje
            p_min_chg_rows     => 0,                   -- Sin mínimo de cambios
            p_force_chg_rows   => 0,                   -- Sin bypass necesario
            
            p_cutoff_time      => '06:00:00'::TIME,    -- Freno final antes de la apertura de servicios
            p_keep_history     => FALSE                -- No saturar la tabla de auditoría con el Analyze masivo
        );
    END;
    $block$;
    $$,
    'db_mantos',                           -- Base de datos destino explícita
    'postgres',                                -- Usuario con privilegios de ejecución
    TRUE
);


-- -----------------------------------------------------------------------------------------
-- 5. 🌳 MÓDULO REINDEX (Desfragmentación B-Tree Cero-Bloqueo)
-- -----------------------------------------------------------------------------------------
-- Sanea índices zombis y reconstruir árboles B-Tree en caliente (CONCURRENTLY).
-- Flexible pero controlado, dado que no bloquea pero genera un volumen alto de I/O en disco.

SELECT cron.schedule_in_database(
    'maint_reindex_domingos',
    '0 1 * * 0',                               -- Domingos a la 01:00 AM
    $$CALL maint.sp_orchestrate_reindex(
        p_scope               => 'SMART_USER',     -- Alcance: Todos los índices de usuario a evaluación
        p_profile             => 'CONCURRENT',     -- Perfil: Reconstrucción online Cero-Bloqueo
        p_parallel_workers    => 2,                -- Seguridad I/O: Limitado a 2 hilos para cuidar el disco
        p_cutoff_time         => '06:00:00'::TIME, -- Freno de emergencia: Abortar si alcanza las 06:00 AM
        p_verbose             => FALSE,            -- Diagnóstico: Silencioso
        
        -- UMBRALES INTERMEDIO-CRÍTICO (Flexible y Controlado):
        p_frag_pct_threshold  => 40.00,            -- Tolerancia de Fragmentación Foliar: Hasta 40%
        p_bloat_pct_threshold => 20.00,            -- Tolerancia de Bloat (Espacio Vacío): Hasta 20%
        p_bloat_mb_threshold  => 1024.00,          -- Tolerancia Absoluta: 1 GB (1024 MB) de basura en el índice
        p_threshold_operator  => 'OR',             -- Condición: Si rompe CUALQUIERA de las 2 reglas de bloat/MB
        p_min_index_mb        => 10.00,            -- Descartar evaluación de índices menores a 10 MB
        p_force_frag_pct      => NULL,             -- Bypass directo de fragmentación (Desactivado)
        p_force_bloat_mb      => NULL,             -- Bypass directo de Bloat MB (Desactivado)
        
        p_rebuild_invalid     => TRUE,             -- Zombis: Reconstrucción forzada y prioritaria de índices caídos
        p_keep_history        => TRUE              -- Auditoría: Conservar historial forense
    );$$,
    'db_mantos',                           -- Base de datos destino explícita
    'postgres',                                -- Usuario con privilegios de ejecución
    TRUE
);



-- -----------------------------------------------------------------------------------------
-- 🧹 MÓDULO PURGA DE MANTENIMIENTO (Mantenimiento Periódico de Tablas Históricas)
-- -----------------------------------------------------------------------------------------
-- Libera espacio en disco y trunca las tablas de métricas/tareas del esquema maint.
-- Se ejecuta automáticamente cada 3 meses (1ro de Ene, Abr, Jul, Oct a las 00:00 hrs).
-- Target DB: db_mantos
-- NOTA: TRUNCATE es ultra rápido ya que libera los bloques a nivel de archivo SO sin generar bloat.

SELECT cron.schedule_in_database(
    'truncate-maint-tables',         -- Nombre único para el job en pg_cron
    '0 0 1 */3 *',                   -- Expresión Cron: Minuto 0, Hora 0, Día 1, Cada 3 meses
    $$ 
        -- Vaciado en bloque para minimizar bloqueos concurrentes en el diccionario de datos
        TRUNCATE TABLE 
            maint.jobs,
            maint.analyze_tasks,
            maint.pgstatindex,
            maint.reindex_tasks,
            maint.pgstattuple,
            maint.vacuum_full_tasks,
            maint.vacuum_tasks;
    $$,
    'db_mantos',                  -- Base de datos objetivo
    'postgres',                       -- Usuario ejecutor
    true                              -- Estado: Activo
);


--- CONSULTA DE CONFIRMACIÓN POST-EJECUCIÓN
SELECT jobid, 
       schedule, 
       jobname, 
       database, 
       username, 
       active 
FROM cron.job 
ORDER BY jobid ASC;
