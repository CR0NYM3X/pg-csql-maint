```
  ██████╗   ██████╗      ██████╗ ███████╗ ██████╗ ██╗        ███╗   ██╗  █████╗  ██████╗ ███╗   ██╗ ████████╗
  ██╔══██╗ ██╔════╝     ██╔════╝ ██╔════╝██╔═══██╗██║        ████╗ ████║██╔══██╗   ██║   ████╗  ██║ ╚══██╔══╝
  ██████╔╝ ██║  ███╗    ██║      ███████╗██║   ██║██║        ██╔████╔██║███████║   ██║   ██╔██╗ ██║    ██║   
  ██╔═══╝  ██║   ██║    ██║      ╚════██║██║▄▄ ██║██║        ██║╚██╔╝██║██╔══██║   ██║   ██║╚██╗██║    ██║   
  ██║      ╚██████╔╝    ╚██████╗ ███████║╚██████╔╝███████╗   ██║ ╚═╝ ██║██║  ██║ ██████╗ ██║ ╚████║    ██║   
  ╚═╝       ╚═════╝      ╚═════╝ ╚══════╝ ╚══▀▀═╝ ╚══════╝   ╚═╝     ╚═╝╚═╝  ╚═╝ ╚═════╝ ╚═╝  ╚═══╝    ╚═╝   
```
# 🛡️ pg-csql-maint 

**pg-csql-maint** es la suite definitiva de orquestación asíncrona, predictiva y forense para el mantenimiento de bases de datos PostgreSQL de alta transaccionalidad.

Diseñada bajo estrictos estándares de ingeniería de confiabilidad (SRE), esta suite erradica la contención de bloqueos, el *bloat* silencioso y la degradación de índices mediante operaciones multi-hilo en segundo plano. No confía en ejecuciones a ciegas: cada módulo evalúa la salud física del motor, interviene quirúrgicamente y verifica los *checksums* de los inodos en disco para garantizar una auditoría inmutable.

*(Vista general del ecosistema modular en el repositorio base, referenciado en image_3889ad.png).*

---

## 🏛️ Arquitectura del Cuarto de Control (Esquema `maint`)

La suite opera de manera unificada a través de 4 tablas maestras que actúan como su cerebro operativo:

* **`maint.jobs`**: Cabecera maestra que registra cada ciclo de orquestación, parámetros JSONB inmutables y tiempos totales.
* **`maint.[modulo]_tasks`**: Colas transaccionales individuales por módulo. Registran PIDs de *workers*, métricas de entrada y validaciones físicas (`old_relfilenode` vs `new_relfilenode`).
* **`maint.filters`**: Escudo de seguridad unificado. Permite configurar Listas Negras (`is_ignored = TRUE`) y Listas VIP/Blancas (`force_maintenance = TRUE`) a nivel de tabla y operación.
* **Telemetría Inteligente**: Tablas como `maint.pgstatindex` y `maint.pgstattuple` actúan como radares diarios, evaluando la "Santa Trinidad del B-Tree" y el historial de degradación sin estresar el servidor.

---

## 🚀 Guía de Ejecución y Umbrales Críticos

A continuación, se presentan las rutinas de ejecución para cada uno de los 4 pilares de la suite. Todos los parámetros de las firmas PL/pgSQL están expuestos y documentados.

> 💡 **Nota de Configuración Táctica:** Los valores de los ejemplos están calibrados según el impacto de la operación. `VACUUM` y `ANALYZE` utilizan umbrales **bajos/tranquilos** para mantenimiento preventivo diario. `REINDEX` usa umbrales **flexibles** para controlar el I/O, y `VACUUM FULL` usa umbrales **agresivos/restrictivos** para evitar cirugías bloqueantes a menos que la situación sea crítica.

### 1. 🧹 Módulo VACUUM (Limpieza Asíncrona Non-Blocking)

Recupera espacio libre de tuplas muertas sin bloquear lecturas ni escrituras. Calibrado con valores bajos para ejecución diaria constante.

```sql
-- Ejecución recomendada: Diario (ej. 02:00 AM o bajo demanda diurna)
CALL maint.sp_orchestrate_vacuum(
    p_scope             => 'SMART_USER',     -- Alcance: Evalúa las tablas de usuario con inteligencia
    p_profile           => 'BALANCED',       -- Perfil: Balance ideal entre limpieza e I/O
    p_parallel_workers  => 4,                -- Concurrencia: 4 hilos para barrido rápido en segundo plano
    p_cutoff_time       => '06:00:00'::TIME, -- Freno de emergencia: Detener si llega a las 6:00 AM
    p_verbose           => FALSE,            -- Diagnóstico: Desactivado para ejecución silenciosa en Cron
    
    -- UMBRALES INTERMEDIO-CRÍTICO (Tranquilo/Bajo para barrido diario):
    p_threshold_pct     => 5.00,             -- Mínimo de basura porcentual (5% de tuplas muertas)
    p_min_dead_rows     => 5000,             -- Filtro anti-morralla (Ignora tablas con < 5,000 tuplas muertas)
    p_force_dead_rows   => 50000,            -- Bypass de emergencia: Fuerza ejecución si supera 50,000 muertas
    
    p_keep_history      => TRUE              -- Auditoría: Conservar historial en maint.vacuum_tasks
);

```

### 2. 📊 Módulo ANALYZE (Actualización del Optimizador)

Refresca el mapa estadístico del planificador de consultas de PostgreSQL. Valores tranquilos para mantener el optimizador ágil.

```sql
-- Ejecución recomendada: 2 a 3 veces al día o tras cargas masivas (ETLs)
CALL maint.sp_orchestrate_analyze(
    p_scope             => 'SMART_USER',     -- Alcance: Estadísticas de esquemas de usuario
    p_profile           => 'NORMAL',         -- Perfil: Analiza con muestra estándar del sistema
    p_parallel_workers  => 4,                -- Concurrencia: Actualiza 4 tablas de forma simultánea
    p_verbose           => FALSE,            -- Diagnóstico: Silencioso
    
    -- UMBRALES INTERMEDIO-CRÍTICO (Tranquilo/Bajo para planificador fresco):
    p_threshold_pct     => 5.00,             -- Actúa si el 5% de la tabla ha sufrido modificaciones
    p_min_chg_rows      => 1000,             -- Requiere al menos 1,000 cambios reales para actuar
    p_force_chg_rows    => 50000,            -- Bypass: Si cambian 50,000 filas, actualiza de inmediato
    
    p_cutoff_time       => '06:00:00'::TIME, -- Límite horario para no solapar procesos matutinos
    p_keep_history      => TRUE              -- Auditoría: Conservar log de ejecuciones
);

```

### 3. 🌳 Módulo REINDEX (Desfragmentación B-Tree Cero-Bloqueo)

Sanea índices zombis y reconstruye árboles B-Tree en caliente (`CONCURRENTLY`). Flexible pero controlado, dado que no bloquea pero genera un volumen alto de lectura/escritura en disco.

```sql
-- Ejecución recomendada: Fines de semana o madrugadas (ej. Viernes 11:00 PM)
CALL maint.sp_orchestrate_reindex(
    p_scope               => 'ALL_USER',     -- Alcance: Todos los índices de usuario a evaluación
    p_profile             => 'CONCURRENT',   -- Perfil: Reconstrucción online Cero-Bloqueo
    p_parallel_workers    => 2,              -- Seguridad I/O: Limitado a 2 hilos para cuidar el disco
    p_cutoff_time         => '04:00:00'::TIME, -- Freno de emergencia: Abortar si alcanza las 4 AM
    p_verbose             => FALSE,          -- Diagnóstico: Silencioso
    
    -- UMBRALES INTERMEDIO-CRÍTICO (Flexible y Controlado):
    p_frag_pct_threshold  => 40.00,          -- Tolerancia de Fragmentación Foliar: Hasta 40%
    p_bloat_pct_threshold => 20.00,          -- Tolerancia de Bloat (Espacio Vacío): Hasta 20%
    p_bloat_mb_threshold  => 1024.00,        -- Tolerancia Absoluta: 1 GB (1024 MB) de basura en el índice
    p_threshold_operator  => 'OR',           -- Condición: Si rompe CUALQUIERA de las 3 reglas, reindexa
    p_min_index_mb        => 10.00,          -- Descartar evaluación de índices menores a 10 MB
    p_force_frag_pct      => NULL,           -- Bypass directo de fragmentación (Desactivado)
    p_force_bloat_mb      => NULL,           -- Bypass directo de Bloat MB (Desactivado)
    
    p_rebuild_invalid     => TRUE,           -- Zombis: Reconstrucción forzada y prioritaria de índices caídos
    p_keep_history        => TRUE            -- Auditoría: Conservar historial forense
);

```

### 4. 🏥 Módulo VACUUM FULL (Cirugía Mayor Físico-Forense)

El único módulo que aplica bloqueos exclusivos (`AccessExclusiveLock`). Calibrado con umbrales extremadamente restrictivos para que **NUNCA** se ejecute a menos que la tabla represente una amenaza física y sostenida para el servidor.

```sql
-- Ejecución recomendada: 1 vez al mes (Exclusivamente en Ventana de Mantenimiento)
CALL maint.sp_orchestrate_vacuum_full(
    p_scope               => 'ALL_USER',     -- Alcance: Tablas de usuario a evaluación estricta
    p_profile             => 'SMART',        -- Perfil: Basado en histórico de telemetría sostenida
    p_parallel_workers    => 1,              -- Máxima seguridad: 1 solo hilo (Bloqueo Total)
    p_cutoff_time         => '05:00:00'::TIME, -- Límite estricto de finalización para liberar sistema
    p_verbose             => FALSE,          -- Diagnóstico: Silencioso
    
    -- UMBRALES INTERMEDIO-CRÍTICO (Extremo/Agresivo para EVITAR el bloqueo innecesario):
    p_bloat_pct_threshold => 50.00,          -- Exige que la tabla esté inflada al menos un 50%
    p_bloat_mb_threshold  => 5120.00,        -- Exige que la tabla tenga al menos 5 GB recuperables
    p_threshold_operator  => 'AND',          -- DEBE cumplir AMBAS condiciones para aplicar (Súper estricto)
    p_sustained_days      => 10,             -- La anomalía debe persistir 10 días seguidos sin solución
    p_min_table_mb        => 1024.00,        -- Solo evalúa tablas que pesan 1 GB o más
    p_force_bloat_mb      => 20480.00,       -- Bypass de Rescate: Si la tabla tiene 20 GB de bloat, entra de golpe
    p_enable_deep_scan    => FALSE,          -- Desactiva escaneo de bloque lento (Usa aproximación rápida)
    
    p_keep_history        => TRUE            -- Auditoría: Registro obligatorio en maint.vacuum_full_tasks
);

```

---

## 🛡️ Principios de Resiliencia (Zero-Trust & Self-Healing)

1. **Self-Healing (Auto-Sanación):** Si el servidor se apaga abruptamente, la suite detecta los procesos "huérfanos" en la siguiente ejecución, sella la bitácora con el estado `ABORTED_ORPHAN` y reanuda el trabajo limpio.
2. **Validación Forense de Inodos (`relfilenode`):** Las operaciones de reconstrucción física (REINDEX y VACUUM FULL) no confían en el "OK" lógico del motor. Verifican el inodo del sistema de archivos antes y después de la operación. Si el archivo en disco no cambió, la operación se marca como anomalía silenciosa.
3. **RAM Interception:** Inyecta tuning dinámico a los *background workers* (ej. `maintenance_work_mem`) copiando la configuración de la sesión orquestadora de forma segura, reseteando los privilegios al terminar.
4. **Desacoplamiento de Snapshots:** Cero riesgo de bloqueos mutuos (*Deadlocks*). La orquestación libera continuamente los *snapshots* de transacción (`COMMIT;`) para permitir que la Fase 2 de índices concurrentes avance en milisegundos.
 
