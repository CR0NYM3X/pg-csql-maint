

## 📅 CRONOGRAMA DE LUNES A SÁBADO: EL BARRIDO DIARIO (Tranquilo)

El objetivo entre semana es mantener los índices limpios, actualizar los mapas de visibilidad y evitar que la basura se acumule. No hacemos reescrituras pesadas de disco (`VACUUM FULL`), solo un mantenimiento asíncrono preventivo.

**Consideración de Hardware:** Al tener 16 CPUs, le asignaremos **6 hilos paralelos** (`p_parallel_workers => 6`). Esto deja 10 CPUs libres para el sistema operativo, tareas de fondo del motor y, lo más importante, el proceso de envío de datos hacia tu servidor réplica (WAL Sender).

```sql
/* =========================================================================
   EJECUCIÓN DIARIA (LUNES A SÁBADO) - 01:00 AM
   ========================================================================= */
CALL maint.sp_orchestrate_vacuum(
    p_scope            => 'ALL_USER', 
    p_profile          => 'BALANCED', 
    p_parallel_workers => 6, 
    p_cutoff_time      => '05:55', 
    p_verbose          => TRUE, 
    p_threshold_pct    => 0.05, 
    p_min_dead_tup     => 5000
);

```

---

## 📅 CRONOGRAMA DOMINICAL: OPERACIÓN HEAVY-LIFT (Agresivo)

El domingo es el día de cirugía mayor. Se divide en tres fases estrictas para identificar la fragmentación profunda, aniquilarla (solo lo más crítico) y luego barrer el resto de la base de datos, garantizando que todo concluya antes de las 06:00 AM.

### [01:00 AM] FASE 1: Radar Forense (Identificación)

Escanea el disco para encontrar tablas "infladas" de aire. No modifica datos.

```sql
CALL maint.sp_populate_vacuum_triage(
    p_scope              => 'ALL_USER', 
    p_free_pct_threshold => 25.00, 
    p_free_mb_threshold  => 1024.00, 
    p_dead_pct_threshold => 30.00, 
    p_min_table_mb       => 50.00, 
    p_verbose            => TRUE
);

```

### [01:20 AM] FASE 2: El Francotirador (Solo Críticos - Vacuum Full)

Reescribe físicamente los discos de las tablas críticas detectadas en la Fase 1.
*Nota de Hardware:* Se fuerza a **1 solo hilo** (`p_parallel_workers => 1`) de forma obligatoria. Si lanzas múltiples Vacuum Full al mismo tiempo, generarás tantos gigabytes de archivos transaccionales por segundo que tu servidor réplica se desconectará por saturación de red (Replication Lag).

```sql
CALL maint.sp_orchestrate_vacuum(
    p_scope            => 'ALL_USER', 
    p_profile          => 'SMART_VACUUM_FULL', 
    p_parallel_workers => 1, 
    p_cutoff_time      => '03:30', 
    p_verbose          => TRUE, 
    p_threshold_pct    => 0.30, 
    p_min_dead_tup     => 5000
);

```

### [03:30 AM] FASE 3: El Barrendero Total (Vacuum Normal a Todo)

Tal como lo ordenaste, a las 03:30 AM el orquestador soltará los bloqueos exclusivos y disparará un Vacuum normal a **todas las tablas** de la base de datos, independientemente de si sufrieron Vacuum Full o no, para asegurar que las estadísticas (`ANALYZE`) y los mapas de visibilidad queden impecables para el inicio de semana.

```sql
CALL maint.sp_orchestrate_vacuum(
    p_scope            => 'ALL_USER', 
    p_profile          => 'BALANCED', 
    p_parallel_workers => 6, 
    p_cutoff_time      => '05:55', 
    p_verbose          => TRUE, 
    p_threshold_pct    => 0.05, 
    p_min_dead_tup     => 5000
);

```

---

## 🎛️ DICCIONARIO DE UMBRALES: ¿CUÁNDO APLICAN Y POR QUÉ?

Aquí te explicamos la lógica matemática detrás de los valores que configuramos en los scripts anteriores.

### 1. Umbrales del Radar (`sp_populate_vacuum_triage`)

*Aplica únicamente el Domingo a las 01:00 AM.*

| Parámetro | Valor | Cuándo Aplica | Justificación (Por qué) |
| --- | --- | --- | --- |
| **`p_min_table_mb`** | `50.00` | Filtro inicial Anti-Morralla. | Ignora cualquier tabla que pese menos de 50 Megabytes. Hacer un escaneo de disco profundo (Fase 2 del triage) a tablas microscópicas es un desperdicio de I/O y ciclos de tu procesador. |
| **`p_free_pct_threshold`** | `25.00` | Gatillo para escaneo profundo. | Si el escaneo superficial detecta que la tabla es **25% aire** (espacio vacío que el S.O. no puede usar), autoriza leer la tabla a bajo nivel. Si tiene menos del 25%, se ignora; el Vacuum normal lo reciclará. |
| **`p_free_mb_threshold`** | `1024.00` | Gatillo absoluto de volumen. | ¿Qué pasa si una tabla pesa 2 Terabytes y tiene solo 10% de fragmentación? No llega al 25% del umbral anterior, pero ese 10% equivale a 200 GB. Este umbral asegura que si vamos a recuperar más de 1 GB (`1024 MB`) físico de disco, la tabla se analice obligatoriamente. |
| **`p_dead_pct_threshold`** | `30.00` | Gatillo de tuplas muertas. | Si la tabla tiene un 30% de registros eliminados/actualizados sin limpiar, se escanea a profundidad. |

### 2. Umbrales del Vacuum Full (`SMART_VACUUM_FULL`)

*Aplica únicamente el Domingo a las 01:20 AM.*

| Parámetro | Valor | Cuándo Aplica | Justificación (Por qué) |
| --- | --- | --- | --- |
| **`p_threshold_pct`** | `0.30` | Filtro final de ejecución. | El orquestador solo ejecutará el `VACUUM FULL` bloqueante si el Radar (Triage) confirmó matemáticamente que recuperarás el **30% o más** del tamaño físico de la tabla. Esto protege a la réplica: nunca reescribimos una tabla si la ganancia de espacio no lo justifica. |
| **`p_min_dead_tup`** | `5000` | Inactivo en este perfil. | Este parámetro es ignorado lógicamente por el código cuando se usa el perfil `SMART_VACUUM_FULL`, ya que la prioridad aquí es el porcentaje de espacio físico recuperable (detectado por el Triage), no la cantidad nominal de tuplas. |

### 3. Umbrales del Vacuum Normal (`BALANCED`)

*Aplica de Lunes a Sábado a la 01:00 AM y el Domingo a las 03:30 AM.*

| Parámetro | Valor | Cuándo Aplica | Justificación (Por qué) |
| --- | --- | --- | --- |
| **`p_threshold_pct`** | `0.05` | Filtro de ejecución asíncrona. | El motor disparará un hilo de trabajo si la tabla tiene al menos un **5% de basura** (tuplas muertas). Un 5% es agresivo y asegura que tu base de datos se barra casi en su totalidad todos los días. |
| **`p_min_dead_tup`** | `5000` | Condición complementaria (AND). | Exige que la tabla tenga al menos 5,000 registros sucios. Si una tabla tiene 100 filas y modificas 6, superas el 5% de basura, pero hacerle Vacuum a 6 filas es inútil. Este umbral evita que el orquestador desperdicie hilos en tablas minúsculas. |

---
