 

# 🛡️ pg-csql-vacuum

 

**pg-csql-vacuum** es un orquestador de mantenimiento asíncrono y predictivo para bases de datos transaccionales masivas. Diseñado para automatizar la limpieza de *bloat* (basura), refrescar estadísticas y ejecutar reestructuraciones físicas quirúrgicas.

## 🥊 Cuadro Comparativo: ¿Por qué usar pg-csql-vacuum?

La industria suele apoyarse en herramientas externas para combatir la fragmentación, pero exigen modificar tu esquema o compilar binarios de terceros. Así nos comparamos con los líderes del mercado:

| Característica / Herramienta | `pg-csql-vacuum` 🛡️ | `pg_repack` 📦 | `pg_squeeze` 🗜️ |
| --- | --- | --- | --- |
| **Requiere Primary Key (PK)** | **NO** (Trabaja con cualquier esquema) | SÍ (Falla si la tabla no tiene PK/UK) | SÍ (Dependencia de PK o REPLICA IDENTITY) |
| **Dependencia de Binarios** | **NO** (Usa extensiones nativas `pg_background`, `pgstattuple`) | SÍ (Requiere compilar en el SO Linux) | SÍ (Requiere binarios externos y decoding) |
| **Nivel de Bloqueo** | **AccessExclusiveLock** (Solo en modo FULL) | AccessExclusiveLock (Breve al final) | AccessExclusiveLock (Breve al final) |
| **Triage Predictivo** | **SÍ** (Calcula matemáticamente si vale la pena) | NO (Repaca a ciegas lo que le pidas) | NO (Depende de triggers o peticiones manuales) |
| **Orquestador Asíncrono** | **SÍ** (Auto-gestionado, multi-hilo en Postgres) | NO (Requiere scripts Bash externos) | NO (Ejecución dependiente del cliente) |
| **Caso de Uso Ideal** | **Ventanas de mantenimiento (Noches/Fines de semana)** | Bases de datos 24/7 sin ventanas | Bases de datos 24/7 sin ventanas |

### 💡 Hablemos claro: La Ventaja y la Desventaja

**La Desventaja (Seamos honestos):** A diferencia de `pg_repack`, nuestra reconstrucción física profunda (`VACUUM FULL`) **bloquea la tabla exclusiva y temporalmente**. No puedes escribir ni leer mientras se reconstruye.
**La Ventaja (El Valor Real):** No te obligamos a alterar tu modelo de datos agregando Primary Keys a tablas *legacy*, ni corres riesgos compilando código C externo en tus servidores. Además, **no bloqueamos a lo loco**: gracias a nuestro Triage, la herramienta solo ejecuta el bloqueo exclusivo si demuestra matemáticamente que vas a recuperar Gigabytes de espacio. Es la herramienta perfecta para organizaciones que sí cuentan con **ventanas de mantenimiento nocturnas o de fin de semana** y buscan una automatización a prueba de fallos.

---
 
### 🎯 1. Ámbitos de Cobertura (`p_scope`)

Controla qué tablas del catálogo serán evaluadas para entrar en la cola de trabajo:

| Valor de `p_scope` | Descripción y Alcance |
| --- | --- |
| **`'SMART_USER'`** *(Default)* | **Esquemas de Usuario:** Aplica filtros inteligentes de *bloat* (tuplas muertas/porcentaje) ignorando catálogos del sistema (`pg_catalog`, `information_schema`). |
| **`'ALL_USER'`** | **Esquemas de Usuario (Forzado):** Selecciona todas las tablas de usuario sin importar si cumplen o no los umbrales de tuplas muertas (útil para mantenimientos globales programados). |
| **`'CUSTOM_LIST'`** | **Lista VIP Exclusiva:** Solo procesa las tablas que tengan el indicador `force_maintenance = TRUE` en la tabla de control `public.maintenance_filters`. |
| **`'SMART_SYSTEM_USER'`** | **Usuario + Sistema (Inteligente):** Incluye tanto tablas de usuario como catálogos del sistema bajo filtros de umbral de tuplas muertas. |
| **`'ALL_SYSTEM_USER'`** | **Usuario + Sistema (Todos):** Incluye absolutamente todas las tablas de usuario y del sistema sin filtrar por volumen de basura. |
| **`'ALL_SYSTEM'`** | **Solo Catálogos del Sistema:** Limita la ejecución exclusivamente a los esquemas de sistema (`pg_catalog` e `information_schema`). |

---

### ⚙️ 2. Perfiles de Mantenimiento (`p_profile`)

Define el comando SQL exacto que se inyectará asíncronamente a los *workers* y el nivel de concurrencia asignado:

| Valor de `p_profile` | Sintaxis SQL Generada | Comportamiento y Uso |
| --- | --- | --- |
| **`'LIGHT'`** | `VACUUM (SKIP_LOCKED ON, INDEX_CLEANUP OFF) schema.table;` | **No bloqueante:** Salta tablas bloqueadas y omite limpieza de índices. Ideal para horas pico. |
| **`'BALANCED'`** *(Default)* | `VACUUM (INDEX_CLEANUP AUTO) schema.table;` | **Mantenimiento estándar:** Limpieza equilibrada de tuplas e índices sin saturar I/O. |
| **`'AGGRESSIVE'`** | `VACUUM (INDEX_CLEANUP AUTO, PARALLEL 4, ANALYZE) schema.table;` | **Mantenimiento profundo:** Usa 4 hilos paralelos por tabla y actualiza estadísticas (`ANALYZE`). |


---


## 💻 Ejemplos de Uso Recomendados

### Escenario 1: Mantenimiento Diario de Rutina (Sin impacto operativo)

Ideal para ejecutarse todas las noches. Limpia tuplas muertas sin bloquear tablas y usa pocos recursos para no afectar transacciones nocturnas.

```sql
-- Mantenimiento ligero/balanceado diario sobre tablas de usuario
CALL public.sp_orchestrate_vacuum(
    p_scope => 'SMART_USER',
    p_profile => 'BALANCED',
    p_parallel_workers => 2,
    p_threshold_pct => 0.05
);

```

---

### Escenario 2: Ventana de Mantenimiento Crítica de Fin de Semana (Triage + Smart Vacuum Full)

Para ejecutar una reestructuración física profunda (`VACUUM FULL`) de forma segura en bases de datos de misión crítica (VLDBs), se debe seguir el flujo en 2 pasos dentro de la ventana de tiempo (ej. Sábados de 01:00 AM a 05:00 AM):

```sql
-- =====================================================================
-- PASO 1: EL RECOLECTOR / RADAR (Se ejecuta 1-2 horas antes)
-- Escanea la base de datos y llena la tabla 'vacuum_full_triage'
-- =====================================================================
CALL public.sp_populate_vacuum_triage(
    p_scope => 'ALL_USER', 
    p_free_pct_threshold => 15.00,  -- Marcará tablas con >15% de espacio libre interno
    p_free_mb_threshold => 1024.00,  -- O con >1 GB de espacio libre absoluto
    p_min_table_mb => 100.00,        -- Ignora tablas menores a 100 MB
    p_verbose => TRUE
);

-- =====================================================================
-- PASO 2: TUNING DINÁMICO DE FUERZA BRUTA (Solo dura esta sesión)
-- =====================================================================
SET maintenance_work_mem = '4GB';           -- Asigna RAM masiva para acelerar índices
SET vacuum_cost_delay = 0;                  -- Quita el freno de disco para máxima I/O
SET max_parallel_maintenance_workers = 8;   -- Exprime los núcleos de CPU disponibles
SET wal_compression = on;                   -- Comprime WALs para no asfixiar la red de las réplicas

-- =====================================================================
-- PASO 3: EL ORQUESTADOR SMART (Cirugía Física Inteligente)
-- Consume los datos recolectados en el Paso 1 para actuar quirúrgicamente
-- =====================================================================
CALL public.sp_orchestrate_vacuum(
    p_scope => 'SMART_USER',
    p_profile => 'SMART_VACUUM_FULL', 
    p_parallel_workers => 1,              -- Importante: 1 hilo para evitar contención de I/O en FULL
    p_threshold_pct => 0.15,              -- Filtra tablas que tengan >= 15% en deep_free_percent
    p_cutoff_time => '05:00:00'::TIME,    -- [KILL SWITCH] Aborta si la hora cruza las 05:00 AM
    p_verbose => TRUE
);

-- =====================================================================
-- PASO 4: LIMPIEZA DE SESIÓN (Opcional)
-- =====================================================================
RESET maintenance_work_mem;
RESET vacuum_cost_delay;

```

---

### Escenario 3: Mantenimiento VIP Relámpago (CUSTOM_LIST)

Si necesitas ejecutar mantenimiento agresivo únicamente sobre una lista específica de tablas críticas durante una ventana corta de 15 minutos:

```sql
-- 1. Marcar la tabla en el panel de seguridad (Pase VIP)
UPDATE public.maintenance_filters 
SET force_maintenance = TRUE 
WHERE schema_name = 'public' AND table_name = 'facturas_mes_activo';

-- 2. Ejecutar el orquestador en modo CUSTOM_LIST
CALL public.sp_orchestrate_vacuum(
    p_scope => 'CUSTOM_LIST',
    p_profile => 'AGGRESSIVE',
    p_parallel_workers => 4,
    p_verbose => TRUE
);

```

---



#### 2. Modos Ejecuta y Suelta


**MÉTODO 1: EL FANTASMA MANUAL (Vía pg_background_launch)**
```sql
SELECT * FROM public.pg_background_launch(
    $$
      CALL maint.sp_orchestrate_vacuum(
          p_scope            => 'ALL_USER',       -- Alcance: Esquemas de usuario. No aplica a esquemas del sistema ('pg_catalog') ni TOAST.
          p_profile          => 'BALANCED',       -- Perfil diario sin bloqueos. Aplica para mantenimiento rutinario; no aplica para reescribir tablas en disco (usar 'SMART_VACUUM_FULL').
          p_parallel_workers => 8,                -- 8 hilos en paralelo. Aplica en perfiles normales; inactivo en 'VACUUM_FULL' (el motor lo fuerza automáticamente a 1 hilo).
          p_threshold_pct    => 0.05,             -- Umbral del 5% de basura. Aplica para encolar la tabla; no aplica en 'SMART_VACUUM_FULL' (ahí evalúa % de espacio libre en disco).
          p_min_dead_tup     => 5000,             -- Mínimo 5,000 tuplas muertas. Aplica en modo 'SMART' para omitir tablas chicas; no aplica en alcances masivos no-SMART.
          p_cutoff_time      => '05:55:00'::TIME, -- [KILL SWITCH]: Freno a las 05:55 AM. Aplica para no invadir el horario laboral; no aplica si se coloca en NULL (sin límite de tiempo).
          p_verbose          => FALSE             -- Modo silencioso. Aplica en cronjobs de producción; usar TRUE solo para depuración manual en terminal.
      );
    $$
);

select * FROM public.pg_background_result(2102986)  AS (result TEXT);
```

**MÉTODO 2: LA AUTOMATIZACIÓN ABSOLUTA (Vía pg_cron)**
```SQL
-- Programa el orquestador para que despierte todos los días a las 02:00 AM
SELECT cron.schedule_in_database(
    'vanguard_smart_analyze_daily', 
    '0 2 * * *', 
    $$ 
    CALL maint.sp_orchestrate_analyze(
        p_job_type         => 'SMART', 
        p_parallel_workers => 4, 
        p_verbose          => FALSE, 
        p_threshold_pct    => 0.05, 
        p_min_rows         => 1000,
        p_cutoff_time      => '06:00:00'::TIME
    ); 
    $$,
    'mi_base_de_datos', 
    'postgres', 
    true
);
```

