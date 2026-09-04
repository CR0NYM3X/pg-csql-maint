# 📋 Bitácora de Cambios y Actualizaciones (Release Notes v3.1.0)

---

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

 
