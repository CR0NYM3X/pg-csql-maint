 
### 🏛️ LISTADO CONSOLIDADO DE CAMBIOS E IMPLEMENTACIONES

#### 1. Arquitectura de Datos y Esquema Universal (`maint.jobs`)

* **Columna `orchestrator_pid` (Navegación Táctica):** Se agregó la columna `orchestrator_pid INT NOT NULL` en `maint.jobs` para registrar el `pg_backend_pid()` de la sesión principal (Padre) que invoca el orquestador.
* **Sustitución por `execution_params JSONB`:** Se eliminaron las columnas rígidas (`threshold_pct`, `parallel_workers`) de `maint.jobs` y se sustituyeron por un campo universal **`execution_params JSONB NOT NULL`** que almacena la fotografía completa e inmutable de los parámetros lanzados (`scope`, `profile`, `parallel_workers`, `threshold_pct`, `min_rows`, `force_rows`, `cutoff_time`, `keep_history`).

#### 2. Mecanismo de Reconciliación y Auto-Sanación de 2 Niveles (Self-Healing Advanced)

* **Resiliencia ante Interrupciones (`CTRL+C` / Caídas de Red):** Se eliminó la trampa transaccional PL/pgSQL que rompía el código con el error `cannot commit while a subtransaction is active`. Si el cliente interrumpe la sesión, los trabajadores en segundo plano (`pg_background`) **siguen corriendo de forma autónoma en el kernel de PostgreSQL hasta terminar su tarea**.
* **Identificación Multidimensional por Firma Digital (Fingerprinting):** Se erradicó la dependencia rígida de marcas de tiempo (`a.backend_start <= j.started_at`) que generaba falsos positivos por retardo de milisegundos o uso de `PgBouncer`. Ahora la vida del Padre se valida con 3 candados biunívocos:
```sql
a.pid = j.orchestrator_pid 
AND a.query ILIKE '%sp_orchestrate_analyze%' 
AND a.state != 'idle'

```


* **Adopción y Reconciliación en Diferido (Bloque 1-B):** En la siguiente llamada del orquestador, el sistema audita si existen Jobs o tareas huérfanas cuyos PIDs ya no existen en `pg_stat_activity` y actualiza las tablas de control a los estados de auditoría **`ABORTED_ORPHAN`**.

#### 3. Preservación Inmutable de `child_pid` (Cero Bloat y Cumplimiento)

* **Prohibición de `child_pid = NULL`:** Se eliminó la instrucción destructiva que borraba el PID del trabajador al finalizar las tareas.
* **Beneficios Duales:**
1. **Auditoría Forense (PCI-DSS / ISO 27001):** Conserva el historial exacto de qué proceso del S.O. ejecutó la tarea para cruzarlo con `journalctl` / `pg_log`.
2. **Eliminación de Bloat:** Evita escrituras *HOT* destructivas innecesarias sobre `maint.analyze_tasks`.



#### 4. Flexibilidad e Inmunidad ante Entornos Diversos (`pg_cron`)

* **Compatibilidad con `pg_cron` y CLI:** Se removió la restricción `backend_type = 'client backend'` sobre el orquestador Padre. El sistema ahora funciona de manera transparente si es invocado por `pg_cron` (`pg_cron launcher`), scripts en Bash, Python, conectores de aplicación o consolas interactivas (`psql`, DBeaver).
* **Validación Estricta de Hijos:** Para los trabajadores asíncronos se mantuvo la validación estricta `a.backend_type = 'pg_background'`.

#### 5. Lógica de Selección y Filtros Homologados

* **Parámetro `p_force_rows`:** Renombrado y estandarizado a `p_force_rows` (por defecto `50000`). Si una tabla cruza este volumen de filas modificadas, entra a la cola por fuerza bruta ignorando el umbral de porcentaje.
* **Integración del Bypass VIP (`maint.filters`):** Si una tabla está marcada en la tabla de control con `force_maintenance = TRUE`, la consulta la selecciona inmediatamente (Short-Circuit), ignorando `p_min_rows` y `p_threshold_pct`.
* **Escala Porcentual Directa (`p_threshold_pct`):** Homologado a escala de 100 (ej. `5.00` representa 5%), igualando el comportamiento de `VACUUM`.

#### 6. Inyección Dinámica de Sesión Filtrada

* **Optimización de Parámetros GUC:** El procedimiento consulta `pg_settings` e **inyecta comandos `SET` solo si el parámetro fue realmente modificado** respecto a su valor por defecto (`setting IS DISTINCT FROM reset_val`).
* **Aislamiento en Perfil `PRELOAD`:** Excluye el parámetro `default_statistics_target` de la cadena global si el perfil es `PRELOAD`, permitiendo que el perfil maneje su escalera de targets dinámicos por fase (`1` -> `10` -> `100`).

#### 7. Purga Efímera y Estándar de Consola

* **Soporte de Purga (`p_keep_history`):** Si se envía `p_keep_history => FALSE`, la cola `maint.analyze_tasks` se limpia automáticamente al finalizar el Job, evitando el crecimiento de la tabla en entornos de alto mantenimiento.
* **Estandarización de Logs de Consola:** Limpieza total de caracteres unicode y emojis no estándar, sustituyéndolos por las etiquetas corporativas `[>]` (despacho activo de worker) y `[✓]` (confirmación de éxito / cierre).
 
