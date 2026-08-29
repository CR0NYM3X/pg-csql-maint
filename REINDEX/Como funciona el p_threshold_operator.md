 
### 🧠 ¿Cómo funciona `p_threshold_operator` en la V3.4.1 (Grado Diamante)?

Cuando le pasas al orquestador o al radar el parámetro `p_threshold_operator`, este determina la compuerta lógica entre los **tres pilares del B-Tree**:

1. **Fragmentación Foliar (%)** (`leaf_frag_pct`)
2. **Porcentaje de Bloat / Espacio Libre (%)** (`total_bloat_pct` / `free_pct`)
3. **Tamaño Absoluto de Bloat en MB** (`total_bloat_kb` / `v_threshold_kb`)

Sin embargo, para evitar que una mala combinación lógica deje pasar índices severamente dañados, la evaluación matemática interna no es una suma lineal simple, sino un **agrupamiento defensivo**:

#### 1. Cuando `p_threshold_operator = 'OR'` (Modo Sensible / Inclusivo)

Cualquiera de las 3 condiciones que se cumpla de forma independiente **disparará el REINDEX**:


$$\text{REINDEX} = (\text{Frag \%} \ge \text{Umbral}) \mathbf{\ OR\ } (\text{Bloat \%} \ge \text{Umbral}) \mathbf{\ OR\ } (\text{Bloat MB} \ge \text{Umbral})$$

> **Caso de uso:** Quieres capturar *cualquier* indicio de degradación. Si el índice está muy desordenado (fragmentado), o tiene mucho porcentaje de huecos, o los MB de espacio recuperable son altos, el motor lo intercepta.

#### 2. Cuando `p_threshold_operator = 'AND'` (Modo Estricto / Conservador con Escudo)

Aquí es donde entra el refinamiento que aprobamos en la mesa de trabajo. Si pones `'AND'`, la **Fragmentación Foliar** actúa como una vía independiente de rescate, mientras que los **dos parámetros de Bloat (Porcentaje y Megabytes)** se evalúan juntos de forma compuesta:

$$\text{REINDEX} = (\text{Frag \%} \ge \text{Umbral}) \mathbf{\ OR\ } \Big( (\text{Bloat \%} \ge \text{Umbral}) \mathbf{\ AND\ } (\text{Bloat MB} \ge \text{Umbral}) \Big)$$

---

### 🛡️ ¿Por qué lo diseñamos así y no con un `AND` plano para las 3 cosas?

Como mencionábamos en el veredicto anterior, **Rodrigo (Gatekeeper)** vetó la posibilidad de aplicar un `AND` plano puro `(Frag AND Bloat% AND BloatMB)`.

**El motivo técnico:**

* Un índice puede tener **0% de Bloat** (está completamente lleno, no tiene espacio libre), pero tener **90% de Fragmentación Foliar** (las páginas están desordenadas en disco debido a inserciones aleatorias o *page splits*).
* Si exigiéramos que también cumpliera la condición de Bloat en MB para hacer el `REINDEX`, el motor **omitiría un índice deshojado y lento**, dañando el rendimiento de los `INDEX SCAN` en producción.

Por lo tanto:

* **Fragmentación** evalúa la *salud estructural/secuencial* del árbol B-Tree.
* **Bloat (% y MB)** evalúa el *desperdicio de almacenamiento físico* en disco.

 
---

### 📋 Resumen para el DBA

1. **Sí, `p_threshold_operator` controla la relación entre los tres parámetros.**
2. Con `'OR'`, si se supera **cualquiera** de las 3 métricas, se realiza el REINDEX.
3. Con `'AND'`, exige que el Bloat sea significativo **tanto en Porcentaje como en Megabytes reales**, pero mantiene la alerta encendida si la Fragmentación Foliar está destruida.
4. Además, los parámetros de rescate directo (`p_force_frag_pct` y `p_force_bloat_mb`) y la bandera de índice corrupto (`is_invalid`) **ignoran el operador** e inyectan el mantenimiento de emergencia de forma directa.
