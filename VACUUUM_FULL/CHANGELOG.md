# 📋 Bitácora de Cambios y Actualizaciones (Release Notes v3.5.0)

---

## 🛠️ Novedades de la Versión v3.5.0 (`maint.sp_orchestrate_vacuum_full`)

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


