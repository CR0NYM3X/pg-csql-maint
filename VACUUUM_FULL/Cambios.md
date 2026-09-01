
# Cambios raelizados


---
## (V3.5.0) Cancelar procesos al llegar el tiempo definido

Para el módulo `maint.sp_orchestrate_vacuum_full`, se aimplementa siguiente lo siguiente:

1. **Nuevo Parámetro de Control:**
`p_kill_active_on_cutoff BOOLEAN DEFAULT FALSE`
*(Permite al DBA decidir si desea un corte pasivo —esperar a que terminen— o un corte agresivo —aniquilar activos a las 06:00 AM—).*
2. **Mecanismo de Aniquilación en 3 Pasos (DENTRO DEL CUTOFF):**
* **Paso 1 (SIGINT):** Enviar `pg_cancel_backend(child_pid)` para solicitar una cancelación limpia de la transacción.
* **Paso 2 (SIGTERM Fallback):** Esperar 500ms. Si el proceso no ha muerto en `pg_stat_activity`, ejecutar `pg_terminate_backend(child_pid)`.
* **Paso 3 (DSM Purge & Detach):** Ejecutar `pg_background_detach` para liberar los segmentos de memoria compartida en el Kernel de Linux y evitar fugas de memoria (*Memory Leaks*).
