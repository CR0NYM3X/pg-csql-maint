 
## 🛠️ Novedades de la Versión v3.6.0 (Grado Diamante - Unified Multi-DB Architecture)

Esta versión representa el hito de consolidación técnica más avanzado de la suite de mantenimiento (`maint`). Se introduce la infraestructura de control dinámico por instancia, el algoritmo *Disk Shield* para prevención activa de fallos por falta de espacio en disco, la estandarización de la *Triada de Control* en reindexación y la intercepción segura de variables del contexto `user`.
 
### 1. Tabla de Configuración Maestra (`maint.instance_config`)

Se implementa el catálogo de configuración global de la instancia, eliminando valores quemados en código (*hardcoded values*) y permitiendo la gobernanza dinámica sin necesidad de recompilar procedimientos almacenados.

* **Estructura DDL Idempotente:**
* `config_id SERIAL PRIMARY KEY`
* `name VARCHAR(255) NOT NULL UNIQUE`
* `setting VARCHAR(255) NOT NULL`
* `unit VARCHAR(50)`
* `setting_desc TEXT`


* **Parámetros Inicializados:**
* `max_parallel_vacuum_full_workers` (Límite dinámico de hilos para `VACUUM FULL`, default: `2`).
* `max_parallel_reindex_workers` (Límite dinámico de hilos para `REINDEX`, default: `4`).
* `max_parallel_vacuum_workers` (Límite dinámico de hilos para `VACUUM`, default: `30` / `4`).
* `max_parallel_analyze_workers` (Límite dinámico de hilos para `ANALYZE`, default: `4`).
* `disk_total_size_gb` (Capacidad total de disco; `-1` desactiva la pre-validación de espacio).
* `disk_safety_margin_gb` (Margen de seguridad intocable o *Techo de Acero*, default: `30` GB).
* `wal_amplification_factor` (Factor de amplificación para estimación de WAL, default: `2.0`).
* `target_databases_for_disk_check` (Ámbito de evaluación Multi-DB, default: `-1`).

 

### 2. Algoritmo *Disk Shield Multi-DB* (`maint.sp_orchestrate_vacuum_full` y `maint.sp_orchestrate_reindex`)

Protección de infraestructura ante eventos de *Disk Full Panic* provocados por la reescritura de archivos físicos (`relfilenode`).

* **Evaluación del Ámbito Multi-DB (`target_databases_for_disk_check`):**
* **Modo `-1`:** Evalúa y suma el tamaño de **todas** las bases de datos conectables (`datallowconn = TRUE`) del clúster mediante `SUM(pg_database_size(oid))`.
* **Modo `'current_database'`:** Calcula exclusivamente el volumen ocupado por la base de datos en ejecución.
* **Modo Lista Explicita:** Parsea listas de bases de datos separadas por comas (`db1, db2, db3`), procesándolas mediante `string_to_array()` y sanitizando espacios con `TRIM()`.


* **Candado de Seguridad por Búsqueda Vacía:**
* Inyección del pre-check defensivo contra la vista global `pg_database`. Si el usuario configura nombres de bases de datos inexistentes, el orquestador aborta la ejecución en el milisegundo cero lanzando la excepción:

CRITICAL [CONFIGURACIÓN]: Ninguna de las bases de datos especificadas en target_databases_for_disk_check (%) existe en esta instancia.
 


* **Cálculo Pesimista de Requerimiento de Disco (*Techo de Acero*):**
* Para `VACUUM FULL`: $\text{Peak GB} = (\text{Heap GB} + \text{Indexes GB}) \times \text{WAL Factor}$
* Para `REINDEX`: $\text{Peak GB} = \text{Indexes GB} \times \text{WAL Factor}$


* **Sanitización del Registro Forense (`error_log`):**
* Implementación de la variable `v_formatted_dbs_log` para prevenir desbordamientos de texto en la columna `error_log` de las tablas `vacuum_full_tasks` y `reindex_tasks` cuando se evalúan cientos de bases de datos.
* Muestra una etiqueta compacta de auditoría (`ALL (-1)`, `Current DB Only`, o resumen de muestra: `700 DB(s) [db1, db2, db3, ...]`).


* **Estado de Tarea Inyectado:**
* **`SKIPPED_INSUFFICIENT_DISK_SPACE`**: Estado asignado automáticamente a la tarea cuando el espacio libre disponible en disco tras la operación proyectada es menor a `disk_safety_margin_gb`.


* **Despliegue Explícito en Consola (`p_verbose = TRUE`):**
* Impresión visual de la fórmula matemática desglosada en tiempo real:

$$\text{Formula: } ((\text{Heap GB } + \text{Index GB}) \times \text{WAL Factor}) = \text{GB Req.}$$


 
### 3. Reestructuración Lógica de Triada en `REINDEX` (`sp_pgstatindex` y `sp_orchestrate_reindex`)

Corrección de la regla de evaluación de fragmentación e ineficiencia de I/O (Triada V4.0.0).

* **Desacoplamiento de Expresión Booleana:**
* Se eliminó el `OR` exterior rígido que provocaba el encolado incondicional de índices por el solo hecho de superar el porcentaje de fragmentación foliar base.


* **Estructura de Evaluación de 3 Vías:**
1. **Vía Bypass (Fuerza Bruta):** Si la fragmentación foliar o el bloat en MB superan los umbrales de emergencia (`p_force_frag_pct` / `p_force_bloat_mb`), el índice entra a la cola omitiendo las demás reglas.
2. **Vía `AND` Estricto:** Exige la alineación simétrica de las tres variables físicas:



3. **Vía `OR` Flexible:** Autoriza el mantenimiento si cualquiera de las tres variables cruza su respectivo umbral base.


 
### 4. Intercepción Dinámica de Contexto `user` (`maint.sp_orchestrate_vacuum`)

Transmisión segura y aislada de configuraciones de sesión para el procedimiento de `VACUUM` estándar.

* **Filtro de Seguridad en `pg_settings`:**
* Captura automática de variables modificadas en la sesión activa (`setting IS DISTINCT FROM reset_val`) restringidas únicamente al contexto seguro `context = 'user'` (ej. `vacuum_cost_delay`, `vacuum_cost_limit`, `vacuum_freeze_min_age`, etc.) junto con `maintenance_work_mem` y `max_parallel_maintenance_workers`.


* **Transmisión por Prefijo SQL (`v_set_prefix`):**
* Erradicación de sentencias `ALTER ROLE ... SET` que alteraban la base de datos de forma permanente.
* Concatenación limpia de instrucciones `SET` al inicio del comando enviado al trabajador de fondo a través de `pg_background_launch`:



* Garantiza la ejecución con los parámetros del usuario sin dejar cambios residuales en la instancia.

 
### 5. Pre-Flight Checks y Gobernanza de Hardware (Todos los Módulos)

Alineación de recursos de hardware en `sp_orchestrate_vacuum_full`, `sp_orchestrate_reindex`, `sp_orchestrate_vacuum` y `sp_orchestrate_analyze`.

* **Validación de `max_worker_processes`:**
* Verificación contra el motor para asegurar que los hilos solicitados (`p_parallel_workers`) no excedan la capacidad nativa del servidor.


* **Validación de Techo Dinámico por Instancia:**
* Lectura de las claves `max_parallel_*_workers` en `maint.instance_config`. Si los hilos solicitados superan el máximo autorizado para el módulo, la transacción se aborta inmediatamente notificando la alerta de seguridad I/O.
 

### 6. Protecciones Físicas e Inmutabilidad Forense

* **Prevención de Overflow Numérico (`LEAST`):**
* Aplicación del modificador `LEAST(..., 999999999.99)` en los cálculos de porcentajes en todas las inserciones de cola para prevenir excepciones `SQLSTATE 22003` (*Numeric Field Overflow*).


* **Compatibilidad Anti-PID Reuse (`child_cookie`):**
* Inserción e idempotencia de la columna `child_cookie BIGINT` en las cuatro tablas de tareas (`vacuum_full_tasks`, `reindex_tasks`, `vacuum_tasks`, `analyze_tasks`), garantizando soporte polimórfico universal con `pg_background` v1.x y v2.0.


* **Purga Defensiva de Memoria Compartida (DSM):**
* Preservación de la llamada defensiva `pg_background_detach` en bloques de excepción para prevenir fugas de memoria en el Kernel de Linux ante interrupciones de workers.



---





# 📋 Bitácora de Cambios y Actualizaciones (Release Notes v3.2.0)

###   Resumen de Impacto

* **Lógica procedural:** 100% Intacta.
* **Calidad de Código (QA):** Eliminación completa de Spanglish y alineación directa con el diccionario de datos nativo de PostgreSQL.

###  (`maint.sp_orchestrate_analyze`)



#### 1. Tabla Bitácora (`maint.analyze_tasks`)

* **`total_filas` ➔ `live_tuples**`: Renombrado para alineación directa con la columna nativa `pg_stat_all_tables.n_live_tup` (representa tuplas vivas en disco).
* **`filas_afectadas` ➔ `modified_tuples**`: Renombrado para alineación con `pg_stat_all_tables.n_mod_since_analyze` (representa tuplas modificadas desde el último ANALYZE).

#### 2. Procedimiento Orquestador (`maint.sp_orchestrate_analyze`)

* **`p_min_chg_rows` ➔ `p_min_mod_tuples**`: Sustituye la contracción informal `chg` y el término abstracto `rows` por la contracción nativa del Kernel `mod` (`n_mod_since_analyze`) y la unidad física `tuples`.
* **`p_force_chg_rows` ➔ `p_force_mod_tuples**`: Mantiene simetría con el parámetro anterior utilizando la nomenclatura nativa de PostgreSQL.

#### 3. Estandarización de Logs y Excepciones (i18n)

* **`[✓] EXITO` ➔ `[✓] SUCCESS**`: Homologación de logs en consola y tablas a inglés técnico universal para colectores SIEM / Datadog.
* **`CRITICO` ➔ `CRITICAL**`: Unificación de mensajes de excepción en PL/pgSQL bajo estándares internacionales.

 

###  (`maint.sp_orchestrate_vacuum`)

#### 1. DDL de Tabla Bitácora (`maint.vacuum_tasks`)

* **`dead_pct` ➔ `dead_tuples_pct**`: Definición explícita de la métrica porcentual de tuplas muertas para alineación semántica de la tabla.

#### 2. Procedimiento Orquestador (`maint.sp_orchestrate_vacuum`)

* **`p_min_dead_rows` ➔ `p_min_dead_tuples**`: Cambio del término abstracto `rows` por el concepto físico nativo de PostgreSQL (`tuples`), alineado directamente con las operaciones del Heap.
* **`p_force_dead_rows` ➔ `p_force_dead_tuples**`: Cambio del término abstracto `rows` por el concepto físico nativo de PostgreSQL (`tuples`) para mantener simetría técnica.

#### 3. Estrategia de Despacho en Cola (`ORDER BY`)

* **Implementación del Algoritmo Snowball**: Inserción y despacho de tareas en `maint.vacuum_tasks` ordenados prioritariamente por la cantidad acumulada de tuplas muertas (`ORDER BY n_dead_tup DESC, n_live_tup DESC`), garantizando ganancias rápidas y optimización de I/O en disco.

#### 4. Estandarización de Logs y Excepciones (i18n)

* **`[✓] EXITO` ➔ `[✓] SUCCESS**`: Homologación de logs en consola y tablas a inglés técnico universal para colectores SIEM / Datadog.
* **`CRITICO` ➔ `CRITICAL**`: Unificación de mensajes de excepción en PL/pgSQL bajo estándares internacionales.

 
 
###  (`maint.sp_orchestrate_vacuum_full`)

#### 1. DDL de Tabla de Telemetría (`maint.pgstattuple`)

* **`requiere_vf` ➔ `requires_vf**`: Corrección gramatical al inglés cambiando el verbo `requiere` por `requires` y conservando el acrónimo técnico internacional `vf` (*Vacuum Full*).

#### 2. DDL de Tabla Bitácora (`maint.vacuum_full_tasks`)

* **`bloat_pct_evaluado` ➔ `bloat_pct**`: Eliminación del sufijo en español `evaluado` para simplificar la columna manteniendo la métrica porcentual.
* **`bloat_kb_evaluado` ➔ `bloat_kb**`: Eliminación del sufijo en español `evaluado` para simplificar la columna manteniendo el volumen de degradación en KB.

#### 3. Procedimiento Radar (`maint.sp_pgstattuple`)

* **`v_requiere_vf` ➔ `v_requires_vf**`: Corrección del verbo en la variable interna para mantener simetría directa con la columna `requires_vf`.

#### 4. Procedimiento Orquestador (`maint.sp_orchestrate_vacuum_full`)

* **Actualización de Consultas de Cola y Despacho**: Ajuste en las sentencias `INSERT INTO maint.vacuum_full_tasks` y en la selección de cola con la estrategia *Snowball* (`ORDER BY bloat_kb ASC`) utilizando los nombres limpios `bloat_pct` y `bloat_kb`.

#### 5. Estandarización de Logs y Excepciones (i18n)

* **Homologación de Salidas en Consola**: Traducción de los mensajes `RAISE INFO`, `RAISE WARNING` y `RAISE EXCEPTION` a inglés técnico estandarizado (`CRITICAL`, `SECURITY ALERT`, `ANOMALY`, `SURGERY CONFIRMED`).


 

**[MESA DE TRABAJO: CHANGELOG TÁCTICO DE REFACTORIZACIÓN - MÓDULO REINDEX]**

Mauricio y Sofía presentan la bitácora resumida de cambios aplicados a la suite `REINDEX CONCURRENTLY` (v3.5.0), incorporando los ajustes exactos de nomenclatura técnica acordados para mantener la precisión semántica y la velocidad de escritura en la consola interactiva.

 

###  (`maint.sp_orchestrate_reindex`)

#### 1. DDL de Tabla de Telemetría (`maint.pgstatindex`)

* **`requiere_reindex` ➔ `requires_reindex**`: Corrección gramatical al inglés cambiando la terminación por la tercera persona (`requires`) y conservando el nombre del objeto nativo.

#### 2. DDL de Tabla Bitácora (`maint.reindex_tasks`)

* **`frag_pct_evaluado` ➔ `frag_pct**`: Eliminación del sufijo en español `evaluado` para simplificar la columna manteniendo la métrica de fragmentación en hojas B-Tree.
* **`bloat_pct_evaluado` ➔ `bloat_pct**`: Eliminación del sufijo en español `evaluado` para simplificar la columna manteniendo la métrica de porcentaje de espacio libre.
* **`bloat_kb_evaluado` ➔ `bloat_kb**`: Eliminación del sufijo en español `evaluado` para simplificar la columna manteniendo el volumen de degradación en KB.

#### 3. Procedimiento Radar (`maint.sp_pgstatindex`)

* **`v_requiere_reindex` ➔ `v_requires_reindex**`: Corrección de la variable interna para mantener simetría directa con la columna refactorizada `requires_reindex`.

#### 4. Procedimiento Orquestador (`maint.sp_orchestrate_reindex`)

* **Actualización de Consultas de Cola y Despacho**: Ajuste en las sentencias `INSERT INTO maint.reindex_tasks` y en la selección de cola con la estrategia priorizada (*Zombis primero + Snowball KB ASC*) utilizando los nombres limpios `frag_pct`, `bloat_pct` y `bloat_kb`.

#### 5. Estandarización de Logs y Excepciones (i18n)

* **Homologación de Salidas en Consola**: Traducción de los mensajes `RAISE INFO`, `RAISE WARNING` y `RAISE EXCEPTION` a inglés técnico estandarizado (`CRITICAL`, `RED ALERT`, `ANOMALY`, `SURGERY CONFIRMED`).

 





---

# 📋 Bitácora de Cambios y Actualizaciones (Release Notes v3.1.0)

## 🛠️ Novedades de la Versión v3.1.0 (`maint.sp_orchestrate_vacuum_full`)

En esta versión se incorporan dos mejoras estratégicas de arquitectura y seguridad operativa para el orquestador de mantenimiento `VACUUM FULL`:

### 1. Despacho Estratégico de Cola: Algoritmo Snowball (`bloat_kb_evaluado ASC`)

Se erradicó el despacho por ordenamiento ciego FIFO (`ORDER BY task_id ASC`) y se sustituyó por una estrategia de **Ganancias Rápidas (Quick Wins)**:

* **Mecanismo:** El orquestador selecciona y procesa las tareas ordenando de menor a mayor cantidad de espacio desperdiciado en disco (`ORDER BY bloat_kb_evaluado ASC, task_id ASC`).
* **Beneficio Técnico:** 
  * **Optimización de Espacio:** Procesa primero las tablas pequeñas y medianas (de 5 a 10 GB), liberando espacio en disco de forma rápida para crear un "colchón" de almacenamiento.
  * **Mitigación de Riesgo de Disco:** Previene fallos por falta de espacio (*File System Full*) al no intentar reescribir tablas gigantes (ej. 100+ GB) de entrada.
  * **Resiliencia ante el Cutoff:** Maximiza el número de tablas procesadas exitosamente antes de que finalice la ventana nocturna de mantenimiento.

###  Nuevos Estados de Tareas (`maint.vacuum_full_tasks`)

* **`ABORTED_BY_CUTOFF`**: Asignado a las tareas que se encontraban en estado `RUNNING` al alcanzar la hora límite y fueron interrumpidas activamente mediante la bandera `p_kill_active_on_cutoff = TRUE`.
* **`SKIPPED_TIME_LIMIT`**: Asignado a las tareas que permanecían en estado `PENDING` al momento de activarse la hora límite.


### 2. Válvula de Aniquilación Defensiva en Cutoff (`p_kill_active_on_cutoff`)

Se añade control activo sobre los procesos en ejecución cuando el reloj alcance la hora límite configurada (`p_cutoff_time`).

* **Nuevo Parámetro de Control:**
  `p_kill_active_on_cutoff BOOLEAN DEFAULT FALSE`  
  *(Permite al DBA decidir si desea un corte pasivo —esperar a que las tareas activas concluyan— o un corte agresivo —aniquilar activos para liberar la base de datos antes del inicio operativo de las 06:00 AM—).*

* **Mecanismo de Aniquilación en 3 Pasos (DENTRO DEL CUTOFF):**
  * **Paso 1 (SIGINT):** Enviar `pg_cancel_backend(child_pid)` para solicitar una cancelación limpia de la transacción.
  * **Paso 2 (SIGTERM Fallback):** Esperar 500 ms. Si el proceso no ha muerto en `pg_stat_activity`, ejecutar `pg_terminate_backend(child_pid)`.
  * **Paso 3 (DSM Purge & Detach):** Ejecutar `pg_background_detach` para liberar los segmentos de memoria compartida en el Kernel de Linux y evitar fugas de memoria (*Memory Leaks*).


 ---


