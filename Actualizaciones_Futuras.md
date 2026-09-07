

# PROPUESTAS DE MEJORAS O ACTUALIZACIONES  FUTURAS: 


## **1. MÓDULO 1: REFACTORIZACIÓN DEL MODELO DE CONTROL (`maint.filters`)**

### **A. Jerarquía de Reglas de Negocio Integrada**

El control de inclusión, exclusión y personalización de mantenimiento se regirá por la siguiente jerarquía inquebrantable de 3 reglas:

1. **Regla 1 (Exclusión Absoluta):** Si `is_ignored = TRUE` (o `filter_type = 'EXCLUDE'/'DISABLED'`), la tabla **nunca** se procesa bajo ninguna circunstancia.
2. **Regla 2 (Fuerza Bruta / Override Total):** Si `force_maintenance = TRUE` (o `filter_type = 'FORCE'`), la tabla **siempre** entra a la cola de procesamiento, ignorando tanto los umbrales globales del orquestador como cualquier umbral específico.
3. **Regla 3 (Umbral Específico por Tabla via `action_params`):** Si `force_maintenance = FALSE` e `is_ignored = FALSE` (o `filter_type = 'CUSTOM'`), el orquestador evalúa los umbrales específicos configurados dentro del campo `action_params` (`JSONB`). Si el parámetro está en `NULL` o ausente dentro del JSON, **hereda automáticamente el parámetro global** pasado al orquestador.

---

### **B. DDL Refactorizado y Estructura Polimórfica (`JSONB` + `filter_type`)**

*Por: Marcos (Arquitectura) y Mauricio (QA & Gobierno)*

Sustituimos el modelo de columnas sueltas por un campo `action_params` tipo `JSONB` extensible a todos los módulos (`ANALYZE`, `VACUUM`, `REINDEX`) y un enum de control unificado `filter_type`.

```sql
-- DDL UNIFICADO DE CONTROL DE FILTROS (V4.0.0)
CREATE TABLE IF NOT EXISTS maint.filters (
    filter_id SERIAL PRIMARY KEY,
    schema_name VARCHAR(255) NOT NULL,
    table_name VARCHAR(255) NOT NULL,
    maintenance_action VARCHAR(50) NOT NULL DEFAULT 'ALL',
    filter_type VARCHAR(20) NOT NULL DEFAULT 'CUSTOM',
    is_ignored BOOLEAN NOT NULL DEFAULT FALSE,          -- Mantenido para retrocompatibilidad V3.x
    force_maintenance BOOLEAN NOT NULL DEFAULT FALSE,   -- Mantenido para retrocompatibilidad V3.x
    action_params JSONB NULL,                            -- Contenedor de umbrales específicos
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_by VARCHAR(100) DEFAULT current_user,

    CONSTRAINT uq_maintenance_filters_schema_table_action 
        UNIQUE (schema_name, table_name, maintenance_action),
    CONSTRAINT chk_valid_maintenance_action CHECK (
        maintenance_action IN ('ALL', 'VACUUM', 'VACUUM_FULL', 'ANALYZE', 'REINDEX')
    ),
    CONSTRAINT chk_valid_filter_type CHECK (
        filter_type IN ('DISABLED', 'EXCLUDE', 'FORCE', 'CUSTOM')
    )
);

-- Ejemplos de configuración en action_params JSONB:
-- ANALYZE:      '{"threshold_pct": 1.5, "min_mod_tuples": 500, "force_mod_tuples": 10000}'
-- VACUUM FULL:  '{"max_dead_tuple_pct": 20.0, "min_dead_tuples": 5000}'
-- REINDEX:      '{"bloat_factor_pct": 30.0, "min_leaf_pages": 1000}'

```

---

## **2. MÓDULO 2: MEJORAS OPERATIVAS Y RESILIENCIA TÁCTICA**

### **1. `lock_timeout` Explícito en Workers Background**

*Por: Pedro (Desarrollo Core) y Samuel (Hardening Linux)*

* **Problema:** En comandos pesados como `VACUUM FULL %I.%I;` o `REINDEX TABLE %I.%I;`, la consulta se ejecuta sin límite de espera de lock. Si la tabla sostiene transacciones largas, el worker en segundo plano se bloquea indefinidamente esperando el candado `ACCESS EXCLUSIVE`, consumiendo un slot de paralelismo sin realizar trabajo real hasta ser abortado por el *cutoff*.
* **Solución de Ingeniería:** Inyectar un `SET lock_timeout` local dentro del bloque SQL lanzado por el worker en background.
 


* **Impacto:** Si la tabla está bloqueada por transacciones activas tras 10 segundos, la tarea falla inmediatamente con el error `55P03` (`lock_not_available`), libera el slot del worker paralelos y permite avanzar a las siguientes tablas de la cola.

---

### **3. Retry Automático Diferenciado por Anomalía**

*Por: Lucas (Integración & Sistemas Distribuidos) y Diego (Seguridad de Datos)*

* **Problema:** Un fallo transitorio por contención de bloqueos (`lock_timeout` o `deadlock`) actualmente recibe el mismo tratamiento definitivo de marcado de error que una anomalía física (como un `relfilenode` que no cambió tras un `VACUUM FULL`).
* **Solución de Ingeniería:** Incorporar un contador de reintentos por tarea y encolar automáticamente si la falla fue de naturaleza transitoria.
* **Ajuste en DDL:**
```sql
ALTER TABLE maint.analyze_tasks ADD COLUMN IF NOT EXISTS retry_count INT NOT NULL DEFAULT 0;
-- Aplicar la misma columna a maint.vacuum_full_tasks y maint.reindex_tasks

```


* **Lógica de Manejo de Excepciones:**
```sql
EXCEPTION WHEN OTHERS THEN
    -- Captura de Lock Timeout (55P03) o Deadlock Detected (40P01)
    IF SQLSTATE IN ('55P03', '40P01') AND r_finished.retry_count < v_max_retries THEN
        UPDATE maint.analyze_tasks 
        SET status = 'PENDING', 
            retry_count = retry_count + 1,
            error_log = 'Re-encolado automático por contención: ' || SQLERRM
        WHERE task_id = r_finished.task_id;
    ELSE
        UPDATE maint.analyze_tasks 
        SET status = 'FAILED', 
            ended_at = clock_timestamp(), 
            error_log = SQLERRM 
        WHERE task_id = r_finished.task_id;
    END IF;

```



---

### **4. Parametrización Dinámica de Paralelismo (`maint.instance_config`)**

*Por: Marcos (Arquitectura) y Samuel (S.O. Linux)*

* **Problema:** Hardcodear el tope de workers paralelos (ej. entre 1 y 2) limita instancias robustas con arreglos NVMe y sobra de CPU, mientras que exponer un parámetro libre en la llamada puede saturar instancias pequeñas.
* **Solución de Ingeniería:** Crear una tabla de configuración persistente a nivel de instancia (`maint.instance_config`) para leer los límites físicos permitidos.
* **DDL de Configuración:**
```sql
CREATE TABLE IF NOT EXISTS maint.instance_config (
    config_id SERIAL PRIMARY KEY,
    name VARCHAR(255) NOT NULL UNIQUE,
    setting VARCHAR(255) NOT NULL,
    unit VARCHAR(50) NULL,
    setting_desc TEXT NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

INSERT INTO maint.instance_config (name, setting, setting_desc) 
VALUES ('max_parallel_vacuum_full_workers', '2', 'Límite máximo de workers concurrentes para tareas pesadas')
ON CONFLICT (name) DO NOTHING;

```


* **Lógica de Validación:** El orquestador lee `setting` de esta tabla en lugar de usar constantes numéricas fijas, validándolo dinámicamente contra `max_worker_processes` de `pg_settings`.

---

### **5. Pre-validación de Espacio en Disco antes del Despacho (Seguridad para `VACUUM FULL` / `REINDEX`)**

*Por: Héctor (Respaldos/DRP) y Javier (Alta Disponibilidad)*

* **Problema:** Ejecutar `VACUUM FULL` o `REINDEX` en tablas de gran volumetría sin suficiente espacio disponible en disco provoca un colapso del almacenamiento (*Disk Full Panic*), corrompiendo la instancia o dejándola fuera de servicio.
* **Solución de Ingeniería:** Calcular el espacio libre real de la partición de datos y restarle el margen de seguridad requerido antes de autorizar el despacho de la tarea.
* **Fórmula Operativa de Validación:**

<BR> **(Espacio Libre Disponible - Espacio Requerido) < Margen de Seguridad Base (10 GB)** <BR> 



<br>**Espacio Libre Disponible = (Tamaño Disco Configurado en instance_config) - (Espacio Consumido por todas las DBs)**<br>


* **Regla de Despacho:**





La tarea se marca como `SKIPPED_INSUFFICIENT_DISK_SPACE` con log explicativo, protegiendo la base de datos de un crash por falta de espacio.

---

### **6. Alertamiento Activo vía `NOTIFY` (Integración Externa)**

*Por: Lucas (Integración & Sistemas Distribuidos)*

* **Problema:** La detección de fallos requiere que un operador consulte proactivamente las tablas de auditoría (`maint.jobs` o `maint.analyze_tasks`).
* **Solución de Ingeniería:** Emitir un evento nativo asíncrono `NOTIFY` cada vez que una tarea cae en estado `FAILED` o `ABORTED_ORPHAN`.
* **Inyección de Código:**
```sql
PERFORM pg_notify(
    'maint_alerts', 
    json_build_object(
        'job_id', v_job_id,
        'schema', r_finished.schema_name,
        'table', r_finished.table_name,
        'status', 'FAILED',
        'error', SQLERRM,
        'timestamp', clock_timestamp()
    )::text
);

```


* **Impacto:** Permite que escuchas externos (un demonio en Python, un servicio en Go o una Cloud Function en GCP/AWS) capturen el canal `maint_alerts` e inyecten la alerta en Slack, PagerDuty o Teams en tiempo real.

---

### **7. Política de Preservación de Historial (`p_keep_history`)**

*Por: Mauricio (QA & Gobierno) y Diego (Seguridad de Datos)*

* **Problema:** La opción `p_keep_history = FALSE` ejecuta un `DELETE FROM maint.analyze_tasks`, lo cual destruye la auditoría forense y contradice la propuesta de valor de trazabilidad del sistema.
* **Solución de Ingeniería:** Reemplazar el `DELETE` destructivo por un esquema de archivado (*Archival Table Pattern*).
* **Implementación:**
Si `p_keep_history = FALSE`, los registros completados no se borran; se mueven mediante una transacción atómica hacia `maint.analyze_tasks_archive`, manteniendo la tabla activa del job ligera sin perder la trazabilidad histórica auditada.

---

### **7. Arquitectura Desacoplada Reinvocada vía `pg_cron` (Eliminación de Polling Interno)**

*Por: Marcos (Arquitectura) y Roberto (AWS/Cloud Architecture)*

* **Problema:** Mantener un `LOOP` con `pg_sleep(2)` dentro de un procedimiento almacenado bloquea una sesión de base de datos durante horas, lo que es frágil ante reinicios de poolers de conexión (como PgBouncer), time-outs de Cloud SQL / RDS o caídas de red.
* **Solución de Ingeniería:** Convertir el orquestador mono-sesión en un modelo de **Máquina de Estados Finitos Reinvocable (Stateless Dispatcher Cycle)**.
* **Estructura Desacoplada:**
1. **`maint.sp_dispatch_analyze_cycle()`:** Procedimiento de paso único (*Single-Pass*). Realiza 3 acciones y termina de inmediato (sin `pg_sleep`, sin loops infinitos):
* A) Revisa y consume resultados de workers `RUNNING` que ya finalizaron.
* B) Auto-sana procesos huérfanos.
* C) Despacha nuevos workers hasta llenar la capacidad configurada en `instance_config` y se cierra.


2. **Programación en `pg_cron`:**
```sql
SELECT cron.schedule(
    'analyze-dispatch-cycle', 
    '*/1 * * * *', 
    $$CALL maint.sp_dispatch_analyze_cycle()$$
);

```




* **Impacto:** Si la sesión se interrumpe, el siguiente minuto de `pg_cron` retoma la ejecución leyendo el estado de las tablas sin perder la secuencia. Libera conexiones y adapta la orquestación a un modelo nativo de la nube.

---



### **8. Reestructuración Lógica del Módulo REINDEX (`p_force_frag_pct` + Triada `AND`)**

*Por: Pedro (Desarrollo Core), Marcos (Arquitectura) y Rodrigo (Technical Gatekeeper)*

* **Problema Identificado:** En la versión anterior, la evaluación del porcentaje de fragmentación base (`p_frag_pct_threshold`) quedaba unida mediante un operador `OR` exterior en todas las ramas de ejecución. Esto provocaba que cualquier índice que superara el umbral base entrara incondicionalmente al proceso, anulando la utilidad técnica del parámetro de bypass `p_force_frag_pct` e impidiendo realizar ejecuciones con una regla `'AND'` estricta sobre la fragmentación y el bloat.
* **Solución de Ingeniería:** Rediseñar la expresión condicional dentro de `maint.sp_pgstatindex` y `maint.sp_orchestrate_reindex` para vincular las tres variables normales (`Fragmentación`, `% Bloat`, `MB Bloat`) al operador de control `p_threshold_operator`. De esta manera, el parámetro `p_force_frag_pct` se preserva y recupera su función de **salida de emergencia (Bypass de Fuerza Bruta)** ante daños estructurales foliares graves.
* **Reglas de Evaluación Rediseñadas (Versión V4.0.0 / V3.5.0):**
1. **Vía Bypass (Fuerza Bruta):** Si la fragmentación foliar alcanza `p_force_frag_pct` (ej. 85%) o el bloat alcanza `p_force_bloat_mb` (ej. 10 GB), el índice se inyecta en la cola de trabajo inmediatamente, ignorando el resto de las reglas.
2. **Vía `'AND'` Estricto:** Si `p_threshold_operator = 'AND'`, el índice solo se procesa si cumple las 3 condiciones al mismo tiempo:
* **Fragmentación** >= `p_frag_pct_threshold` **AND** **Bloat %** >= `p_bloat_pct_threshold` **AND** **Bloat MB** >= `p_bloat_mb_threshold`


3. **Vía `'OR'` Flexible:** Si `p_threshold_operator = 'OR'`, el índice entra a la cola si cumple cualquiera de las 3 condiciones individuales.


* **Ajuste del Condicional en PL/pgSQL:**

```sql
-- EVALUACIÓN MATEMÁTICA RESTRUCTURADA (Fase de Triage REINDEX)
IF (p_force_frag_pct IS NOT NULL AND v_leaf_frag >= p_force_frag_pct) 
   OR (v_force_bloat_kb IS NOT NULL AND v_est_bloat_kb >= v_force_bloat_kb) THEN
    -- Vía 1: Bypass de Fuerza Bruta (Garantiza el rescate de índices destruidos)
    v_requieres_reindex := TRUE;
ELSIF v_op_upper = 'AND' THEN
    -- Vía 2: Regla AND Estricta que vincula las 3 variables
    v_requieres_reindex := (
        v_leaf_frag >= p_frag_pct_threshold 
        AND v_total_bloat_pct >= p_bloat_pct_threshold 
        AND v_est_bloat_kb >= v_threshold_kb
    );
ELSE
    -- Vía 3: Regla OR Flexible
    v_requieres_reindex := (
        v_leaf_frag >= p_frag_pct_threshold 
        OR v_total_bloat_pct >= p_bloat_pct_threshold 
        OR v_est_bloat_kb >= v_threshold_kb
    );
END IF;

```

* **Impacto:** Permite configurar ventanas de mantenimiento altamente conservadoras mediante la regla `'AND'` para no saturar I/O en horas pico, manteniendo `p_force_frag_pct` como una válvula de rescate automática y simétrica para índices pequeños pero severamente fragmentados.



## ** MATRIZ CONSOLIDADA DE LA PROPUESTA (VERSIÓN V4.0.0)**

```
┌────────────────────────────────────────────────────────────────────────────────────────────────────────┐
│                                 ECOSISTEMA DE MANTENIMIENTO V4.0.0                                     │
├──────────────────────────┬───────────────────────────────────────────┬─────────────────────────────────┤
│ Componente               │ Implementación Técnica                    │ Beneficio Principal             │
├──────────────────────────┼───────────────────────────────────────────┼─────────────────────────────────┤
│ Control de Filtros       │ filter_type + action_params (JSONB)       │ Ajuste fino por tabla unificado │
│ Control de Bloqueos      │ SET lock_timeout = '10s' en background    │ Evita slots paralelos zombis    │
│ Manejo de Fallas         │ Retry automático para 55P03/40P01         │ Tolerancia a contención temporal│
│ Paralelismo              │ maint.instance_config dinámico            │ Escalabilidad según Hardware    │
│ Validación de Disco      │ Chequeo previo de MB requeridos vs libres │ Previene colapsos de disco      │
│ Alertamiento             │ NOTIFY 'maint_alerts' (JSON Payload)      │ Integración Slack / PagerDuty   │
│ Auditoría                │ Purga a maint.analyze_tasks_archive       │ Preserva inmutabilidad histórica│
│ Arquitectura de Ciclos   │ Single-pass dispatcher reinvocado pg_cron │ Resiliencia nativa en la Nube   │
│ Reindex Triada AND       │ p_force_frag_pct + Triada AND Estricta    │ Rescue Bypass + Control I/O     │
└──────────────────────────┴───────────────────────────────────────────┴─────────────────────────────────┤

```

 
