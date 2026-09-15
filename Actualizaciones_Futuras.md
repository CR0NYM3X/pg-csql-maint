

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


 
## **2. Alertamiento Activo vía `NOTIFY` (Integración Externa)**

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

 
