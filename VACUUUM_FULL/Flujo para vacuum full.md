 

### ⚙️ EL FLUJO DE DETECCIÓN (CÓMO PENSARÁ EL ORQUESTADOR)

Cuando el nuevo `sp_orchestrate_vacuum_full` se ejecute en la madrugada, no lanzará el bloqueo a ciegas. Seguirá esta secuencia de 4 pasos para cada tabla:

1. **Lectura de Parámetros:** El orquestador recibe la orden: *"Busca tablas que cumplan la regla de bloat de manera sostenida por p_sustained_days = 5 días"*.
2. **Evaluación en Vivo (Just-In-Time):** El orquestador escanea la tabla en RAM en ese milisegundo exacto. ¿Supera los umbrales de Bloat Hoy?
* Si la respuesta es **NO**, la ignora y pasa a la siguiente. (La tabla está sana hoy, el pasado no importa).
* Si la respuesta es **SÍ**, se enciende la alerta preventiva, pero **no dispara** el `VACUUM FULL` todavía. Pasa al paso 3.


3. **Auditoría Forense (El Viaje al Pasado):** El motor consulta la tabla `maint.pgstattuple` buscando el historial de esa tabla específica durante los últimos 5 días.
4. **Validación de Persistencia:** Verifica si en **TODAS** las evaluaciones de esos 5 días la tabla estuvo marcada como `requiere_vf = TRUE`.
* Si hubo al menos un día donde la tabla se "desinfló" y se volvio inflar el espacio, significa que la tabla es volátil y respira. **Se cancela el bloqueo**.
* Si los 5 días el bloat se mantuvo por encima del umbral, significa que es "Basura Permanente" (Steady-State Bloat). **El francotirador dispara el `VACUUM FULL**`.



---

### 📊 SIMULACIÓN DE COMBATE (Escenario: 7 Días de Operación)

Supongamos que configuras el orquestador con `p_sustained_days => 5`.
Ejecutas el orquestador el **Día 7 en la noche**.

Evaluaremos dos tablas bajo las mismas condiciones:

* **Umbral exigido:** 25% Bloat `AND` 50 MB de basura.

#### Tabla A: `ventas_temporales` (Alta Volatilidad - Falso Positivo)

Esta tabla sufre borrados masivos los lunes, pero los martes se vuelve a llenar.

| Día Operativo | % Bloat | MB Basura | `requiere_vf` en Bitácora |
| --- | --- | --- | --- |
| Día 2 | 10% | 15 MB | `FALSE` |
| Día 3 (Carga) | 30% | 60 MB | **`TRUE`** (Pico de basura) |
| Día 4 (Nuevos Inserts) | 15% | 25 MB | `FALSE` (Reutilizó el espacio) |
| Día 5 | 18% | 30 MB | `FALSE` |
| Día 6 | 28% | 55 MB | **`TRUE`** (Pico de basura) |
| **Día 7 (HOY)** | **29%** | **58 MB** | **`TRUE` (Evaluación en Vivo)** |

**Veredicto del Orquestador para `ventas_temporales`:** **IGNORADA**.
*Análisis de Marcos:* Aunque HOY la tabla supera los umbrales, al mirar 5 días atrás vemos que en los Días 4 y 5 la tabla reutilizó su propio espacio (`FALSE`). Si le hacemos `VACUUM FULL` hoy, destruiremos ese espacio libre que seguramente va a necesitar mañana para los nuevos registros. Salvaste al servidor de un bloqueo innecesario.

#### Tabla B: `clientes_baja_historico` (Basura Permanente - Blanco Confirmado)

Una tabla donde hubo un borrado masivo legal de clientes hace una semana y nadie insertó nada nuevo.

| Día Operativo | % Bloat | MB Basura | `requiere_vf` en Bitácora |
| --- | --- | --- | --- |
| Día 2 | 45% | 120 MB | **`TRUE`** |
| Día 3 | 45% | 120 MB | **`TRUE`** |
| Día 4 | 45% | 120 MB | **`TRUE`** |
| Día 5 | 45% | 120 MB | **`TRUE`** |
| Día 6 | 45% | 120 MB | **`TRUE`** |
| **Día 7 (HOY)** | **45%** | **120 MB** | **`TRUE` (Evaluación en Vivo)** |

**Veredicto del Orquestador para `clientes_baja_historico`:** **FUEGO AUTORIZADO (`VACUUM FULL`)**.
*Análisis de Pedro:* La evaluación en vivo da `TRUE`. El historial de 5 días da `TRUE` continuo ininterrumpido. La matemática demuestra que esta tabla no va a reutilizar ese espacio. Es basura estática muerta. El bloqueo destructivo está justificado.

---

### 🛡️ Mejoras

**El Riesgo de las "Lagunas de Datos" (Gaps):**
¿Qué pasa si el radar matutino (`sp_pgstattuple`) falló el Día 4 porque el servidor se reinició? No habrá registro para el Día 4 en la bitácora.
Si el orquestador busca "5 registros consecutivos en los últimos 5 días" y solo encuentra 4, ignorará una tabla que tal vez sí necesitaba `VACUUM FULL`, solo porque falta un día en la bitácora.

**La Solución Estructural (Aprobada por QA):**
En lugar de buscar por fechas exactas del calendario, la consulta de Pedro deberá basarse en las **"Últimas $X$ evaluaciones reales"**.
El código SQL hará lo siguiente:

1. Toma las últimas 5 lecturas ordenadas por fecha descendente para esa tabla.
2. Cuenta cuántas existen. Si hay menos de 5 lecturas en toda la historia, se salta la tabla (aún no hay madurez de datos para evaluar).
3. Si hay 5 o más, cuenta cuántas de esas últimas 5 fueron `requiere_vf = TRUE`.
4. Si la cuenta exacta es 5 de 5, el historial es persistente y se procede a la cirugía.



--- 
 
###   EL FLUJO DEL ORQUESTADOR  

El orquestador no ejecuta un script ciego; opera como un **motor de decisión en 4 fases**:

1. **Fase 0 - Pre-Flight Check (Fail-Fast):** Valida la presencia de `pg_background`, disponibilidad de `max_worker_processes` y aplica el **freno de mano estricto de 1 a 2 hilos máximos (`p_parallel_workers`)** para prevenir la saturación del disco. Si falla algo, la ejecución aborta en el milisegundo cero.
2. **Fase 1 - Self-Healing & Triage:** Limpia trabajos huérfanos dejados por procesos padres o workers muertos (`ABORTED_ORPHAN`). Posteriormente, llama síncronamente al Radar (`sp_pgstattuple`) para tomar la foto del *bloat* en disco del día de hoy.
3. **Fase 2 - Encolado Silencioso & Escudo Físico:** Filtra las tablas que cumplen los umbrales históricos (`p_sustained_days`) o bypass de emergencia (`p_force_bloat_mb`). **Aplica el Escudo de Inmunidad (`t.schema_name <> 'maint'`)** para impedir que el orquestador se haga `VACUUM FULL` a sí mismo.
4. **Fase 3 - Despacho Asíncrono con Checksum Físico:** Lanza subprocesos mediante `pg_background_launch()`, reportando únicamente la línea enriquecida de lanzamiento. Al finalizar cada tabla, **compara los inodos en disco (`relfilenode`)** para certificar que la reescritura física ocurrió realmente.

---

### 🗺️ DIAGRAMA DE FLUJO TÁCTICO

```text
               ┌─────────────────────────────────────────┐
               │    INICIO: CALL sp_orchestrate_...      │
               └────────────────────┬────────────────────┘
                                    │
                                    ▼
               ┌─────────────────────────────────────────┐
               │   FASE 0: PRE-FLIGHT CHECK (FAIL-FAST)  │
               │   - Extensión pg_background lista?     │
               │   - max_worker_processes suficiente?    │
               │   - p_parallel_workers entre 1 y 2?    │
               └────────────────────┬────────────────────┘
                                    │
                         ┌──────────┴──────────┐
                         │   ¿Pasó Verificación?│
                         └──────────┬──────────┘
                                 NO │  │ SÍ
           ┌────────────────────────┘  └──────────────────────┐
           ▼                                                  ▼
┌──────────────────────┐                           ┌────────────────────┐
│ RAISE EXCEPTION      │                           │ FASE 1:            │
│ (Aborta Sin Registro)│                           │ Self-Healing       │
└──────────────────────┘                           │ & Triage Síncrono  │
                                                   └─────────┬──────────┘
                                                             │
                                                             ▼
                                                   ┌────────────────────┐
                                                   │ FASE 2: ENCOLADO   │
                                                   │ - Evalúa Umbrales  │
                                                   │ - ESCUDO ACTIVO:   │
                                                   │   schema <> 'maint'│
                                                   └─────────┬──────────┘
                                                             │
                                                   ┌─────────┴──────────┐
                                                   │ ¿Hay tareas pendientes?
                                                   └─────────┬──────────┘
                                                           SÍ│  │ NO
                                    ┌────────────────────────┘  └────────┐
                                    ▼                                    ▼
┌────────────────────────────────────────────────────────┐    ┌─────────────────────┐
│ FASE 3: BUCLE DE DESPACHO ASÍNCRONO                    │    │ Cierra Job          │
│                                                        │    │ status = 'COMPLETED'│
│ 1. Selecciona tarea PENDING.                           │    └─────────────────────┘
│ 2. Captura OLD relfilenode.                            │
│ 3. Log: [>] LANZANDO PID -> Tabla | Bloat MB | Días.   │
│ 4. Lanza pg_background_launch('VACUUM FULL...').       │
│ 5. Espera finalización del trabajador.                 │
│ 6. Captura NEW relfilenode.                            │
│                                                        │
│   ¿NEW relfilenode != OLD relfilenode?                 │
│         ├── SÍ ──> Status: 'SUCCESS'                   │
│         └── NO ──> Status: 'FAILED_SILENT_ANOMALY'     │
└───────────────────────────┬────────────────────────────┘
                            │
                            ▼
               ┌─────────────────────────┐
               │ Fin de Cola o Cutoff    │
               │ Cierra Job en maint.jobs│
               └─────────────────────────┘

```

---
