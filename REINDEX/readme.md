# 🛡️ pg-csql-reindex

**pg-csql-reindex** es un orquestador de mantenimiento asíncrono, predictivo y con validación físico-forense para bases de datos transaccionales masivas en PostgreSQL. Su objetivo es automatizar la reconstrucción de índices B-Tree, eliminar la fragmentación foliar, recuperar espacio en disco por *bloat* en índices y sanear automáticamente índices zombis/corruptos (`indisvalid = false`) sin intervención humana.

> ⚠️ **ACLARACIÓN CRÍTICA DE SEGURIDAD:**
> Esta herramienta está diseñada **estrictamente para mantenimiento en caliente (Zero-Downtime / Non-Blocking)** mediante `REINDEX INDEX CONCURRENTLY`. **NO APLICA bloqueo exclusivo de tabla (*AccessExclusiveLock*)** sobre las operaciones transaccionales ordinarias. Garantiza que tu aplicación pueda seguir leyendo y escribiendo datos (`SELECT`, `INSERT`, `UPDATE`, `DELETE`) en las tablas asociadas mientras la reconstrucción de índices ocurre asíncronamente en segundo plano.

---

## 🏛️ El Cuarto de Control (Arquitectura de Tablas)

El orquestador no opera a ciegas; está gobernado por 4 tablas maestras en el esquema `maint` que actúan como su memoria transaccional, panel de seguridad y bitácora forense:

```
                      +-------------------+
                      |    maint.jobs     |
                      | (Cabecera Global) |
                      +---------+---------+
                                |
                                | 1:N
                                v
                   +--------------------------+
                   |   maint.reindex_tasks    |
                   |   (Cola Transaccional)   |
                   +------------+-------------+
                                ^
                                |
      +-------------------------+-------------------------+
      |                                                   |
+-----+-------------------+                     +---------+---------+
|  maint.pgstatindex      |                     |   maint.filters   |
| (Telemetría B-Tree)     |                     | (Blacklist/White) |
+-------------------------+                     +-------------------+

```

### 1. `maint.jobs` (La Cabecera Global)

Cada vez que lanzas el orquestador, se crea un registro maestro aquí. Almacena el identificador global del ciclo de trabajo (`job_id`), la acción (`REINDEX`), el PID del proceso orquestador padre, la fotografía inmutable de parámetros de entrada en formato `JSONB`, la cantidad real de índices procesados exitosamente, las estampas de tiempo de inicio/fin y el estado de la orquestación (`RUNNING`, `COMPLETED`, `COMPLETED_WITH_CUTOFF`, `ABORTED_ORPHAN`).

### 2. `maint.reindex_tasks` (La Cola Transaccional)

Es el campo de batalla de nivel de índice. Por cada `Job`, el motor inserta aquí todos los índices candidatos que superaron la evaluación del radar. Registra el milisegundo exacto en que inició y terminó la reconstrucción, la fragmentación foliar evaluada (`frag_pct_evaluado`), el porcentaje de bloat (`bloat_pct_evaluado`), el espacio en KB a recuperar (`bloat_kb_evaluado`), si el índice era zombi (`is_invalid`), el PID del worker asíncrono (`child_pid`), el historial de errores nativos (`error_log`) y las firmas de validación física (`old_relfilenode` vs `new_relfilenode`).

### 3. `maint.pgstatindex` (Telemetría Predictiva B-Tree)

Es la bitácora diaria de escaneo estructural de la salud del árbol B-Tree. Almacena la evaluación realizada por el radar `sp_pgstatindex` sobre cada índice: tamaño en KB, porcentaje de fragmentación foliar (`leaf_fragmentation_pct`), densidad promedio de páginas (`avg_leaf_density_pct`), porcentaje de páginas vacías (`empty_pages_pct`), espacio de bloat estimado en KB y porcentaje (`total_bloat_pct`), indicador de invalidez (`is_invalid`) y la bandera de decisión (`requiere_reindex`).

### 4. `maint.filters` (Panel de Granularidad y Excepciones)

Funciona como el panel de reglas para definir Listas Negras (exclusiones absolutas) o Listas VIP (mantenimiento prioritario por demanda).

**Ejemplos prácticos de configuración de Filtros:**

```sql
-- RESTRICCIÓN (Lista Negra / Escudo Inmune): Evitar que los índices de la tabla 'historico_logs' sean intervenidos por REINDEX
INSERT INTO maint.filters (schema_name, table_name, maintenance_action, is_ignored) 
VALUES ('public', 'historico_logs', 'REINDEX', TRUE)
ON CONFLICT (schema_name, table_name, maintenance_action) DO UPDATE SET is_ignored = EXCLUDED.is_ignored;

-- FORZADO VIP (Lista Blanca / Francotirador Ciego): Obligar a procesar la tabla 'facturas_vip' cuando se use p_profile = 'FORCE_SURGERY'
INSERT INTO maint.filters (schema_name, table_name, maintenance_action, force_maintenance) 
VALUES ('public', 'facturas_vip', 'REINDEX', TRUE)
ON CONFLICT (schema_name, table_name, maintenance_action) DO UPDATE SET force_maintenance = EXCLUDED.force_maintenance;

```

---

## 🎛️ Parámetros Principales de Ejecución

Cuando llamas al orquestador `maint.sp_orchestrate_reindex`, defines su ámbito de cobertura, concurrencia de hilos, ventana de ejecución y los umbrales de la **Santa Trinidad del B-Tree**.

### 🎯 Ámbitos de Cobertura (`p_scope`) y Dependencia de Umbrales

Controla el universo de esquemas e índices que entran al radar de evaluación.

| Valor | Descripción | ¿Evalúa Umbrales de Salud B-Tree? |
| --- | --- | --- |
| **`ALL_USER`** *(Default)* | Revisa todos los índices B-Tree en esquemas de usuario (excluye `pg_catalog`, `information_schema` y `maint`). | ✅ **SÍ** (Evalúa Fragmentación, % Bloat y MB Bloat) |
| **`ALL_SYSTEM_USER`** | Evalúa índices de tablas de usuario y catálogos internos del sistema simultáneamente. | ✅ **SÍ** (Evalúa Fragmentación, % Bloat y MB Bloat) |
| **`ALL_SYSTEM`** | Restringe la evaluación únicamente a los catálogos del motor (`pg_catalog`, `information_schema`). | ✅ **SÍ** (Evalúa Fragmentación, % Bloat y MB Bloat) |
| **`CUSTOM_LIST`** | Procesa **únicamente** las tablas marcadas con `force_maintenance = TRUE` en `maint.filters`. | ❌ **NO** (Si se combina con `p_profile = 'FORCE_SURGERY'`) |

### ⚙️ Perfiles de Mantenimiento (`p_profile`)

A diferencia del mantenimiento de tablas, el módulo de reconstrucción de índices opera bajo dos perfiles quirúrgicos:

| Perfil | Comportamiento Técnico Operativo |
| --- | --- |
| **`CONCURRENT`** *(Default)* | **Modo Inteligente / Cero-Bloqueo:** Dispara primero el radar de telemetría `sp_pgstatindex`, evalúa los umbrales y reconstruye de forma asíncrona mediante `REINDEX INDEX CONCURRENTLY` sin bloquear lecturas ni escrituras en producción. |
| **`FORCE_SURGERY`** | **Modo Francotirador Ciego:** Omite el escaneo del radar de métricas y ejecuta la reconstrucción concurrente de manera inmediata sobre las tablas configuradas en la lista blanca de `maint.filters` (`force_maintenance = TRUE`). Requiere obligatoriamente `p_scope = 'CUSTOM_LIST'`. |

---

## 🚀 Guía de Ejecución Rápida (Deploy & Forget)

La arquitectura es asíncrona y no bloqueante. Utiliza uno de los dos métodos recomendados según tu infraestructura y necesidades operativas:

### MÉTODO 1: Automatización Absoluta Nocturna (Vía `pg_cron`) 🌙

**Compatibilidad:** Soportado en IaaS, On-Premise y Cloud Gestionado (AWS RDS, Aurora, GCP Cloud SQL).

**Recomendación:** Programar en ventanas nocturnas/madrugadas (Ej. 02:00 AM). Si el mantenimiento se prolonga hasta el inicio de la jornada laboral, el parámetro `p_cutoff_time` activará el freno de emergencia y abortará las tareas pendientes limpiamente.

```sql
-- Programa la desfragmentación automática de índices diariamente a las 02:00 AM
SELECT cron.schedule_in_database('vanguard_daily_reindex', '0 2 * * *', 
$$ 
  CALL maint.sp_orchestrate_reindex(
      p_scope               => 'ALL_USER',    -- Alcance ('ALL_USER', 'ALL_SYSTEM_USER', 'ALL_SYSTEM', 'CUSTOM_LIST')
      p_profile             => 'CONCURRENT',  -- Perfil ('CONCURRENT', 'FORCE_SURGERY')
      p_parallel_workers    => 2,             -- Hilos asíncronos paralelos (Rango permitido: 1 a 4)
      p_cutoff_time         => '06:00:00'::TIME, -- Hora límite / Kill-Switch (06:00 AM)
      p_verbose             => FALSE,         -- Diagnóstico en consola
      p_frag_pct_threshold  => 40.00,         -- Umbral de fragmentación foliar (>= 40%)
      p_bloat_pct_threshold => 20.00,         -- Umbral de % de espacio libre de bloat (>= 20%)
      p_bloat_mb_threshold  => 1024.00,       -- Umbral de bloat absoluto en MB (>= 1024 MB)
      p_threshold_operator  => 'OR',          -- Compuerta lógica ('OR' / 'AND')
      p_min_index_mb        => 10.00,         -- Filtro de tamaño mínimo de índice (10 MB)
      p_force_frag_pct      => NULL,          -- Bypass por fragmentación extrema (NULL = Desactivado)
      p_force_bloat_mb      => NULL,          -- Bypass por tamaño masivo en MB (NULL = Desactivado)
      p_rebuild_invalid     => TRUE,          -- Reconstrucción prioritaria de índices zombis (indisvalid = false)
      p_keep_history        => TRUE           -- Retención de bitácora en reindex_tasks
  );
$$, 
'mi_base_de_datos', 'postgres', true);

```

### MÉTODO 2: El Botón de Pánico Asíncrono Diurno (Vía `pg_background`) ⚡

**Compatibilidad:** Soportado en Servidores Nativos, IaaS, EC2, On-Premise y GCP Cloud SQL / AWS RDS.

**Recomendación:** Intervención de urgencia sobre índices sin congelar la terminal interactiva del DBA.

```sql
-- Lanza el orquestador en segundo plano y regresa el control inmediato de la consola al DBA
SELECT * FROM public.pg_background_launch(
    $$
    CALL maint.sp_orchestrate_reindex(
        p_scope               => 'ALL_USER',
        p_profile             => 'CONCURRENT',
        p_parallel_workers    => 2,
        p_cutoff_time         => NULL,
        p_verbose             => TRUE,
        p_frag_pct_threshold  => 40.00,
        p_bloat_pct_threshold => 20.00,
        p_bloat_mb_threshold  => 1024.00,
        p_threshold_operator  => 'OR',
        p_min_index_mb        => 10.00,
        p_force_frag_pct      => NULL,
        p_force_bloat_mb      => NULL,
        p_rebuild_invalid     => TRUE,
        p_keep_history        => TRUE
    );
    $$
);

-- La llamada devolverá un PID de fondo (Ej. 1089201). Para revisar el log de salida al finalizar:
-- SELECT * FROM public.pg_background_result(1089201) AS (result TEXT);

```

---

## ⚡ Optimización Avanzada: Tuning de Sesión Dinámico (RAM Interception)

El orquestador `pg-csql-reindex` integra un **Interceptor Dinámico de Recursos de Sesión**. Detecta si modificaste parámetros de memoria o paralelismo en tu sesión interactiva mediante comandos `SET` y los transfiere a nivel de rol (`ALTER ROLE ... SET`) garantizando que los *workers* en segundo plano (`pg_background`) hereden el tuning de memoria. Al finalizar toda la orquestación, el procedimiento restablece limpiamente la configuración original (`ALTER ROLE ... RESET`).

#### Parámetros Soportados para Tuning de Sesión:

* `maintenance_work_mem`: Asigna memoria RAM masiva para acelerar la ordenación e inversión de claves de los índices B-Tree en RAM.
* `max_parallel_maintenance_workers`: Define los hilos paralelos nativos por cada instrucción de índice.

#### Ejemplo de Ejecución Acelerada:

```sql
-- 1. Asigna recursos acelerados en tu sesión interactiva
SET maintenance_work_mem = '2GB';
SET max_parallel_maintenance_workers = 4;

-- 2. Lanza el orquestador (Los workers heredan los 2GB de RAM por hilo automáticamente)
CALL maint.sp_orchestrate_reindex(
    p_scope            => 'ALL_USER',
    p_profile          => 'CONCURRENT',
    p_parallel_workers => 2,
    p_verbose          => TRUE
);

-- 3. Al concluir la orquestación, el motor resetea la configuración del ROL automáticamente.

```

---

> ⚠️ **ADVERTENCIA CRÍTICA DE RECURSOS (RAM & I/O):**
> * **Límite Estricto de Seguridad en Hilos (`p_parallel_workers`):** El parámetro `p_parallel_workers` está restringido internamente a un rango obligatorio de **1 a 4 hilos paralelos**. Configurar más de 4 hilos en operaciones concurrentes de índices provocará saturación de ancho de banda de I/O en la controladora de disco.
> * **Riesgo de Agotamiento de Memoria (OOM Killer):** Recuerda que `maintenance_work_mem` se multiplica por la cantidad de hilos en ejecución. Si configuras `maintenance_work_mem = '2GB'` y ejecutas con `p_parallel_workers => 4`, el servidor consumirá hasta **8 GB de RAM real dedicada únicamente a la reconstrucción de índices**. Asegúrate de que el servidor disponga de memoria libre para no activar el *Out-Of-Memory (OOM) Killer* de Linux.
> 
> 

---

## 🎛️ Diccionario de Parámetros: `maint.sp_orchestrate_reindex`

| Parámetro | Tipo | Default | Descripción y Uso Operativo |
| --- | --- | --- | --- |
| `p_scope` | `VARCHAR` | `'ALL_USER'` | **Ámbito de Cobertura.** Define el universo de índices a evaluar. Valores: `'ALL_USER'`, `'ALL_SYSTEM_USER'`, `'ALL_SYSTEM'`, `'CUSTOM_LIST'`. |
| `p_profile` | `VARCHAR` | `'CONCURRENT'` | **Perfil Operativo.** Define la modalidad de mantenimiento. Valores: `'CONCURRENT'` (Evaluación inteligente y ejecuciones no bloqueantes) y `'FORCE_SURGERY'` (Mantenimiento quirúrgico sobre la lista blanca de `maint.filters`). |
| `p_parallel_workers` | `INT` | `2` | **Nivel de Concurrencia de Hilos.** Define cuántos índices se reconstruirán de manera simultánea en segundo plano. **Rango permitido de seguridad: 1 a 4 hilos.** |
| `p_cutoff_time` | `TIME` | `NULL` | **Freno de Emergencia (Kill Switch).** Fija una hora límite (Ej. `'06:00:00'::TIME`). Si la hora actual del servidor alcanza este límite, la orquestación aborta la cola pendiente marcándola como `SKIPPED_TIME_LIMIT` para no invadir el horario productivo. |
| `p_verbose` | `BOOLEAN` | `FALSE` | **Modo Diagnóstico.** Imprime eventos en consola (`INFO`, `WARNING`, `NOTICE`) detallando PIDs de trabajadores, nodos físicos (`relfilenode`), porcentajes de fragmentación y avances en tiempo real. |
| `p_frag_pct_threshold` | `NUMERIC` | `40.00` | **Umbral de Fragmentación Foliar (%).** Porcentaje mínimo de deshojado o desorden en las páginas foliares B-Tree para requerir mantenimiento. |
| `p_bloat_pct_threshold` | `NUMERIC` | `20.00` | **Umbral de Porcentaje de Bloat (%).** Porcentaje mínimo de espacio libre/recuperable (`100 - avg_leaf_density`) en las páginas del índice. |
| `p_bloat_mb_threshold` | `NUMERIC` | `1024.00` | **Umbral de Bloat Absoluto (MB).** Tamaño físico mínimo en Megabytes desperdiciados en disco para requerir reconstrucción. |
| `p_threshold_operator` | `VARCHAR` | `'OR'` | **Compuerta Lógica de Evaluación.** Operador para combinar la Fragmentación y el Bloat. Valores: `'OR'` (Sensible) o `'AND'` (Estricto). |
| `p_min_index_mb` | `NUMERIC` | `10.00` | **Filtro de Tamaño Mínimo (MB).** Omite la evaluación de índices menores a este tamaño en MB para ahorrar ciclos de CPU en el radar. |
| `p_force_frag_pct` | `NUMERIC` | `NULL` | **Bypass Directo por Fragmentación.** Si el índice supera este porcentaje, ingresa a la cola omitiendo las reglas de Bloat. (`NULL` = Desactivado). |
| `p_force_bloat_mb` | `NUMERIC` | `NULL` | **Bypass Directo por Tamaño Masivo.** Si el bloat en MB supera este valor, ingresa a la cola por rescate de almacenamiento directo. (`NULL` = Desactivado). |
| `p_rebuild_invalid` | `BOOLEAN` | `TRUE` | **Saneamiento Automático de Zombis.** Si es `TRUE`, asigna prioridad máxima y obliga la reconstrucción de índices marcados como inválidos (`indisvalid = false`). |
| `p_keep_history` | `BOOLEAN` | `TRUE` | **Retención de Bitácora.** Si es `TRUE`, conserva el registro de tareas en `maint.reindex_tasks`. En `FALSE`, limpia la cola al terminar la orquestación. |

---

## 📊 MATRIZ DE ESTADOS PARA EL MÓDULO `REINDEX`

### 1. Para la Tabla Cabecera Maestra (`maint.jobs`):

* **`RUNNING`**: El orquestador principal (Job Padre) se encuentra activo, despachando o monitoreando trabajadores de `REINDEX CONCURRENTLY`.
* **`COMPLETED`**: El orquestador concluyó todo el ciclo de trabajo de forma exitosa. Procesa todas las tareas pendientes o confirma que ningún índice requirió mantenimiento.
* **`COMPLETED_WITH_CUTOFF`**: El orquestador alcanzó la hora límite (`p_cutoff_time`). Interrumpió el despacho de nuevas tareas, esperó a que terminaran los trabajadores activos y cerró la sesión de manera segura.
* **`ABORTED_ORPHAN`**: El proceso orquestador sufrió una interrupción abrupta (caída de sesión, reinicio de servidor, detención del backend). El mecanismo de *Self-Healing* detectó la ausencia del PID orquestador en la ejecución posterior y selló el Job de forma forense.

### 2. Para la Cola de Tareas Hijas (`maint.reindex_tasks`):

* **`PENDING`**: El índice fue seleccionado por el radar o por la lista blanca y aguarda en la cola la asignación de un trabajador disponible.
* **`RUNNING`**: El índice está siendo reconstruido en tiempo real por un trabajador en segundo plano (`pg_background`). El campo `child_pid` almacena la identificación del trabajador activo.
* **`SUCCESS`**: El trabajador ejecutó la instrucción `REINDEX INDEX CONCURRENTLY` exitosamente. El recolector forense confirmó que la firma física en disco cambió (`old_relfilenode != new_relfilenode`).
* **`FAILED`**: La reconstrucción del índice falló a nivel del motor SQL (ejemplo: falta de memoria, cancelación de consulta por tiempo de espera). El mensaje de error nativo queda grabado en `error_log`.
* **`FAILED_SILENT_ANOMALY`**: El motor SQL retornó éxito en la ejecución, pero el recolector forense detectó que el inodo del archivo en disco no cambió (`old_relfilenode = new_relfilenode`). La tarea se marca como anomalía física silenciosa.
* **`SKIPPED_TIME_LIMIT`**: La tarea permanecía en estado `PENDING` cuando el orquestador activó el freno de emergencia por hora límite (`p_cutoff_time`).
* **`ABORTED_ORPHAN`**: La tarea quedó congelada en estado `RUNNING` debido a la muerte del proceso Padre, y fue sellada por el procedimiento de *Self-Healing* en la siguiente ejecución.
