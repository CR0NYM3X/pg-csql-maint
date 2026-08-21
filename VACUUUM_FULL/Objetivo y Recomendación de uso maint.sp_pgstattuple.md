# OBJETIVO DEL PROCEDIMIENTO `maint.sp_pgstattuple`

El objetivo de `maint.sp_pgstattuple` es actuar como un **radar de diagnóstico preventivo** que mide la fragmentación física (*bloat* o espacio muerto) de las tablas antes de las ventanas de mantenimiento.

* **Escanear sin asfixiar el disco:** Inspecciona el espacio libre interno de las tablas usando aproximaciones ultrarrápidas (`pgstattuple_approx`), reservando el escaneo profundo e intensivo solo si tú lo autorizas (`p_enable_deep_scan = TRUE`).
* **Evaluar contra umbrales:** Compara la degradación detectada contra tus reglas de negocio (`p_free_pct_threshold`, `p_free_mb_threshold`, `p_dead_pct_threshold`).
* **Encender el semáforo de ejecución:** Marca la columna `requiere_vf = TRUE` en la tabla de telemetría `maint.pgstattuple` únicamente para las tablas que realmente justifican una cirugía mayor.
* **Aligerar la ventana nocturna:** Evita que el orquestador principal (`sp_orchestrate_vacuum`) pierda tiempo haciendo cálculos matemáticos pesados a la 01:00 AM; el orquestador solo lee el flag `requiere_vf` y dispara el `VACUUM FULL` de forma directa y segura.
 

# Cómo funcionan maint.sp_pgstattuple

Imagínalo como un filtro de seguridad en dos pasos.

#### PASO 1: El Radar Ligero (Siempre obligatorio)

El motor llega a una tabla y hace el escaneo superficial (`pgstattuple_approx`). Inmediatamente, compara esos números aproximados contra los umbrales que tú le pasaste.

* **Si la tabla NO supera ningún umbral:** El motor estampa `requiere_vf = FALSE`. Fin de la historia. No hace nada más y pasa a la siguiente tabla.
* **Si la tabla SÍ supera el umbral:** El motor entra en alerta. Piensa: *"Encontré demasiada basura, esta tabla necesita un VACUUM FULL"*.

**Es justo en este momento de alerta donde entra a jugar el parámetro `p_enable_deep_scan`:**

#### PASO 2: La Decisión (Solo si superó el Paso 1)

Como la tabla reprobó la evaluación rápida, el motor lee tu configuración para saber cómo proceder:

* **ESCENARIO A (`p_enable_deep_scan = FALSE`):**
El motor dice: *"Superó el umbral en mi escaneo rápido y me ordenaron NO hacer el escaneo profundo. Confiaré en mi aproximación"*.
**Resultado:** Estampa `requiere_vf = TRUE` y pasa a la siguiente tabla. (Esto es ideal para tablas gigantes, porque te ahorra I/O).
* **ESCENARIO B (`p_enable_deep_scan = TRUE`):**
El motor dice: *"Superó el umbral en mi escaneo rápido, pero me ordenaron pedir una segunda opinión antes de disparar"*.
Entonces, detiene todo y hace el escaneo profundo bloque por bloque. Vuelve a comparar los **nuevos números reales** contra tus mismos umbrales.
* Si los números reales confirman que la tabla supera el umbral -> **Resultado:** `requiere_vf = TRUE`.
* Si los números reales demuestran que la aproximación exageraba y NO supera el umbral (falsa alarma) -> **Resultado:** Rectifica y estampa `requiere_vf = FALSE`.



---

### 🗺️ El Flujo Táctico Resumido (Sin gráficos que fallen)

1. **¿La tabla es grande?** (Supera `p_min_table_mb`).
* *No:* Ignorar.
* *Sí:* Ir al paso 2.


2. **Escaneo Rápido (Aproximación).** ¿Supera el % de aire o % de tuplas muertas configurado?
* *No:* `requiere_vf = FALSE`. (Termina).
* *Sí:* Ir al paso 3.


3. **¿Me autorizaste el Escaneo Profundo? (`p_enable_deep_scan`)**
* *No (FALSE):* `requiere_vf = TRUE`. (Termina y autoriza el Vacuum Full).
* *Sí (TRUE):* Hacer escaneo profundo y recalcular. Ir al paso 4.


4. **Escaneo Profundo.** ¿Los datos reales superan el umbral?
* *No:* `requiere_vf = FALSE` (Falsa alarma).
* *Sí:* `requiere_vf = TRUE` (Confirmado).
 

---
# 🛡️ Recomendación de Uso 1: Radar Ligero (El Estándar para VLDBs)

**Escenario:** Tienes bases de datos gigantes (con tablas de más de 150 GB).
**Objetivo:** Evaluar la fragmentación en segundos usando el mapa de visibilidad, sin matar el I/O del disco duro. **El Escaneo Profundo se mantiene APAGADO.**

```sql
CALL maint.sp_pgstattuple(
    p_scope              => 'ALL_USER', 
    p_free_pct_threshold => 30.00,       -- Requiere 30% de aire para encender el flag
    p_free_mb_threshold  => 1024.00,     -- O al menos 1 GB de aire absoluto
    p_dead_pct_threshold => 30.00,       -- O 30% de tuplas muertas estimadas
    p_min_table_mb       => 50.00,       -- Ignora tablas menores a 50MB
    p_enable_deep_scan   => FALSE,       -- [KILL-SWITCH]: Escaneo pesado APAGADO.
    p_verbose            => TRUE
);

```

### 🛡️ Recomendación de Uso 2: Auditoría Forense (El Francotirador)

**Escenario:** Auditoría estricta de espacio o bases de datos medianas.
**Objetivo:** Obtener la matemática real bloque por bloque.
**Comportamiento:** Si la Fase 1 detecta aire, se enciende la Fase 2 para confirmar la matemática física exacta antes de encender el flag `requiere_vf`.

```sql
CALL maint.sp_pgstattuple(
    p_scope              => 'ALL_USER', 
    p_free_pct_threshold => 25.00, 
    p_free_mb_threshold  => 1024.00, 
    p_dead_pct_threshold => 30.00, 
    p_min_table_mb       => 50.00, 
    p_enable_deep_scan   => TRUE,        -- [ADVERTENCIA]: Escaneo I/O intensivo ENCENDIDO.
    p_verbose            => TRUE
);

```

### 🛡️ Recomendación de Uso 3: Barrido Rápido a Tablas de Sistema

**Escenario:** Mantenimiento rutinario de catálogos nativos.
**Objetivo:** Limpiar el bloat de `pg_catalog` sin arriesgar bloqueos severos en disco.

```sql
CALL maint.sp_pgstattuple(
    p_scope              => 'ALL_SYSTEM', 
    p_free_pct_threshold => 15.00,       -- Umbral más bajo para catálogos
    p_free_mb_threshold  => 256.00, 
    p_dead_pct_threshold => 20.00, 
    p_min_table_mb       => 0.00,        -- Escanea todo, sin importar tamaño
    p_enable_deep_scan   => FALSE, 
    p_verbose            => TRUE
);

```

### 🔗 Integración Final con el Orquestador

Una vez que el Radar termina, el `VACUUM FULL` se orquesta así, basándose **únicamente** en el flag resultante:

```sql
-- El Orquestador ahora es "tonto". Solo dispara si requiere_vf = TRUE.
CALL maint.sp_orchestrate_vacuum(
    p_scope            => 'ALL_USER', 
    p_profile          => 'SMART_VACUUM_FULL', 
    p_parallel_workers => 1, 
    p_cutoff_time      => '03:30', 
    p_verbose          => TRUE
);

```
