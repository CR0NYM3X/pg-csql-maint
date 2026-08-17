
## 🛠️ ¿PARA QUÉ SIRVE EL ORQUESTADOR analyze?

Es un **motor de mantenimiento asíncrono y paralelo para PostgreSQL** diseñado para mantener al optimizador de consultas en su punto máximo de rendimiento.

* **Evita la degradación del sistema:** Automatiza el refresco de estadísticas (`ANALYZE`)  sin bloquear las transacciones activas de los usuarios.
* **Control de recursos de bajo nivel:** Administra pools de hilos concurrentes, elimina procesos zombis automáticamente y realiza recolección de memoria (GC) para jamás saturar la RAM ni el CPU.
* **Trazabilidad Forense:** Guarda un historial inmutable de cada intervención (filas afectadas, tiempos de ejecución y porcentaje de desfase `drift_pct`) en tablas de auditoría.

```
Futuras actualizaciones agregar y actualizar p_job_type :
SMART_USER
SMART_SYSTEM
SMART_USER_SYSTEM
ALL_USER_SYSTEM

-- Tambien agregarle para que desde el inicio desde la primera ejecucion valide el tema de la hora y no guarde las tablas esto para que no ocupe espacio.
```


---

## 🚦 MODOS DE EJECUCIÓN (`p_job_type`)

### 1. `'SMART'` (El Mantenimiento Quirúrgico Diario)

* **¿Para qué sirve?:** Es el modo **inteligente y autónomo**. En lugar de procesar toda la base de datos a ciegas, lee la telemetría interna del motor (`pg_stat_user_tables`) y selecciona **única y exclusivamente las tablas que están "sucias" o desfasadas**.
* **Criterio de selección:**
* Ignora la "morralla" (tablas con menos de `p_min_rows` modificaciones; por defecto **1,000** filas).
* Evalúa si sufrieron alta volatilidad (cambios mayor a `p_threshold_pct`; por defecto **5%**).
* O si sufrieron un volumen masivo absoluto (más de **50,000** modificaciones sin importar el porcentaje).


* **Caso de uso ideal:** **Mantenimiento nocturno programado de rutina** (vía `pg_cron` a la 1:00 AM o 2:00 AM). Procesa lo que se ensució en el día en cuestión de minutos, ahorrando ciclos de CPU y lecturas de disco SSD.

---

### 2. `'ALL'` (El Mantenimiento Masivo de Catálogo)

* **¿Para qué sirve?:** Ejecuta un `ANALYZE` **sobre absolutamente todas las tablas de usuario** existentes en el catálogo, sin importar si sufrieron cambios o no.
* **Criterio de selección:** Lee `pg_stat_user_tables` completo y ordena las tablas para procesar primero las que tienen mayor volumen de filas modificadas y vivas.
* **Caso de uso ideal:** Mantenimientos profundos de **fin de semana** o ventanas de mantenimiento generales donde se requiere forzar la actualización del 100% de los histogramas del optimizador de la base de datos.

---

### 3. `'PRELOAD'` (La Recuperación de Emergencia en Fases)

* **¿Para qué sirve?:** Emula el flag `--analyze-in-stages` del binario de Linux `vacuumdb`. Ejecuta **3 pasadas consecutivas de `ANALYZE` por cada tabla**, manipulando dinámicamente el parámetro `default_statistics_target`:
1. *Fase 1 (`target = 1`):* Muestra ultra rápida para dar un mapa básico de inmediato.
2. *Fase 2 (`target = 10`):* Muestra media para ajustar histogramas.
3. *Fase 3 (`RESET target`):* Análisis profundo definitivo (target por defecto del servidor, usualmente 100).


* **Caso de uso ideal:** **Exclusivo para escenarios post-desastre:** inmediatamente después de una restauración de base de datos (Point-in-Time Recovery), post-migración de servidor o al levantar un entorno desde cero, permitiendo que el planificador de consultas tenga estadísticas útiles de inmediato sin esperar a que termine un análisis completo.

---
 
### 📋 RESUMEN TÁCTICO DE INVOCACIÓN

```sql
-- 1. Mantenimiento Diario Autónomo (Recomendado)
CALL maint.sp_orchestrate_analyze(p_job_type => 'SMART', p_parallel_workers => 4, p_verbose => TRUE);

-- 2. Mantenimiento Masivo de Fin de Semana
CALL maint.sp_orchestrate_analyze(p_job_type => 'ALL', p_parallel_workers => 8, p_verbose => FALSE);

-- 3. Mantenimiento de Emergencia Post-Restauración
CALL maint.sp_orchestrate_analyze(p_job_type => 'PRELOAD', p_parallel_workers => 8, p_verbose => TRUE);

```




### 🎮 EL MODO DE USO: DOS ESCENARIOS TÁCTICOS

#### 1. El Bisturí (Prueba Visual en tu Consola)

Lo lanzas con `TRUE` en tu DBeaver, se queda "trabado", pero te va imprimiendo un log hermoso en la pestaña de mensajes:

```sql
--- TU CONSOLA SE BLOQUEADA  hasta que termine de procesar todas las tablas.

CALL maint.sp_orchestrate_analyze(
    p_job_type         => 'SMART', 
    p_parallel_workers => 4, 
    p_verbose          => TRUE,
    p_threshold_pct    => 0.05, 
    p_min_rows         => 1000  -- <-- ¡ESTA ES LA CLAVE PARA TU LABORATORIO!
);

```

**Resultado Visual Esperado:**

```text
INFO:  =========================================================
INFO:  [DBA SQUAD] INICIANDO ORQUESTADOR DE MANTENIMIENTO VANGUARD
INFO:  TIPO: SMART | ACCIÓN: ANALYZE | HILOS: 4 | UMBRAL: %5.00 | MIN CAMBIOS: 1000
INFO:  =========================================================
INFO:  [+] JOB ID Asignado: 2
INFO:  [+] Total de tablas que requieren intervención: 5
INFO:  ---------------------------------------------------------
INFO:     [>] LANZANDO -> Hilo 56479 asignado a Tabla: maint.lab_sesiones (Task ID: 6)
INFO:     [>] LANZANDO -> Hilo 56480 asignado a Tabla: maint.lab_carritos (Task ID: 7)
INFO:     [>] LANZANDO -> Hilo 56481 asignado a Tabla: maint.lab_pedidos (Task ID: 8)
INFO:     [>] LANZANDO -> Hilo 56482 asignado a Tabla: maint.lab_logs_auditoria (Task ID: 9)
INFO:     [✓] ÉXITO -> Tabla: maint.lab_carritos (Task ID: 7)
INFO:     [✓] ÉXITO -> Tabla: maint.lab_logs_auditoria (Task ID: 9)
INFO:     [✓] ÉXITO -> Tabla: maint.lab_pedidos (Task ID: 8)
INFO:     [✓] ÉXITO -> Tabla: maint.lab_sesiones (Task ID: 6)
INFO:     [>] LANZANDO -> Hilo 56483 asignado a Tabla: maint.lab_inventario (Task ID: 10)
INFO:     [✓] ÉXITO -> Tabla: maint.lab_inventario (Task ID: 10)
INFO:  ---------------------------------------------------------
INFO:  [DBA SQUAD] ORQUESTACIÓN FINALIZADA CON ÉXITO.
INFO:  Tiempo Total: 00:00:02.036088
INFO:  =========================================================
```

#### 2. Modos Ejecuta y Suelta


**MÉTODO 1: EL FANTASMA MANUAL (Vía pg_background_launch)**
```sql
SELECT pid 
FROM maint.pg_background_launch(
    $$
      CALL maint.sp_orchestrate_analyze(
          p_job_type         => 'SMART',        -- Modo quirúrgico: Solo analiza lo que realmente mutó
          p_parallel_workers => 4,              -- Fuerza bruta controlada: 4 núcleos de CPU trabajando en paralelo
          p_verbose          => FALSE,          -- Silencioso: Como se ejecuta en automático, no saturamos el log
          p_threshold_pct    => 0.05,           -- Umbral del 5%: Solo toca la tabla si el 5% de sus datos cambiaron
          p_min_rows         => 1000,           -- Filtro anti-morralla: Ignora tablas con menos de 1,000 cambios
          p_cutoff_time      => '06:00:00'::TIME -- [KILL SWITCH]: Aborto automático a las 6:00 AM exactas
      );
    $$
);



```

**MÉTODO 2: LA AUTOMATIZACIÓN ABSOLUTA (Vía pg_cron)**
```SQL
-- Programa el orquestador para que despierte todos los días a las 02:00 AM
SELECT cron.schedule_in_database(
    'vanguard_smart_analyze_daily', 
    '0 2 * * *', 
    $$ 
    CALL maint.sp_orchestrate_analyze(
        p_job_type         => 'SMART', 
        p_parallel_workers => 4, 
        p_verbose          => FALSE, 
        p_threshold_pct    => 0.05, 
        p_min_rows         => 1000,
        p_cutoff_time      => '06:00:00'::TIME
    ); 
    $$,
    'mi_base_de_datos', 
    'postgres', 
    true
);
```






---

## **¿Por qué ANALYZE no tarda 1,000 veces más en una tabla de 10 TB que en una de 10 GB en PostgreSQL?**

No, no tarda lo mismo, pero tampoco tarda proporcionalmente  1,000 veces más.  
 
### 1. Comando `ANALYZE` (Recolección de estadísticas)

El comando `ANALYZE` estándar **no lee toda la tabla**. PostgreSQL utiliza un algoritmo de muestreo aleatorio (*random sampling*) basado en el parámetro `default_statistics_target`.

* **Comportamiento:** Por defecto (`default_statistics_target = 100`), PostgreSQL lee únicamente unas **30,000 páginas/bloques aleatorios** de la tabla, sin importar si esta mide 50 GB, 1 TB o 20 TB.
* **Diferencia de tiempo:**
* En una tabla de **10 GB**, las páginas leídas probablemente estén guardadas en la memoria caché RAM (`shared_buffers` / *OS cache*), por lo que el comando tarda **milisegundos o pocos segundos**.
* En una tabla de **10 TB**, las muestras aleatorias obligan al disco a realizar lecturas físicas no secuenciales (*random I/O*). El tiempo aumenta por la latencia del almacenamiento subyacente, tardando desde **algunos segundos hasta un par de minutos**, pero **no** horas.

> **Excepción:** Si aumentas manualmente el `statistics_target` en columnas específicas para mayor precisión (ej. de 100 a 1000), el tamaño de la muestra crece y el tiempo de ejecución aumentará en consecuencia.

