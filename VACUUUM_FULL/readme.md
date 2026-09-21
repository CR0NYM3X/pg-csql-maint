
# 🛡️ pg-csql-vacuum-full

**pg-csql-vacuum-full** es una suite de orquestación asíncrona, quirúrgica y con verificación forense diseñada para la reescritura física de tablas con degradación severa (*bloat*) en PostgreSQL. Su objetivo principal es recuperar espacio real en disco mediante cirugía mayor, manteniendo control estricto sobre el impacto de I/O y asegurando una trazabilidad completa mediante validación de checksum físico (`relfilenode`).

> ⚠️ **ADVERTENCIA CRÍTICA DE OPERACIÓN Y BLOQUEOS:**
> A diferencia del mantenimiento ordinario (`VACUUM` / `ANALYZE`), el procedimiento `VACUUM FULL` ejecuta una reescritura física completa de la tabla en disco y solicita un bloqueo exclusivo pesado (**`AccessExclusiveLock`**).
> * **Bloqueo Total:** Durante la cirugía de una tabla, se **bloquean temporalmente todas las lecturas y escrituras (`SELECT`, `INSERT`, `UPDATE`, `DELETE`)** sobre esa tabla específica.
> * **Requisito de Espacio:** La reescritura crea una copia temporal del archivo en disco; por ende, debes contar con espacio libre suficiente en el sistema de archivos equivalente al tamaño de la tabla a intervenir.
> * **Control de I/O:** Para evitar colapsar la controladora de almacenamiento, la concurrencia máxima del orquestador está limitada estrictamente entre **1 y 2 hilos paralelos**.

---

## 🏛️ El Cuarto de Control (Arquitectura de Tablas)

El módulo opera bajo el esquema `maint` utilizando 4 estructuras maestras que gestionan la memoria, las reglas de protección y el historial de telemetría:

 
```
                  +-------------------+
                  |    maint.jobs     |
                  | (Cabecera Global) |
                  +---------+---------+
                            |
                            | 1:N
                            v
               +--------------------------+
               | maint.vacuum_full_tasks  |
               |   (Cola Transaccional)   |
               +------------+-------------+
                            ^
                            |
  +-------------------------+-------------------------+
  |                                                   |
+-----+-------------------+                     +---------+---------+
|   maint.pgstattuple     |                     |   maint.filters   |
| (Telemetría Histórica)  |                     | (Blacklist/White) |
+-------------------------+                     +-------------------+

```

### 1. `maint.jobs` (La Cabecera Maestra Unificada)

Registra la ejecución global de cada ciclo de trabajo. Almacena el ID del trabajo (`job_id`), el tipo de alcance (`job_type`), la acción (`VACUUM_FULL`), el PID del proceso orquestador principal, los parámetros de ejecución en formato `JSONB` inmutable, las tablas procesadas con éxito y el estado final (`RUNNING`, `COMPLETED`, `COMPLETED_WITH_CUTOFF`, `ABORTED_ORPHAN`).

### 2. `maint.vacuum_full_tasks` (La Cola Transaccional y Bitácora Forense)

Almacena el detalle individual de cada tabla encolada para cirugía mayor. Registra las métricas evaluadas al momento de entrar a la cola (`bloat_pct`, `bloat_kb`), los días de degradación sostenida cumplidos (`sustained_days_met`), el PID del trabajador asíncrono (`child_pid`), el registro de errores (`error_log`) y los **inodos físicos de archivo** (`old_relfilenode` vs `new_relfilenode`).

### 3. `maint.pgstattuple` (Histórico Diario de Telemetría Física)

Guarda el registro acumulado de escaneos de tuplas y espacio libre a nivel de Kilobytes (`total_bloat_kb` y `total_bloat_pct`), independientemente de `autovacuum`. Soporta escaneos aproximados de alta velocidad (`pgstattuple_approx`) y escaneos profundos bloque a bloque (`pgstattuple`). La columna `requires_vf` indica si la tabla superó los umbrales configurados en una fecha dada.

### 4. `maint.filters` (Panel de Control y Reglas de Excepción)

Permite definir excepciones de seguridad (Listas Negras) o autorizaciones directas (Listas Blancas/VIP):

```sql
INSERT INTO maint.filters (
    schema_name, 
    table_name, 
    maintenance_action, 
    filter_type, 
    action_params
) VALUES 
-- [REGLA 1 - EXCLUSIÓN ABSOLUTA]: Intocable. Jamás entra a mantenimiento ni genera telemetría.
('lab', 'demo_extreme_bloat', 'VACUUM_FULL', 'EXCLUDE', NULL),

-- [REGLA 2 - FUERZA BRUTA / OVERRIDE]: Entra directamente a la cola ignorando todo cálculo.
('lab', 'demo_vip_facturas', 'VACUUM_FULL', 'FORCE', NULL),

-- [REGLA 3 - UMBRAL ESPECÍFICO JSONB]: Carga el 100% de los parámetros de tabla homologados.
('lab', 'demo_heavy_updates', 'VACUUM_FULL', 'CUSTOM', '{"bloat_pct_threshold":15.0,"bloat_mb_threshold":100.0,"threshold_operator":"AND","sustained_days":3,"force_bloat_mb":500.0}'::jsonb)
```

---

### 🎯 **COMPORTAMIENTO `p_scope` PARA `sp_orchestrate_vacuum_full**`

A diferencia de otros módulos de mantenimiento, `VACUUM FULL` ejecuta el **Radar de Triage (`sp_pgstattuple`)** y la **Evaluación del Histórico (`sustained_days`)** para decidir de forma inteligente si una tabla requiere o no reescritura física.

A continuación se presenta la matriz de comportamiento oficial del orquestador para `VACUUM FULL`:

| `p_scope` | `filter_type = 'EXCLUDE'` | `filter_type = 'FORCE'` | `filter_type = 'CUSTOM'` + JSONB | Tablas no registradas en `maint.filters` |
| --- | --- | --- | --- | --- |
| **`CUSTOM_LIST`** | 🚫 **NUNCA entra** | ⚡ **Entra DIRECTO** *(Fuerza Bruta)* | 🎯 **Evalúa parámetros JSONB** *(O parámetros globales si JSONB es NULL)* | ❌ **Ignorada** *(Solo procesa las registradas)* |
| **`SMART_USER`** *(Default)* | 🚫 **NUNCA entra** | ⚡ **Entra DIRECTO** *(Fuerza Bruta)* | 🎯 **Evalúa parámetros JSONB** *(Sobre esquemas de usuario)* | 📊 **Evalúa parámetros globales + Radar** *(Solo esquemas de usuario)* |
| **`SMART_SYSTEM`** | 🚫 **NUNCA entra** | ⚡ **Entra DIRECTO** *(Fuerza Bruta)* | 🎯 **Evalúa parámetros JSONB** *(Sobre catalogos del sistema)* | 📊 **Evalúa parámetros globales + Radar** *(Solo catalogos `pg_catalog`/`information_schema`)* |
| **`SMART_SYSTEM_USER`** | 🚫 **NUNCA entra** | ⚡ **Entra DIRECTO** *(Fuerza Bruta)* | 🎯 **Evalúa parámetros JSONB** *(Sobre toda la base de datos)* | 📊 **Evalúa parámetros globales + Radar** *(Toda la base de datos)* |

---

### 📌 **NOTAS DE INGENIERÍA SOBRE LA MATRIZ DE `VACUUM FULL**`

1. **Ausencia de modos `ALL_*` en `sp_orchestrate_vacuum_full`:**
En la suite **VANGUARD BLACK-OPS**, el procedimiento `VACUUM FULL` no expone ámbitos ciegos de fuerza bruta global (como `ALL_USER` o `ALL_SYSTEM`) por motivos de **seguridad extrema de I/O y bloqueo exclusivo (`AccessExclusiveLock`)**. Si se requiere forzar la cirugía masiva sobre tablas específicas sin pasar por el radar, se debe utilizar `p_scope = 'CUSTOM_LIST'` registrando las tablas objetivo con `filter_type = 'FORCE'` o compilar una lista limpia en `maint.filters`.
2. **Diferencia entre `EXCLUDE` y `CUSTOM` con umbrales altos:**
* **`EXCLUDE`:** Descarte absoluto. La tabla es omitida por el radar; **no genera registros diarios en `maint.pgstattuple**`.
* **`CUSTOM` con umbrales inalcanzables:** Mantiene la observabilidad. La tabla **sí genera telemetría diaria en `maint.pgstattuple**`, pero el orquestador nunca activará la reescritura física.


 


### ⚙️ Perfiles de Ejecución (`p_profile`)

| Perfil | Comportamiento Técnico Operativo |
| --- | --- |
| **`SMART`** *(Default)* | **Modo Predictivo e Histórico:** Ejecuta el radar `sp_pgstattuple` para refrescar telemetría. Valida que la tabla haya superado los umbrales de *bloat* de forma ininterrumpida durante los últimos `p_sustained_days` días antes de encolarla. |
| **`FORCE_SURGERY`** | **Modo Cirugía Ciega / Francotirador:** Omite la validación de días históricos e interviene de inmediato las tablas configuradas en `maint.filters` con `force_maintenance = TRUE`. Requiere obligatoriamente `p_scope = 'CUSTOM_LIST'`. |

---

## 🚀 Guía de Ejecución Rápida (Deploy & Forget)

Debido al uso de `AccessExclusiveLock`, la ejecución debe programarse en ventanas de mantenimiento nocturnas o durante horas de bajo tráfico en producción.

### MÉTODO 1: Programación Nocturna Automatizada (Vía `pg_cron`) 🌙

```sql
-- [CRON JOB]: Revisión y cirugía mayor nocturna programada a las 01:00 AM
SELECT cron.schedule_in_database(
    'vanguard_daily_vacuum_full',
    '0 1 * * *',
    $$
    CALL maint.sp_orchestrate_vacuum_full(
        p_scope                 => 'SMART_USER',     -- 'SMART_USER', 'SMART_SYSTEM_USER', 'SMART_SYSTEM', 'CUSTOM_LIST'
        p_profile               => 'SMART',          -- 'SMART' (Radar+Histórico) o 'FORCE_SURGERY' (Ciego)
        p_parallel_workers      => 1,                -- Hilos paralelos (Tope dinámico según maint.config)
        p_cutoff_time           => '05:00:00'::TIME, -- Hora límite / Kill-Switch (05:00 AM)
        p_kill_active_on_cutoff => TRUE,             -- Cancelación/Terminación activa al alcanzar el cutoff
        p_verbose               => FALSE,            -- Salida de diagnóstico en consola
        p_bloat_pct_threshold   => 25.00,            -- Umbral de porcentaje de bloat (>= 25%)
        p_bloat_mb_threshold    => 1024.00,          -- Umbral de bloat en MB (>= 1 GB)
        p_threshold_operator    => 'OR',             -- Compuerta lógica ('OR' / 'AND')
        p_sustained_days        => 5,                -- Días consecutivos requeridos en el radar
        p_min_table_mb          => 50.00,            -- Tamaño mínimo de tabla a evaluar (>= 50 MB)
        p_force_bloat_mb        => NULL,             -- Bypass por tamaño en MB (NULL = Desactivado)
        p_enable_deep_scan      => FALSE,            -- Escaneo profundo bloque a bloque (FALSE = Aprox)
        p_keep_history          => TRUE              -- Retención de auditoría en vacuum_full_tasks
    );
    $$,
    'mi_base_de_datos',
    'postgres',
    TRUE
);
```

### MÉTODO 2: Ejecución Asíncrona bajo Demanda (Vía `pg_background`) ⚡

```sql
-- [EJECUCIÓN MANUAL ASÍNCRONA]: Invocación vía pg_background
SELECT * FROM public.pg_background_launch(
    $$
    CALL maint.sp_orchestrate_vacuum_full(
        p_scope                 => 'SMART_USER',
        p_profile               => 'SMART',
        p_parallel_workers      => 1,
        p_cutoff_time           => NULL,             -- Sin hora límite
        p_kill_active_on_cutoff => FALSE,
        p_verbose               => TRUE,             -- Diagnóstico detallado en logs
        p_bloat_pct_threshold   => 25.00,
        p_bloat_mb_threshold    => 1024.00,
        p_threshold_operator    => 'OR',
        p_sustained_days        => 5,
        p_min_table_mb          => 50.00,
        p_force_bloat_mb        => 5000.00,          -- Bypass de emergencia: Tablas con >= 5 GB de bloat entran directo
        p_enable_deep_scan      => FALSE,
        p_keep_history          => TRUE
    );
    $$
);

-- Para obtener el resultado del proceso hijo mediante el PID devuelto:
-- SELECT * FROM public.pg_background_result(PID_OBTENIDO) AS (result TEXT);
```

---

## 🔬 Verificación Forense por Checksum de Inodo (`relfilenode`)

Para certificar que la cirugía física ocurrió correctamente en el almacenamiento de disco, el orquestador no confía únicamente en la respuesta del comando SQL.

Antes de despachar la tarea, captura el inodo del archivo en disco (`old_relfilenode`). Al finalizar, consulta nuevamente `pg_class.relfilenode` (`new_relfilenode`):

* **`SUCCESS`**: Se confirma cuando `old_relfilenode != new_relfilenode`, garantizando que PostgreSQL reescribió la tabla en un nuevo archivo físico de almacenamiento y liberó las páginas viejas al sistema operativo.
* **`FAILED_SILENT_ANOMALY`**: Si el motor retorna éxito pero el inodo no cambió (`old_relfilenode = new_relfilenode`), la tarea se cataloga como anomalía silenciosa y se registra en el historial para auditoría.

```sql
-- Consulta de verificación forense de firmas en disco
SELECT 
    task_id,
    job_id,
    schema_name,
    table_name,
    bloat_pct,
    bloat_kb,
    old_relfilenode AS "Inodo ANTES",
    new_relfilenode AS "Inodo DESPUÉS",
    CASE 
        WHEN old_relfilenode != new_relfilenode THEN '✓ REESCRITURA CONFIRMADA'
        ELSE 'X ANOMALÍA FÍSICA'
    END AS verificacion_checksum,
    status,
    ended_at - started_at AS duracion
FROM maint.vacuum_full_tasks
ORDER BY task_id ASC;

```

---

## 🎛️ Diccionario de Parámetros: `maint.sp_orchestrate_vacuum_full`

| Parámetro | Tipo | Default | Descripción y Uso Operativo |
| --- | --- | --- | --- |
| `p_scope` | `VARCHAR` | `'SMART_USER'` | **Ámbito de Cobertura.** Universo de tablas a evaluar. Valores: `'SMART_USER'`, `'SMART_SYSTEM_USER'`, `'SMART_SYSTEM'`, `'CUSTOM_LIST'`. |
| `p_profile` | `VARCHAR` | `'SMART'` | **Perfil Operativo.** Valores: `'SMART'` (Evaluación por historial de días) y `'FORCE_SURGERY'` (Cirugía directa sobre la lista blanca de `maint.filters`). |
| `p_parallel_workers` | `INT` | `1` | **Concurrencia de Hilos.** Cantidad de tablas a intervenir en paralelo. **Tope estricto de seguridad: 1 a 2 hilos.** |
| `p_cutoff_time` | `TIME` | `NULL` | **Freno de Emergencia (Kill Switch).** Hora límite (Ej. `'05:00:00'::TIME`). Omite tareas pendientes e interrumpe activamente tareas RUNNING (si `p_kill_active_on_cutoff = TRUE`). |
| `p_kill_active_on_cutoff` | `BOOLEAN` | `FALSE` | **Válvula de Aniquilación Activa.** Si es `TRUE` y se alcanza el `p_cutoff_time`, fuerza la cancelación/terminación activa de las tareas en estado `RUNNING` (`pg_cancel_backend` -> `pg_terminate_backend` -> `pg_background_detach`). |
| `p_verbose` | `BOOLEAN` | `FALSE` | **Modo Diagnóstico.** Imprime detalles en tiempo real sobre PIDs, inodos físicos, tiempos y progreso de la cirugía. |
| `p_bloat_pct_threshold` | `NUMERIC` | `25.00` | **Umbral Porcentual de Bloat (%).** Porcentaje mínimo de espacio muerto/libre para requerir cirugía. |
| `p_bloat_mb_threshold` | `NUMERIC` | `1024.00` | **Umbral Absoluto de Bloat (MB).** Espacio mínimo en Megabytes desperdiciados en disco para requerir cirugía. |
| `p_threshold_operator` | `VARCHAR` | `'OR'` | **Compuerta Lógica.** Operador para evaluar el % de bloat y los MB de bloat. Valores: `'OR'` (Sensible) u `'AND'` (Estricto). |
| `p_sustained_days` | `INT` | `5` | **Regla de Días Sostenidos.** Número de días consecutivos en los que la tabla debió marcar `requires_vf = true` en el radar `maint.pgstattuple` para ser encolada. |
| `p_min_table_mb` | `NUMERIC` | `50.00` | **Filtro de Tamaño Mínimo (MB).** Omite tablas pequeñas de menos de X Megabytes. |
| `p_force_bloat_mb` | `NUMERIC` | `NULL` | **Bypass Directo por Tamaño Masivo.** Si el bloat en MB supera este valor, ignora la regla de `p_sustained_days` e ingresa inmediatamente a la cola de cirugía. |
| `p_enable_deep_scan` | `BOOLEAN` | `FALSE` | **Escaneo Profundo.** Si es `TRUE`, usa `pgstattuple` (bloque a bloque) en lugar de `pgstattuple_approx`. |
| `p_keep_history` | `BOOLEAN` | `TRUE` | **Retención de Bitácora.** Si es `TRUE`, mantiene el historial en `maint.vacuum_full_tasks`. En `FALSE`, purga las tareas al finalizar el Job. |

---

## 📊 MATRIZ DE ESTADOS PARA EL MÓDULO `VACUUM FULL`

### 1. Para la Tabla Cabecera Maestra (`maint.jobs`):

* **`RUNNING`**: El orquestador principal (Job Padre) está activo despachando o monitoreando trabajadores de cirugía mayor.
* **`COMPLETED`**: El orquestador concluyó el ciclo de trabajo exitosamente.
* **`COMPLETED_WITH_CUTOFF`**: El orquestador alcanzó la hora límite (`p_cutoff_time`), detuvo el despacho de nuevas tareas, limpió/canceló las activas (si aplicaba) y cerró el Job de forma limpia.
* **`ABORTED_ORPHAN`**: El proceso orquestador principal sufrió una interrupción abrupta (caída de red, término de backend) y fue conciliado por el procedimiento de *Self-Healing* en la siguiente ejecución.

### 2. Para la Cola de Tareas Hijas (`maint.vacuum_full_tasks`):

* **`PENDING`**: La tabla superó las reglas de telemetría o lista blanca y aguarda en la cola la asignación de un trabajador.
* **`RUNNING`**: La tabla está siendo intervenida físicamente por un trabajador asíncrono (`pg_background`). El campo `child_pid` identifica el proceso activo.
* **`SUCCESS`**: La reescritura de la tabla finalizó y el recolector forense confirmó que la firma física en disco cambió (`old_relfilenode != new_relfilenode`).
* **`FAILED`**: La reescritura falló a nivel del motor SQL (ejemplo: falta de espacio en disco, cancelación de consulta). El error nativo queda registrado en `error_log`.
* **`FAILED_SILENT_ANOMALY`**: El comando SQL finalizó sin error, pero el inodo en disco no cambió (`old_relfilenode = new_relfilenode`).
* **`SKIPPED_TIME_LIMIT`**: La tarea permanecía en estado `PENDING` cuando el orquestador activó el freno de emergencia por hora límite (`p_cutoff_time`).
* **`ABORTED_BY_CUTOFF`**: La tarea se encontraba en estado `RUNNING` al momento de alcanzar el `p_cutoff_time` y fue cancelada/terminada activamente por el orquestador debido a la bandera `p_kill_active_on_cutoff = TRUE`.
* **`ABORTED_ORPHAN`**: La tarea quedó congelada en `RUNNING` debido a la muerte del proceso Padre y fue cerrada por el procedimiento de *Self-Healing*.
