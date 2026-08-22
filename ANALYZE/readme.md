
# 🛡️ pg-csql-analyze

## 🛠️ ¿PARA QUÉ SIRVE EL ORQUESTADOR ANALYZE?

Es un **motor de mantenimiento asíncrono y paralelo para PostgreSQL** diseñado para mantener al optimizador de consultas en su punto máximo de rendimiento.

* **Evita la degradación del sistema:** Automatiza el refresco de estadísticas (`ANALYZE`) sin bloquear las transacciones activas de los usuarios ni generar *locks* pesados.
* **Control de recursos de bajo nivel:** Administra pools de hilos concurrentes, elimina procesos zombis automáticamente y permite la recolección de memoria (GC) para jamás saturar la RAM ni el CPU.
* **Trazabilidad Forense Eficiente:** Guarda un historial inmutable de cada intervención (filas afectadas, tiempos de ejecución y porcentaje de desfase `drift_pct`) en tablas de auditoría, con capacidad de purga automática para evitar el *bloat* del propio orquestador.

> ⚠️ **ACLARACIÓN TÁCTICA:**
> A diferencia de `VACUUM`, `ANALYZE` es una operación extremadamente ligera y *Non-Blocking*. Esta herramienta está diseñada para mantener los histogramas del motor actualizados, asegurando que PostgreSQL siempre elija el plan de ejecución más rápido posible.

---

## 🏛️ El Cuarto de Control (Arquitectura de Tablas)

El orquestador no opera a ciegas; está gobernado por 3 tablas maestras que actúan como su memoria y panel de seguridad:

### 1. `maint.jobs` (La Cabecera Global)

Almacena el identificador global del ciclo de trabajo, cuántos hilos paralelos se usaron, la hora de inicio/fin y el estado general (`RUNNING`, `COMPLETED`, `COMPLETED_WITH_CUTOFF`). Es tu vista macro de auditoría operativa.

### 2. `maint.analyze_tasks` (La Cola Transaccional y Auditoría)

Es la memoria operativa en tiempo real. Rastrea el milisegundo exacto en que una tabla empezó a procesarse, qué PID la tomó, su nivel de desfase estadístico y guarda el error nativo (`SQLERRM`) si algo falló. Mediante el parámetro `p_keep_history`, esta tabla puede limpiarse automáticamente tras cada ejecución para ahorrar espacio, o conservarse para análisis forense.

### 3. `maint.filters` (Panel de Granularidad y Excepciones)

Funciona como Lista Negra y Lista VIP. Te permite bloquear o forzar mantenimientos a nivel de tabla con precisión quirúrgica, previniendo análisis innecesarios en tablas congeladas.

**Ejemplos prácticos de configuración de Filtros:**

```sql
-- RESTRICCIÓN (Lista Negra): Evitar que 'historico_logs' sea evaluada por el ANALYZE
INSERT INTO maint.filters (schema_name, table_name, maintenance_action, is_ignored) 
VALUES ('public', 'historico_logs', 'ANALYZE', TRUE);

-- FORZADO VIP (Lista Blanca): Obligar a analizar 'usuarios' siempre, ignorando umbrales
INSERT INTO maint.filters (schema_name, table_name, maintenance_action, force_maintenance) 
VALUES ('public', 'usuarios', 'ANALYZE', TRUE);

```

---

## 🚦 ÁMBITOS DE COBERTURA (`p_scope`)

Controla qué universo de tablas entra a la cola de evaluación. Los parámetros de control de volatilidad (`p_threshold_pct` y `p_min_rows`) solo son respetados por los alcances inteligentes (`SMART`).

| Valor | Descripción | ¿Evalúa Umbrales (Volatilidad)? |
| --- | --- | --- |
| **`SMART_USER`** *(Default)* | Mantenimiento Quirúrgico Diario. Solo procesa tablas de usuario que crucen los umbrales de modificaciones. | ✅ **SÍ** |
| **`ALL_USER`** | Ejecuta sobre todas las tablas de usuario, ignorando si sufrieron cambios. | ❌ **NO** |
| **`CUSTOM_LIST`** | Solo procesa las tablas marcadas con `force_maintenance = TRUE` en `maint.filters`. | ❌ **NO** |
| **`SMART_SYSTEM_USER`** | Igual que `SMART_USER`, pero evalúa también los catálogos internos de PostgreSQL. | ✅ **SÍ** |
| **`ALL_SYSTEM_USER`** | Limpia todas las tablas de usuario y catálogos de sistema a fuerza bruta. | ❌ **NO** |
| **`ALL_SYSTEM`** | Exclusivo para catálogos del motor (`pg_catalog`, `information_schema`). | ❌ **NO** |

---

## ⚙️ PERFILES DE EJECUCIÓN (`p_profile`)

| Perfil | Comportamiento Táctico |
| --- | --- |
| **`NORMAL`** *(Default)* | Análisis estándar de 1 sola pasada respetando el `default_statistics_target` del servidor. |
| **`PRELOAD`** | **Modo de Recuperación en Fases (Disaster Recovery).** Emula `--analyze-in-stages`. Ejecuta 3 pasadas consecutivas por tabla inyectando dinámicamente *targets* estadísticos progresivos (Fase 1: target=1, Fase 2: target=10, Fase 3: target=Default). Ideal post-restauración masiva para dar planes rápidos al optimizador de forma casi inmediata. |

---

## 🚀 GUÍA DE EJECUCIÓN RÁPIDA (Deploy & Forget)

La arquitectura es asíncrona. Nunca ejecutes el procedimiento bloqueando tu consola SSH.

### MÉTODO 1: Automatización Absoluta Nocturna (Vía `pg_cron`) 🌙

**Recomendación:** Madrugadas. El orquestador limpiará su propio rastro (`p_keep_history => FALSE`) y abortará limpiamente si se excede el límite de tiempo.

```sql
SELECT cron.schedule_in_database('vanguard_smart_analyze_daily', '0 2 * * *', 
$$ 
  CALL maint.sp_orchestrate_analyze(
      p_scope            => 'SMART_USER',   -- Solo tablas de usuario modificadas
      p_profile          => 'NORMAL',       -- 1 pasada estándar
      p_parallel_workers => 4,              -- 4 núcleos simultáneos
      p_verbose          => FALSE,          -- Silencioso
      p_threshold_pct    => 0.05,           -- Umbral del 5% de volatilidad
      p_min_rows         => 1000,           -- Ignora tablas con < 1000 cambios
      p_cutoff_time      => '06:00:00'::TIME, -- [KILL SWITCH] Aborto a las 6:00 AM
      p_keep_history     => FALSE           -- [HIGIENE] Purgar detalles al terminar para no ocupar espacio
  ); 
$$, 
'mi_base_de_datos', 'postgres', true);

```

### MÉTODO 2: El Botón de Pánico Asíncrono Diurno (Vía `pg_background`) ⚡

**Recomendación:** Urgencias diurnas sobre tablas VIP o post-restauración (PRELOAD).

```sql
SELECT * FROM public.pg_background_launch(
    $$
      CALL maint.sp_orchestrate_analyze(
          p_scope            => 'CUSTOM_LIST', -- Lista VIP (maint.filters)
          p_profile          => 'PRELOAD',     -- 3 fases progresivas
          p_parallel_workers => 8,             -- Máxima fuerza bruta
          p_keep_history     => TRUE           -- Retener auditoría forense
      );
    $$
);
-- Devuelve un PID. Para monitorear: SELECT * FROM public.pg_background_result(TU_PID) AS (result TEXT);

```

---

## ⚡ OPTIMIZACIÓN AVANZADA: Tuning de Sesión Dinámico

`pg-csql-analyze` posee un **Puente Dinámico Sesión-Worker**. Antes de encolar las tareas, detecta automáticamente si alteraste parámetros de rendimiento en tu consola mediante comandos `SET` y los inyecta directamente (*inline*) a los *workers* en segundo plano.

**Parámetros Soportados para Inyección Dinámica:**

* `maintenance_work_mem`
* `vacuum_cost_delay`
* `vacuum_buffer_usage_limit` *(PostgreSQL 16+)*

**Ejemplo de uso:**

```sql
-- 1. Acelera el I/O en tu sesión actual
SET maintenance_work_mem = '4GB';
SET vacuum_cost_delay = 0;

-- 2. Lanza el orquestador (Los workers asíncronos heredarán tus 4GB y 0 delay automáticamente)
CALL maint.sp_orchestrate_analyze(p_scope => 'SMART_USER');

```

---

## 🎛️ DICCIONARIO DE PARÁMETROS

| Parámetro | Tipo | Default | Descripción Táctica |
| --- | --- | --- | --- |
| `p_scope` | `VARCHAR` | `'SMART_USER'` | Define qué tablas se evalúan. Valores: `'SMART_USER'`, `'ALL_USER'`, `'CUSTOM_LIST'`, `'SMART_SYSTEM_USER'`, `'ALL_SYSTEM_USER'`, `'ALL_SYSTEM'`. |
| `p_profile` | `VARCHAR` | `'NORMAL'` | `'NORMAL'` para uso diario. `'PRELOAD'` para recuperación de emergencia en 3 fases estadísticas. |
| `p_parallel_workers` | `INT` | `4` | Nivel de concurrencia. Número de tablas analizadas simultáneamente. |
| `p_verbose` | `BOOLEAN` | `FALSE` | Modo Diagnóstico. Si es `TRUE`, imprime logs en tiempo real. Usar solo en consolas interactivas (DBeaver/pgAdmin). |
| `p_threshold_pct` | `NUMERIC` | `0.05` | *(Aplica a SMART)* Porcentaje mínimo de filas modificadas respecto al total (0.05 = 5%). |
| `p_min_rows` | `INT` | `1000` | *(Aplica a SMART)* Cantidad absoluta mínima de modificaciones para considerar la tabla. |
| `p_cutoff_time` | `TIME` | `NULL` | **Kill Switch.** Hora militar tope. Si se supera, aborta las tareas encoladas limpiamente. |
| `p_keep_history` | `BOOLEAN` | `TRUE` | **Purga Efímera.** `TRUE` conserva el detalle del job en `analyze_tasks`. `FALSE` elimina los registros detallados al finalizar, previniendo el *bloat* del orquestador. (La tabla `jobs` nunca se borra). |
