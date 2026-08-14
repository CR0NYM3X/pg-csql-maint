 

### 🧪  (INYECCIÓN DE CAOS Y FRAGMENTACIÓN B-TREE)

Ejecuta este bloque DDL para limpiar pruebas anteriores y construir escenarios de fragmentación masiva, índices zombis simulados y reglas de seguridad.

```sql
/* =========================================================================================
   DBA SQUAD: VANGUARD BLACK-OPS
   MÓDULO: SIMULADOR DE CAOS B-TREE Y POLÍGONO DE PRUEBAS DE REINDEX
   ========================================================================================= */

-- 1. Limpieza de Estructuras Previas
DROP TABLE IF EXISTS public.lab_idx_heavy_bloat CASCADE;
DROP TABLE IF EXISTS public.lab_idx_zombie CASCADE;
DROP TABLE IF EXISTS public.lab_idx_vip CASCADE;
DROP TABLE IF EXISTS public.lab_idx_escudo CASCADE;

TRUNCATE TABLE public.maintenance_filters RESTART IDENTITY CASCADE;
TRUNCATE TABLE public.index_bloat_triage RESTART IDENTITY CASCADE;
TRUNCATE TABLE public.mant_reindex_task RESTART IDENTITY CASCADE;
TRUNCATE TABLE public.maintenance_jobs RESTART IDENTITY CASCADE;

-- 2. Creación de Tablas de Prueba con Índices Múltiples
CREATE TABLE public.lab_idx_heavy_bloat (
    id INT, 
    codigo VARCHAR(50), 
    cliente_id INT, 
    fecha TIMESTAMPTZ, 
    payload TEXT
);
CREATE INDEX idx_bloat_id ON public.lab_idx_heavy_bloat(id);
CREATE INDEX idx_bloat_codigo ON public.lab_idx_heavy_bloat(codigo);
CREATE INDEX idx_bloat_cliente ON public.lab_idx_heavy_bloat(cliente_id);

CREATE TABLE public.lab_idx_zombie (id INT, referencia TEXT);
CREATE INDEX idx_zombie_id ON public.lab_idx_zombie(id);
CREATE INDEX idx_zombie_ref ON public.lab_idx_zombie(referencia);

CREATE TABLE public.lab_idx_vip (id INT, monto NUMERIC);
CREATE INDEX idx_vip_id ON public.lab_idx_vip(id);

CREATE TABLE public.lab_idx_escudo (id INT, token TEXT);
CREATE INDEX idx_escudo_id ON public.lab_idx_escudo(id);

-- =========================================================================================
-- 3. GENERACIÓN DE FRAGMENTACIÓN FÍSICA FOLIAR (PAGE SPLITS Y HUECOS)
-- =========================================================================================

-- [ESCENARIO A]: TABLA CON FRAGMENTACIÓN EXTREMA DE B-TREE
-- Insertamos 300,000 registros y borramos intercaladamente el 70% de forma no secuencial.
-- Esto destruye la densidad del árbol B-Tree, dejando 'Leaf Pages' llenas de huecos.
INSERT INTO public.lab_idx_heavy_bloat (id, codigo, cliente_id, fecha, payload)
SELECT g, 'COD-' || md5(g::text), (random() * 50000)::int, clock_timestamp(), repeat('X', 100)
FROM generate_series(1, 300000) g;

-- Borrado no secuencial (Genera agujeros profundos en las hojas del índice)
DELETE FROM public.lab_idx_heavy_bloat WHERE id % 3 = 0 OR id % 7 = 0;
VACUUM public.lab_idx_heavy_bloat; -- Libera tuplas muertas pero deja los bloques de índice vacíos

-- [ESCENARIO B]: SIMULACIÓN DE ÍNDICE CORRUPTO / ZOMBI (`indisvalid = false`)
-- Simulamos un REINDEX CONCURRENTLY que fue abortado a mitad de camino por un corte de energía.
INSERT INTO public.lab_idx_zombie(id, referencia)
SELECT g, 'REF-' || g FROM generate_series(1, 50000) g;

-- FORZADO DE ESTADO ZOMBI EN EL CATÁLOGO
UPDATE pg_index 
SET indisvalid = FALSE 
WHERE indexrelid = 'public.idx_zombie_ref'::regclass;

-- [ESCENARIO C]: TABLA VIP
INSERT INTO public.lab_idx_vip(id, monto)
SELECT g, g * 1.5 FROM generate_series(1, 20000) g;

-- [ESCENARIO D]: TABLA ESCUDO
INSERT INTO public.lab_idx_escudo(id, token)
SELECT g, md5(g::text) FROM generate_series(1, 50000) g;
DELETE FROM public.lab_idx_escudo WHERE id < 30000;

-- 4. CONFIGURACIÓN DEL PANEL DE SEGURIDAD (FILTROS)
INSERT INTO public.maintenance_filters (schema_name, table_name, is_ignored, force_maintenance) VALUES 
('public', 'lab_idx_escudo', TRUE, FALSE),  -- [BLACK-LIST]: Intocable
('public', 'lab_idx_vip', FALSE, TRUE);      -- [PASE VIP]: Prioridad absoluta

```

---

### 🔬 FASE 2: GUÍA DE EJECUCIÓN Y DEMOSTRACIÓN EN VIVO

**"Soy Sofía, Directora de Producto."**
Aquí tienes la secuencia de comandos acompañada del discurso de venta técnica (*Pitch*) para presentar la potencia del orquestador ante clientes o auditores de infraestructura.

#### Paso 1: Disparo del Radar Predictivo de Índices

> **Pitch para el Cliente:** *"Antes de ejecutar cualquier reconstrucción que consuma I/O de disco, nuestro radar analiza la estructura interna B-Tree vía `pgstatindex`. Calculamos el porcentaje exacto de fragmentación foliar (`leaf_fragmentation`). Si el índice está sano, no se toca."*

```sql
CALL public.sp_populate_index_triage(
    p_scope              => 'ALL_USER',
    p_min_index_mb       => 0.00,   -- Evalúa todos los índices del polígono
    p_frag_pct_threshold => 15.00,  -- Registra si la fragmentación es >= 15%
    p_verbose            => TRUE
);

-- Mostrar el mapa de telemetría obtenido:
SELECT schema_name, table_name, index_name, pg_size_pretty(index_size_bytes) AS tamaño, leaf_fragmentation_pct 
FROM public.index_bloat_triage
ORDER BY leaf_fragmentation_pct DESC;

```

---

#### Paso 2: Activación del "Cazador de Zombis" (`ZOMBIE_HUNTER`)

> **Pitch para el Cliente:** *"Un índice marcado como `INVALID` es una plaga: roba CPU en cada `INSERT` pero no sirve para hacer consultas. Miren cómo el perfil `ZOMBIE_HUNTER` detecta el índice corrupto `idx_zombie_ref` y lo reconstruye de forma concurrente sin detener la base de datos."*

```sql
CALL public.sp_orchestrate_reindex(
    p_scope            => 'SMART_USER',
    p_profile          => 'ZOMBIE_HUNTER',
    p_parallel_workers => 2,
    p_verbose          => TRUE
);

-- Verificar que el índice zombi fue sanado en el catálogo:
SELECT i.relname AS indice, idx.indisvalid AS es_valido 
FROM pg_index idx 
JOIN pg_class i ON i.oid = idx.indexrelid 
WHERE i.relname = 'idx_zombie_ref';

```

---

#### Paso 3: Reindexación Concurrente con Fuerza Bruta en RAM y Kill Switch

> **Pitch para el Cliente:** *"Es noche de fin de semana. Inyectamos 4GB de RAM por hilo de trabajo (`maintenance_work_mem`) y activamos el freno de emergencia a las 06:00 AM. El orquestador reconstruye concurrentemente los índices B-Tree más fragmentados mientras la aplicación sigue vendiendo."*

```sql
-- Tuning de Sesión Dinámico
SET maintenance_work_mem = '4GB';

-- Ejecución del Orquestador
CALL public.sp_orchestrate_reindex(
    p_scope            => 'SMART_USER',
    p_profile          => 'CONCURRENT',
    p_parallel_workers => 2,
    p_cutoff_time      => '06:00:00'::TIME,
    p_frag_pct         => 15.00,
    p_verbose          => TRUE
);

RESET maintenance_work_mem;

```

---

#### Paso 4: Validación del Escudo de Seguridad (`is_ignored = TRUE`)

> **Pitch para el Cliente:** *"A pesar de que la tabla `lab_idx_escudo` tenía miles de páginas fragmentadas, nuestro filtro de inmunidad la protegió al 100%. Cero riesgo en tablas transaccionales hiper-críticas."*

```sql
-- Confirmar que ningún índice de 'lab_idx_escudo' fue ingresado a la cola
SELECT task_id, index_name, status 
FROM public.mant_reindex_task 
WHERE table_name = 'lab_idx_escudo';

```

---

### 📊 FASE 3: DASHBOARD C-LEVEL (VERIFICACIÓN PARA GERENCIA)

Presenta esta consulta SQL para mostrar el control total de métricas y duraciones que la suite registra en cada ciclo:

```sql
SELECT 
    j.job_id AS "ID Job",
    j.job_type AS "Perfil Ejecutado",
    j.maintenance_action AS "Acción Core",
    j.status AS "Estado Final",
    j.parallel_workers AS "Hilos",
    j.tables_processed AS "Índices Exitosos",
    COUNT(t.task_id) AS "Total Candidatos",
    SUM(CASE WHEN t.is_invalid THEN 1 ELSE 0 END) AS "Zombis Curados",
    ROUND(EXTRACT(EPOCH FROM (j.ended_at - j.started_at))::numeric, 2) || ' seg' AS "Tiempo Total",
    j.started_at::TIME(0) AS "Hora Inicio"
FROM public.maintenance_jobs j
LEFT JOIN public.mant_reindex_task t ON j.job_id = t.job_id
WHERE j.maintenance_action = 'REINDEX'
GROUP BY j.job_id, j.job_type, j.maintenance_action, j.status, j.parallel_workers, j.tables_processed, j.started_at, j.ended_at
ORDER BY j.job_id DESC;

```

--- 
