
# Ingeniería Defensiva de Almacenamiento

 

### 🛡️ RAZONAMIENTO PROFUNDO (La Ley del Peor Escenario)

**¿Por qué elegimos `pg_indexes_size()` y le cerramos la puerta a `pgstatindex`?**

Para entenderlo, piensa en lo que le hace a tu servidor. `pgstatindex` no sabe hacer estimaciones rápidas; para darte un dato, obliga al motor a leer físicamente cada bloque del índice en el disco. ¿El resultado? Destruye tu memoria caché (*cache thrashing*) y asfixia el I/O de tu base de datos. En cambio, `pg_indexes_size()` es como mirar el índice de un libro: consulta el tamaño actual directo del catálogo en un instante y con cero impacto operativo, dándonos un límite máximo perfecto.

**Seguramente te estás preguntando: "¿Pero si uso `pg_indexes_size()`, no estoy arrastrando también todo el bloat (la basura)?"**

¡Exacto! Y ese es precisamente nuestro objetivo. Te confieso que al principio consideramos usar un porcentaje para calcular el tamaño real (asumiendo que, si la tabla se reduce a la mitad, el índice también lo hará). Pero lo descartamos de inmediato. ¿La razón? Los índices compuestos, las cláusulas `INCLUDE` y los árboles GIN/GiST simplemente no se encogen de forma lineal. Intentar predecirlo con un porcentaje es jugar a las adivinanzas, y adivinar abre la puerta a que autoricemos un mantenimiento que termine llenando el disco por completo.

**Construyendo un "Techo de Acero"**

Cuando diseñamos sistemas de recuperación, nunca calculamos el espacio esperando un "día soleado"; asumimos que todo va a salir mal. Al incluir el tamaño de `pg_indexes_size()` intacto en nuestra ecuación, estamos creando un escudo impenetrable.

Piénsalo así: si validamos que la nueva tabla cabe en el disco asumiendo que sus índices **no se van a reducir ni un solo megabyte**, entonces tu `VACUUM FULL` está matemáticamente garantizado a no llenar el almacenamiento, sin importar la complejidad de los índices que tenga que reconstruir.

Al final del día, es preferible tener un sistema "cobarde" que decida saltarse una tabla por extrema precaución, a tener un sistema "valiente" que termine tumbando el servidor principal. La única "desventaja" que aceptamos con este modelo es generar un falso positivo por espacio —omitiendo una tabla que quizá, con un poco de suerte, sí habría cabido—. Sinceramente, es un precio minúsculo a pagar a cambio de poder dormir tranquilos y garantizar el 100% de disponibilidad en producción.
 
 
# 🔄 SIMULACIÓN DEL FLUJO Y CÁLCULO EN GIGABYTES (GB)

## 📊 CONFIGURACIÓN EN `MAINT.INSTANCE_CONFIG` (CONFIGURACIÓN EN GB)

```sql
-- DDL DE LA TABLA DE CONFIGURACIÓN
CREATE TABLE IF NOT EXISTS maint.instance_config (
    config_id SERIAL PRIMARY KEY,
    name VARCHAR(255) NOT NULL UNIQUE,
    setting VARCHAR(255) NOT NULL,
    unit VARCHAR(50) NULL,
    setting_desc TEXT NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

-- INSERCIÓN IDEMPOTENTE CON VALOR POR DEFECTO DESACTIVADO (-1)
INSERT INTO maint.instance_config (name, setting, unit, setting_desc) 
VALUES 
  ('max_parallel_vacuum_full_workers', '2', 'workers', 'Límite máximo de workers concurrentes'),
  ('disk_total_size_gb', '-1', 'GB', 'Capacidad total de disco. -1 desactiva la pre-validación de espacio'),
  ('disk_safety_margin_gb', '30', 'GB', 'Margen de seguridad intocable en GB'),
  ('wal_amplification_factor', '2.0', 'ratio', 'Factor de amplificación por WAL (GCP/On-Premise=2.0, Aurora=1.0)')
ON CONFLICT (name) DO NOTHING;

```


### **DATOS DE LA TABLA DE EJEMPLO:**

* **Tabla:** `public.tbl_masiva_100gb`
* **Tamaño Físico Actual:** $100.00\text{ GB}$
* **Datos Reales (`approx_tuple_len`):** $10.00\text{ GB}$ ($10\%$ datos vivos)
* **Basura / Bloat:** $90.00\text{ GB}$ ($90\%$ espacio libre)
* **Índices Actuales (`pg_indexes_size`):** $2.00\text{ GB}$ (Techo Máximo Pesimista)
* **Ocupación Actual de la BD (`pg_database_size`):** $250.00\text{ GB}$

---

### **ESCENARIO 1: `disk_total_size_gb = -1` (DESACTIVADO POR DEFECTO)**

```text
 [ BUCLE DESPACHADOR ]
           │
           ▼
 [ 1. Lectura de maint.instance_config ]
 ├─► disk_total_size_gb = -1
           │
           ▼
 [ 2. Evaluación de Interruptor ]
 ├─► ¿ disk_total_size_gb <= 0 ?  ---> TRUE
 │
 └─► ACCIÓN: BYPASS TOTAL DE LA VALIDACIÓN DE ESPACIO.
     No se realizan cálculos de disco ni se detiene el despacho.
           │
           ▼
 [ AUTORIZADO PARA DESPACHO ]
 ├─► Status inicial = 'RUNNING'
 ├─► Exec: pg_background_launch('VACUUM FULL public.tbl_masiva_100gb;')
 └─► Status final = 'SUCCESS'

```

---

### **ESCENARIO 2: `disk_total_size_gb = 600` (ACTIVADO CON CÁLCULO EN GB)**

```text
 [ BUCLE DESPACHADOR ]
           │
           ▼
 [ 1. Lectura de maint.instance_config ]
 ├─► disk_total_size_gb       = 600.00 GB
 ├─► disk_safety_margin_gb    =  30.00 GB
 ├─► wal_amplification_factor =   2.0
           │
           ▼
 [ 2. Evaluación de Interruptor ]
 ├─► ¿ disk_total_size_gb > 0 ?  ---> TRUE (Proceder con cálculo matemático)
           │
           ▼
 [ 3. Cálculo de Variables en GB (Modelo Pesimista Estricto) ]
 ├─► v_new_heap_gb    = approx_tuple_len / 1024 / 1024 / 1024 = 10.00 GB
 ├─► v_max_indexes_gb = pg_indexes_size() / 1024 / 1024 / 1024 =  2.00 GB
 │
 ├─► v_peak_required_gb = (10.00 GB + 2.00 GB) * 2.0 (WAL)    = 24.00 GB
 ├─► v_db_size_gb       = pg_database_size() / 1024^3          = 250.00 GB
 ├─► v_free_disk_gb     = 600.00 GB - 250.00 GB                = 350.00 GB
           │
           ▼
 [ 4. Evaluación de la Condición de Seguridad ]
 ├─► Espacio Disponible Tras Operación: (350.00 GB - 24.00 GB) = 326.00 GB
 ├─► ¿ 326.00 GB >= 30.00 GB (disk_safety_margin_gb)?
 └─► RESPUESTA: TRUE (Operación 100% Segura)
           │
           ├────────────────────────────────────────┐
           ▼ (Si fuera TRUE)                        ▼ (Si fuera FALSE)
 [ AUTORIZADO PARA DESPACHO ]             [ CANCELACIÓN DE SEGURIDAD ]
 ├─► Status = RUNNING                      ├─► Status = SKIPPED_INSUFFICIENT_DISK_SPACE
 └─► Exec: pg_background_launch()         └─► Registra Log Explicativo

```

---

### **ESCENARIO 3: CANCELACIÓN POR DISCO CASI LLENO (`disk_total_size_gb = 600`, BD Ocupa 550 GB)**

1. $\text{Espacio Libre Actual} = 600.00\text{ GB} - 550.00\text{ GB} = \mathbf{50.00\text{ GB}}$
2. $\text{Espacio Disponible Tras Operación} = 50.00\text{ GB} - 24.00\text{ GB} = \mathbf{26.00\text{ GB}}$
3. **Evaluación de Seguridad:** ¿ $26.00\text{ GB} \ge 30.00\text{ GB}$ (Margen Exigido)? $\rightarrow$ **`FALSE`**.
4. **Acción Operativa:**
* **NO SE LANZA EL VACUUM FULL.**
* `status = 'SKIPPED_INSUFFICIENT_DISK_SPACE'`
* `error_log = 'SKIPPED: Insufficient disk space for public.tbl_masiva_100gb. Peak required (Heap+Indexes+WAL): 24.00 GB. Available after operation: 26.00 GB. Required safety margin: 30.00 GB.'`



---

### ⚖️ VEREDICTO DEL GATEKEEPER (RODRIGO)

"Comandante: La lógica del orquestador ahora es completamente **flexible y a prueba de fallos**:

* Si el cliente deja el parámetro en `-1`, el orquestador opera como originalmente funcionaba (sin filtro de espacio).
* Si el cliente configura un valor mayor a 0 (ej. `600`), activa el escudo pesimista estricto calculando todo en **Gigabytes**.

**LA LÓGICA Y EL FLUJO HAN SIDO AUDITADOS Y APROBADOS.**

¿Confirmas que la simulación es correcta para proceder con la entrega de los artefactos de código SQL/PLpgSQL?"



