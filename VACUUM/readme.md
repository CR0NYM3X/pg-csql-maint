 

# 🛡️ pg-csql-maint

**Predictive Triage & Async Maintenance Engine for Enterprise PostgreSQL.**

**pg-csql-maint** es un orquestador de mantenimiento asíncrono y predictivo para bases de datos transaccionales masivas. Diseñado para automatizar la limpieza de *bloat* (basura), refrescar estadísticas y ejecutar reestructuraciones físicas quirúrgicas.

## 🥊 Cuadro Comparativo: ¿Por qué usar pg-csql-maint?

La industria suele apoyarse en herramientas externas para combatir la fragmentación, pero exigen modificar tu esquema o compilar binarios de terceros. Así nos comparamos con los líderes del mercado:

| Característica / Herramienta | `pg-csql-maint` 🛡️ | `pg_repack` 📦 | `pg_squeeze` 🗜️ |
| --- | --- | --- | --- |
| **Requiere Primary Key (PK)** | **NO** (Trabaja con cualquier esquema) | SÍ (Falla si la tabla no tiene PK/UK) | SÍ (Dependencia de PK o REPLICA IDENTITY) |
| **Dependencia de Binarios** | **NO** (Usa extensiones nativas `pg_background`, `pgstattuple`) | SÍ (Requiere compilar en el SO Linux) | SÍ (Requiere binarios externos y decoding) |
| **Nivel de Bloqueo** | **AccessExclusiveLock** (Solo en modo FULL) | AccessExclusiveLock (Breve al final) | AccessExclusiveLock (Breve al final) |
| **Triage Predictivo** | **SÍ** (Calcula matemáticamente si vale la pena) | NO (Repaca a ciegas lo que le pidas) | NO (Depende de triggers o peticiones manuales) |
| **Orquestador Asíncrono** | **SÍ** (Auto-gestionado, multi-hilo en Postgres) | NO (Requiere scripts Bash externos) | NO (Ejecución dependiente del cliente) |
| **Caso de Uso Ideal** | **Ventanas de mantenimiento (Noches/Fines de semana)** | Bases de datos 24/7 sin ventanas | Bases de datos 24/7 sin ventanas |

### 💡 Hablemos claro: La Ventaja y la Desventaja

**La Desventaja (Seamos honestos):** A diferencia de `pg_repack`, nuestra reconstrucción física profunda (`VACUUM FULL`) **bloquea la tabla exclusiva y temporalmente**. No puedes escribir ni leer mientras se reconstruye.
**La Ventaja (El Valor Real):** No te obligamos a alterar tu modelo de datos agregando Primary Keys a tablas *legacy*, ni corres riesgos compilando código C externo en tus servidores. Además, **no bloqueamos a lo loco**: gracias a nuestro Triage, la herramienta solo ejecuta el bloqueo exclusivo si demuestra matemáticamente que vas a recuperar Gigabytes de espacio. Es la herramienta perfecta para organizaciones que sí cuentan con **ventanas de mantenimiento nocturnas o de fin de semana** y buscan una automatización a prueba de fallos.

---

## 🎛️ Ámbitos de Operación (`p_scope`)

El parámetro `p_scope` le dice al orquestador **DÓNDE** debe buscar tablas para trabajar. Define el perímetro de seguridad y los filtros aplicables.

* **`SMART_USER`** *(Recomendado)*
* **Para qué sirve:** Evalúa tablas del usuario, pero solo procesa las que tengan un nivel de fragmentación/tuplas muertas superior al umbral permitido (`p_threshold_pct`).
* **Ventaja:** Ahorra CPU. No hace VACUUM a tablas que ya están limpias.
* **Mini Ejemplo:** `CALL public.sp_orchestrate_vacuum(p_scope => 'SMART_USER');`


* **`ALL_USER`**
* **Para qué sirve:** Fuerza el mantenimiento en absolutamente todas las tablas de usuario de la base de datos, ignorando si están limpias o no.
* **Ventaja:** Ideal para un "borrón y cuenta nueva" obligatorio anual o antes de una migración.


* **`CUSTOM_LIST`**
* **Para qué sirve:** Modo VIP. Solo evalúa y procesa las tablas que tú configuraste manualmente con `force_maintenance = TRUE` en la tabla de seguridad `maintenance_filters`.
* **Ventaja:** Permite lanzar un mantenimiento de emergencia al mediodía sobre 3 tablas específicas, sin que el motor se distraiga con el resto del sistema.
* **Mini Ejemplo:** `CALL public.sp_orchestrate_vacuum(p_scope => 'CUSTOM_LIST', p_profile => 'AGGRESSIVE');`


* **`SMART_SYSTEM_USER` / `ALL_SYSTEM_USER` / `ALL_SYSTEM**`
* **Para qué sirve:** Expande los horizontes para incluir los catálogos internos de PostgreSQL (`pg_catalog`).
* **Ventaja:** Combate la inflación oculta del diccionario de datos de Postgres, vital en bases de datos con creación y destrucción constante de objetos temporales.



---

## ⚙️ Perfiles de Ejecución (`p_profile`)

El parámetro `p_profile` le dice al orquestador **CÓMO** actuar sobre las tablas que encontró. Define el nivel de agresividad y el comando SQL exacto que se inyectará.

* **`LIGHT`**
* **Para qué sirve:** Ejecuta un `VACUUM` saltando tablas bloqueadas y omitiendo la limpieza de los índices.
* **Ventaja:** Ejecución ultrarrápida que no interfiere con transacciones en curso.
* **Mini Ejemplo:** `CALL public.sp_orchestrate_vacuum(p_profile => 'LIGHT');`


* **`BALANCED`** *(Por Defecto)*
* **Para qué sirve:** Ejecuta un mantenimiento estándar, limpiando índices solo si la heurística interna del motor lo requiere.
* **Ventaja:** El mejor balance entre recuperación de rendimiento y bajo impacto de I/O.


* **`AGGRESSIVE`**
* **Para qué sirve:** Lanza un mantenimiento pesado usando paralelismo interno nativo de PostgreSQL (4 hilos por tabla) y fuerza una actualización de estadísticas (`ANALYZE`).
* **Ventaja:** Restaura el rendimiento óptimo de las consultas después de cargas masivas de datos (ETLs).


* **`SMART_VACUUM_FULL`** *(La Joya de la Corona)*
* **Para qué sirve:** Cruza datos con la tabla de telemetría del Triage. Si la tabla demostró tener un hueco físico recuperable enorme, lanza un `VACUUM FULL`. Si no, la ignora.
* **Ventaja:** Cero "bloqueos en vano". Solo asumes el costo del bloqueo exclusivo si el retorno de inversión (en Megabytes liberados) está matemáticamente asegurado.
* **Mini Ejemplo:** `CALL public.sp_orchestrate_vacuum(p_profile => 'SMART_VACUUM_FULL', p_threshold_pct => 0.20);`


* **`VACUUM_FULL`**
* **Para qué sirve:** Fuerza la reconstrucción total de la tabla y sus índices, empaquetando los datos a su mínima expresión.
* **Ventaja:** Elimina el 100% de la fragmentación física. Usar con extrema precaución solo dentro de ventanas de mantenimiento aprobadas.



---


## 💻 Ejemplos de Uso Recomendados

### Escenario 1: Mantenimiento Diario de Rutina (Sin impacto operativo)

Ideal para ejecutarse todas las noches. Limpia tuplas muertas sin bloquear tablas y usa pocos recursos para no afectar transacciones nocturnas.

```sql
-- Mantenimiento ligero/balanceado diario sobre tablas de usuario
CALL public.sp_orchestrate_vacuum(
    p_scope => 'SMART_USER',
    p_profile => 'BALANCED',
    p_parallel_workers => 2,
    p_threshold_pct => 0.05
);

```

---

### Escenario 2: Ventana de Mantenimiento Crítica de Fin de Semana (Triage + Smart Vacuum Full)

Para ejecutar una reestructuración física profunda (`VACUUM FULL`) de forma segura en bases de datos de misión crítica (VLDBs), se debe seguir el flujo en 2 pasos dentro de la ventana de tiempo (ej. Sábados de 01:00 AM a 05:00 AM):

```sql
-- =====================================================================
-- PASO 1: EL RECOLECTOR / RADAR (Se ejecuta 1-2 horas antes)
-- Escanea la base de datos y llena la tabla 'vacuum_full_triage'
-- =====================================================================
CALL public.sp_populate_vacuum_triage(
    p_scope => 'ALL_USER', 
    p_free_pct_threshold => 15.00,  -- Marcará tablas con >15% de espacio libre interno
    p_free_mb_threshold => 1024.00,  -- O con >1 GB de espacio libre absoluto
    p_min_table_mb => 100.00,        -- Ignora tablas menores a 100 MB
    p_verbose => TRUE
);

-- =====================================================================
-- PASO 2: TUNING DINÁMICO DE FUERZA BRUTA (Solo dura esta sesión)
-- =====================================================================
SET maintenance_work_mem = '4GB';           -- Asigna RAM masiva para acelerar índices
SET vacuum_cost_delay = 0;                  -- Quita el freno de disco para máxima I/O
SET max_parallel_maintenance_workers = 8;   -- Exprime los núcleos de CPU disponibles
SET wal_compression = on;                   -- Comprime WALs para no asfixiar la red de las réplicas

-- =====================================================================
-- PASO 3: EL ORQUESTADOR SMART (Cirugía Física Inteligente)
-- Consume los datos recolectados en el Paso 1 para actuar quirúrgicamente
-- =====================================================================
CALL public.sp_orchestrate_vacuum(
    p_scope => 'SMART_USER',
    p_profile => 'SMART_VACUUM_FULL', 
    p_parallel_workers => 1,              -- Importante: 1 hilo para evitar contención de I/O en FULL
    p_threshold_pct => 0.15,              -- Filtra tablas que tengan >= 15% en deep_free_percent
    p_cutoff_time => '05:00:00'::TIME,    -- [KILL SWITCH] Aborta si la hora cruza las 05:00 AM
    p_verbose => TRUE
);

-- =====================================================================
-- PASO 4: LIMPIEZA DE SESIÓN (Opcional)
-- =====================================================================
RESET maintenance_work_mem;
RESET vacuum_cost_delay;

```

---

### Escenario 3: Mantenimiento VIP Relámpago (CUSTOM_LIST)

Si necesitas ejecutar mantenimiento agresivo únicamente sobre una lista específica de tablas críticas durante una ventana corta de 15 minutos:

```sql
-- 1. Marcar la tabla en el panel de seguridad (Pase VIP)
UPDATE public.maintenance_filters 
SET force_maintenance = TRUE 
WHERE schema_name = 'public' AND table_name = 'facturas_mes_activo';

-- 2. Ejecutar el orquestador en modo CUSTOM_LIST
CALL public.sp_orchestrate_vacuum(
    p_scope => 'CUSTOM_LIST',
    p_profile => 'AGGRESSIVE',
    p_parallel_workers => 4,
    p_verbose => TRUE
);

```

---
