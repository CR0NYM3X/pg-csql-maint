

# PROPUESTAS DE MEJORAS O ACTUALIZACIONES  FUTURAS: 


 
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

