

# 🛡️ pg-csql-vacuum

**pg-csql-vacuum** es un orquestador de mantenimiento asíncrono y predictivo para bases de datos transaccionales masivas en PostgreSQL. Su objetivo es automatizar la limpieza de *bloat* (basura transaccional) y la actualización de estadísticas sin intervención humana.

> ⚠️ **ACLARACIÓN CRÍTICA DE SEGURIDAD:**
> Esta herramienta está diseñada **estrictamente para mantenimiento en caliente (Non-Blocking)** mediante `VACUUM` y `ANALYZE`. **NO SIRVE ni ejecuta `VACUUM FULL**`. Esta herramienta jamás aplicará un *AccessExclusiveLock* que detenga tu operación, garantizando que tu aplicación pueda seguir leyendo y escribiendo datos mientras la limpieza ocurre en segundo plano.

---

## 🏛️ El Cuarto de Control (Arquitectura de Tablas)

El orquestador no opera a ciegas; está gobernado por 4 tablas maestras que actúan como su memoria y panel de seguridad. Para entender y operar la herramienta, debes conocer estas tablas:

### 1. `maint.jobs` (La Cabecera Global)

Cada vez que lanzas el orquestador, se crea un registro aquí. Almacena el identificador global del ciclo de trabajo, cuántos hilos paralelos se usaron, la hora de inicio/fin y el estado general (`RUNNING`, `COMPLETED`). Es tu vista de "alto nivel" para auditoría operativa.

### 2. `maint.vacuum_tasks` (La Cola Transaccional)

Es el campo de batalla. Por cada `Job`, el motor inserta aquí todas las tablas que necesitan limpieza. Rastrea el milisegundo exacto en que una tabla empezó a limpiarse, qué PID (hilo del sistema operativo) la procesó, y guarda el error nativo (`SQLERRM`) si algo falló.

### 3. `maint.vacuum_profiles` (Seguridad Dinámica Anti-SQLi)

Almacena los perfiles de ejecución dinámicos (Ej. `BALANCED`, `AGGRESSIVE`). En lugar de pasar parámetros de texto inseguros en tus consultas, el orquestador lee las configuraciones de esta tabla (`is_analyze`, `parallel_workers`) y ensambla el código internamente, erradicando cualquier riesgo de Inyección SQL.

**Nota:** La herramienta ya viene con perfiles predefinidos (`LIGHT`, `BALANCED`, `AGGRESSIVE`), pero **puedes modificarlos o agregar tus propios perfiles personalizados** insertando nuevas filas en esta tabla.

### 4. `maint.filters` (Panel de Granularidad y Excepciones)

Funciona como Lista Negra y Lista VIP. Te permite bloquear o forzar mantenimientos a nivel de tabla con precisión quirúrgica.

**Ejemplos prácticos de configuración de Filtros:**

```sql
-- RESTRICCIÓN (Lista Negra): Evitar que 'historico_logs' sea tocada por cualquier mantenimiento
INSERT INTO maint.filters (schema_name, table_name, maintenance_action, is_ignored) 
VALUES ('public', 'historico_logs', 'ALL', TRUE);

-- FORZADO VIP (Lista Blanca): Obligar a limpiar 'usuarios' (Para usar con p_scope = 'CUSTOM_LIST')
INSERT INTO maint.filters (schema_name, table_name, maintenance_action, force_maintenance) 
VALUES ('public', 'usuarios', 'VACUUM', TRUE);

```

---

## 🎛️ Parámetros Principales de Ejecución

Cuando llamas al orquestador, debes definir su alcance y su agresividad.

### 🎯 Ámbitos de Cobertura (`p_scope`) y Dependencia de Umbrales

Controla qué universo de tablas entra a la cola de evaluación. **Nota Táctica:** Los parámetros de control de basura (`p_threshold_pct` y `p_min_dead_tup`) solo son respetados por los alcances inteligentes (`SMART`).

| Valor | Descripción | ¿Evalúa Umbrales de Basura? |
| --- | --- | --- |
| **`SMART_USER`** *(Default)* | Limpia esquemas de usuario. Solo procesa tablas que crucen los umbrales de fragmentación. | ✅ **SÍ** (Filtra por % y tuplas muertas) |
| **`ALL_USER`** | Limpia todas las tablas de usuario, ignorando si están muy sucias o poco sucias. | ❌ **NO** (Ejecución forzada masiva) |
| **`CUSTOM_LIST`** | Solo procesa las tablas marcadas con `force_maintenance = TRUE` en `maint.filters`. | ❌ **NO** (Depende de la Lista VIP) |
| **`SMART_SYSTEM_USER`** | Igual que `SMART_USER`, pero también evalúa catálogos internos de PostgreSQL. | ✅ **SÍ** (Filtra por % y tuplas muertas) |
| **`ALL_SYSTEM_USER`** | Limpia todas las tablas de usuario y catálogos de sistema sin discriminar por tamaño de basura. | ❌ **NO** (Ejecución forzada masiva) |
| **`ALL_SYSTEM`** | Limita la ejecución exclusivamente a los catálogos del motor (`pg_catalog`, `information_schema`). | ❌ **NO** (Ejecución forzada masiva) |

### ⚙️ Perfiles de Mantenimiento (`p_profile`)

*Estos perfiles predefinidos residen en `maint.vacuum_profiles`. Puedes alterarlos o crear los tuyos.*

| Valor Predeterminado | Comportamiento |
| --- | --- |
| **`LIGHT`** | Inofensivo. Salta tablas que estén bloqueadas y no limpia índices (Ideal para picos diurnos). |
| **`BALANCED`** *(Default)* | Limpia tuplas e índices automáticamente. Balance perfecto de I/O. |
| **`AGGRESSIVE`** | Inyecta hilos paralelos (`PARALLEL 4`) y refresca estadísticas (`ANALYZE`). |

---

## 🚀 Guía de Ejecución Rápida (Deploy & Forget)

La arquitectura es asíncrona. Nunca ejecutes el procedimiento bloqueando tu consola SSH. Utiliza uno de estos dos métodos, considerando tu infraestructura.

### MÉTODO 1: Automatización Absoluta Nocturna (Vía `pg_cron`) 🌙

**Compatibilidad:** Soportado en IaaS, On-Premise y Cloud Gestionado (AWS RDS, Aurora, GCP Cloud SQL).
**Recomendación:** Madrugadas (Ej. 02:00 AM) de Lunes a Domingo. Si el mantenimiento se alarga, `p_cutoff_time` abortará las colas limpiamente para no afectar el horario laboral.

```sql
-- Programa el Barrendero Diario a las 02:00 AM.
SELECT cron.schedule_in_database('vanguard_daily_vacuum', '0 2 * * *', 
$$ 
  CALL maint.sp_orchestrate_vacuum(
      p_scope          => 'SMART_USER',  -- VARCHAR : Alcance ('SMART_USER', 'ALL_USER', 'CUSTOM_LIST', 'SMART_SYSTEM_USER', 'ALL_SYSTEM_USER', 'ALL_SYSTEM')
      p_profile        => 'BALANCED',    -- VARCHAR : Perfil de vacuum ('LIGHT', 'BALANCED', 'AGGRESSIVE')
      p_parallel_workers => 4,           -- INT     : Cantidad máxima de hilos/workers asíncronos en paralelo
      p_cutoff_time    => '06:00:00'::TIME,          -- TIME    : Freno de emergencia / Kill-Switch por hora límite (ej. '06:00:00'::TIME; NULL = sin límite)
      p_verbose        => FALSE,          -- BOOLEAN : Diagnóstico visual en tiempo real en consola (TRUE/FALSE)
      p_threshold_pct  => 5,          -- NUMERIC : Umbral de porcentaje mínimo de tuplas muertas (5.00 = 5% de muertas)
      p_min_dead_rows  => 100,          -- INT     : Cantidad mínima de tuplas muertas para evaluar (Filtro anti-morralla)
      p_force_dead_rows => 1000,         -- INT     : Fuerza la entrada si la tabla supera esta cantidad de tuplas muertas (NULL para desactivar)
      p_keep_history   => TRUE           -- BOOLEAN : Retención de auditoría en vacuum_tasks (FALSE = Purga la cola al finalizar)
  );
$$, 
'mi_base_de_datos', 'postgres', true);

```

### MÉTODO 2: El Botón de Pánico Asíncrono Diurno (Vía `pg_background`) ⚡

**Compatibilidad:** Soportado en Servidores Nativos (IaaS, EC2, On-Premise, Cloud SQL).

**Recomendación:** Urgencias diurnas sobre tablas específicas sin congelar la consola del DBA.

```sql
-- Lanza el proceso como un fantasma en el sistema operativo y te devuelve el control de la consola
SELECT * FROM public.pg_background_launch(
    $$
    CALL maint.sp_orchestrate_vacuum(
        p_scope          => 'SMART_USER',  -- VARCHAR : Alcance ('SMART_USER', 'ALL_USER', 'CUSTOM_LIST', 'SMART_SYSTEM_USER', 'ALL_SYSTEM_USER', 'ALL_SYSTEM')
        p_profile        => 'BALANCED',    -- VARCHAR : Perfil de vacuum ('LIGHT', 'BALANCED', 'AGGRESSIVE')
        p_parallel_workers => 4,           -- INT     : Cantidad máxima de hilos/workers asíncronos en paralelo
        p_cutoff_time    => NULL,          -- TIME    : Freno de emergencia / Kill-Switch por hora límite (ej. '06:00:00'::TIME; NULL = sin límite)
        p_verbose        => TRUE,          -- BOOLEAN : Diagnóstico visual en tiempo real en consola (TRUE/FALSE)
        p_threshold_pct  => 5,          -- NUMERIC : Umbral de porcentaje mínimo de tuplas muertas (5.00 = 5% de muertas)
        p_min_dead_rows   => 100,          -- INT     : Cantidad mínima de tuplas muertas para evaluar (Filtro anti-morralla)
        p_force_dead_rows => 1000,         -- INT     : Fuerza la entrada si la tabla supera esta cantidad de tuplas muertas (NULL para desactivar)
        p_keep_history   => TRUE           -- BOOLEAN : Retención de auditoría en vacuum_tasks (FALSE = Purga la cola al finalizar)
    );
    $$
);

-- Obtendrás un PID en pantalla (Ej. 104598). Para revisar el log final, ejecuta:
-- SELECT * FROM public.pg_background_result(104598) AS (result TEXT);
```


 
---
 
## 🎛️ Diccionario de Parámetros: `maint.sp_orchestrate_vacuum`

Cuando ejecutes el procedimiento almacenado (ya sea vía cron o manual), puedes ajustar su comportamiento utilizando estos parámetros. El diseño del escuadrón garantiza que, si omites alguno, el orquestador usará valores seguros por defecto.

| Parámetro | Tipo | Default | Descripción y Uso Operativo |
| --- | --- | --- | --- |
| `p_scope` | `VARCHAR` | `'SMART_USER'` | **Ámbito de Cobertura.** Define qué universo de tablas será evaluado. Valores permitidos: `'SMART_USER'`, `'ALL_USER'`, `'CUSTOM_LIST'`, `'SMART_SYSTEM_USER'`, `'ALL_SYSTEM_USER'`, `'ALL_SYSTEM'`. |
| `p_profile` | `VARCHAR` | `'BALANCED'` | **Nivel de Agresividad.** Lee la tabla `maint.vacuum_profiles` para inyectar configuraciones sin riesgo de inyección SQL. Ejemplos integrados: `'LIGHT'`, `'BALANCED'`, `'AGGRESSIVE'`. |
| `p_parallel_workers` | `INT` | `4` | **Nivel de Concurrencia.** Define cuántas tablas se limpiarán de forma simultánea. *Advertencia: Úsalo con precaución; valores muy altos en bases de datos con discos lentos generarán cuellos de botella de I/O (Saturación de I/O Wait).* |
| `p_cutoff_time` | `TIME` | `NULL` | **Freno de Emergencia (Kill Switch).** Fija una hora límite militar (Ej. `'06:00:00'`). Si un proceso termina y el reloj del sistema supera esta hora, el orquestador abortará la cola pendiente y se apagará para no invadir el horario laboral diurno. Si es `NULL`, correrá hasta vaciar la cola. |
| `p_verbose` | `BOOLEAN` | `FALSE` | **Modo Depuración.** Si se ajusta a `TRUE`, el procedimiento imprimirá mensajes (`INFO`, `WARNING`) en tiempo real sobre qué tabla está procesando, el PID asignado y los fallos encontrados. *Dejar en `FALSE` para automatizaciones en cron.* |
| `p_threshold_pct` | `NUMERIC` | `5.00` | **Umbral Porcentual de Basura.** Solo aplica a *scopes* que inician con `'SMART_'`. Define el porcentaje mínimo de tuplas muertas que una tabla debe tener para entrar a la cola. (Ej. `5.00` = 5% de basura detectada). |
| `p_min_dead_tup` | `INT` | `5000` | **Filtro de Tablas Minúsculas.** Evita desperdiciar ciclos de CPU evaluando tablas ínfimas. Una tabla debe tener al menos este número absoluto de tuplas muertas para ser considerada. *Nota: Si una tabla supera las 100,000 tuplas muertas, ignora el porcentaje e ingresa a la cola automáticamente como medida de protección extrema.* |

 


Aquí tienes el bloque exacto en Markdown listo para agregar a tu `README.md`.

Te recomiendo colocarlo **justo después de la sección "🚀 Guía de Ejecución Rápida"** y antes del **"🎛️ Diccionario de Parámetros"**.

---

### ⚡ Optimización Avanzada: Tuning de Sesión Dinámico (Fuerza Bruta)

Si necesitas acelerar una ejecución crítica, `pg-csql-vacuum` incluye un **Puente Dinámico Sesión-Rol**. Detecta automáticamente si alteraste parámetros en tu consola local mediante comandos `SET` y los transmite de forma segura a los *workers* en segundo plano, limpiando el catálogo del sistema al finalizar.

#### Parámetros Soportados para Tuning al Vuelo:

* `maintenance_work_mem`: Asigna RAM masiva para acelerar el procesamiento de índices en memoria.
* `max_parallel_maintenance_workers`: Asigna más núcleos de CPU por cada tabla encolada.
* `vacuum_cost_delay`: Controla el "freno de disco" de I/O.

#### Ejemplo de Ejecución Acelerada:

```sql
-- 1. Configura tus recursos extremos a nivel de sesión actual
SET maintenance_work_mem = '2GB';
SET max_parallel_maintenance_workers = 4;
SET vacuum_cost_delay = 0;

-- 2. Lanza el orquestador (Los background workers heredarán tus 2GB y 4 hilos automáticamente)
    CALL maint.sp_orchestrate_vacuum(
        p_scope          => 'SMART_USER',  -- VARCHAR : Alcance ('SMART_USER', 'ALL_USER', 'CUSTOM_LIST', 'SMART_SYSTEM_USER', 'ALL_SYSTEM_USER', 'ALL_SYSTEM')
        p_profile        => 'BALANCED',    -- VARCHAR : Perfil de vacuum ('LIGHT', 'BALANCED', 'AGGRESSIVE')
        p_parallel_workers => 4,           -- INT     : Cantidad máxima de hilos/workers asíncronos en paralelo
        p_cutoff_time    => NULL,          -- TIME    : Freno de emergencia / Kill-Switch por hora límite (ej. '06:00:00'::TIME; NULL = sin límite)
        p_verbose        => TRUE,          -- BOOLEAN : Diagnóstico visual en tiempo real en consola (TRUE/FALSE)
        p_threshold_pct  => 5,          -- NUMERIC : Umbral de porcentaje mínimo de tuplas muertas (5.00 = 5% de muertas)
        p_min_dead_rows   => 100,          -- INT     : Cantidad mínima de tuplas muertas para evaluar (Filtro anti-morralla)
        p_force_dead_rows => 1000,         -- INT     : Fuerza la entrada si la tabla supera esta cantidad de tuplas muertas (NULL para desactivar)
        p_keep_history   => TRUE           -- BOOLEAN : Retención de auditoría en vacuum_tasks (FALSE = Purga la cola al finalizar)
    );

-- 3. Al terminar la orquestación, el procedimiento resetea la configuración del ROL automáticamente en el catálogo.

```

---

> ⚠️ **ADVERTENCIA CRÍTICA DE RECURSOS (I/O & RAM):**
> * **Saturación de Disco (`vacuum_cost_delay = 0`):** Ajustar el delay a `0` quita por completo el freno de disco. **Nunca uses este valor en horario laboral**, ya que consumirá todo el ancho de banda del almacenamiento e incrementará drásticamente los tiempos de respuesta de tu aplicación.
> * **Riesgo de Colapso de Memoria (OOM Killer):** Recuerda que `maintenance_work_mem` se multiplica por la concurrencia. Si configuras `2GB` de RAM y ejecutas con `p_parallel_workers => 4`, el proceso usará hasta **8 GB de RAM real de golpe**. Si el servidor se queda sin memoria, el Kernel de Linux (OOM Killer) matará el proceso de PostgreSQL.
 
💡 **Recomendación:** Usa el tuning de sesión dinámico **únicamente en ventanas de mantenimiento nocturnas o fines de semana**. Para la rutina diaria automática vía `pg_cron`, no ejecutes ningún `SET` previo; deja que el orquestador opere con los valores por defecto (`reset_val`) del servidor para no impactar la operación.

---

### 📊 MATRIZ DE ESTADOS PARA EL MÓDULO `VACUUM`

#### 1. Para la Tabla Cabecera Maestra (`maint.jobs`):

* **`RUNNING`**: El orquestador principal (el Job Padre) está actualmente en ejecución activa despachando o monitoreando trabajadores de `VACUUM`.
* **`COMPLETED`**: El orquestador terminó todo el ciclo de trabajo de manera óptima, ya sea porque procesó todas las tareas exitosamente o porque no hubo tablas candidatas en el sistema (Sistema óptimo).
* **`COMPLETED_WITH_CUTOFF`**: El orquestador alcanzó la hora límite (`p_cutoff_time`) definida por el DBA. Detuvo la inyección de nuevas tareas, cerró limpiamente las que estaban en ejecución y cerró el Job.
* **`ABORTED_ORPHAN`**: El Job Padre sufrió una muerte súbita (ej. Caída de red del cliente, Servidor reiniciado, `SIGKILL -9`). El orquestador detectó la ausencia del PID en la siguiente ejecución y selló el Job de forma forense.
* **`CANCELLED_BY_USER`**: Interrupción manual controlada (ej. `CTRL+C` atrapado limpiamente). *(Nota: En `VACUUM` este estado es menos frecuente debido a que la interrupción suele generar el estado Huérfano si el Padre muere de golpe, pero el catálogo lo soporta por homologación con la suite global).*

 
#### 2. Para la Cola de Tareas Hijas (`maint.vacuum_tasks`):

* **`PENDING`**: La tabla candidata superó los filtros matemáticos (o fue forzada por `maint.filters`) y está en la cola, esperando que un worker se libere.
* **`RUNNING`**: La tabla está siendo intervenida en este milisegundo por un worker asíncrono (`pg_background`). El campo `child_pid` contiene la firma del trabajador activo.
* **`SUCCESS`**: El worker de fondo ejecutó el `VACUUM (Opciones) esquema.tabla` de manera exitosa y el recolector forense recuperó el resultado.
* **`FAILED`**: La ejecución del comando `VACUUM` sobre esa tabla en particular falló (por ejemplo, permisos insuficientes, objeto eliminado en caliente, etc.). El error nativo queda grabado inmutablemente en la columna `error_log`.
* **`SKIPPED_TIME_LIMIT`**: La tarea estaba en `PENDING` cuando el orquestador activó el freno de emergencia por tiempo (`p_cutoff_time`). La tarea no se ejecutó.
* **`ABORTED_ORPHAN`**: La tarea quedó congelada en `RUNNING` cuando el proceso Padre murió, y fue reconciliada (sellada) por el bloque de auto-sanación en la siguiente ejecución del orquestador.

 
