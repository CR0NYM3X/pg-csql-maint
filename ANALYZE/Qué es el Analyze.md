 

### 1. ¿Qué es `ANALYZE` y por qué surge la necesidad?


Para entender por qué existe `ANALYZE`, primero debes entender que **PostgreSQL es ciego**.
Cuando tú envías una consulta (`SELECT * FROM ventas WHERE total > 1000`), el cerebro del motor —llamado **Optimizador de Consultas (Query Planner)**— tiene que decidir cómo encontrar esos datos: ¿Usa un índice? ¿Escanea todo el disco duro? ¿Hace un *Hash Join* o un *Nested Loop*?

El Optimizador no puede leer la tabla entera en ese milisegundo para decidir. Necesita un mapa previo. **`ANALYZE` es el cartógrafo del motor.**
Es el comando que escanea las tablas y recolecta estadísticas matemáticas sobre los datos, guardándolas en el catálogo interno `pg_statistic`. Sin estas estadísticas, el Optimizador adivinaría a ciegas, eligiendo rutas desastrosas que congelarían tu servidor.

Realizar el analyze tambien actualiza en memoria  la vista pg_stat_user_tables y su columna importante n_mod_since_analyze.
Tambien llena la tabla  pg_class y columna relpages,reltuples 

### 4 formas principales de ejecutar ANALYZE en PostgreSQL
```SQL


--- Toda la base de datos actual:
ANALYZE;

--- Una tabla específica:
ANALYZE mi_tabla;

--- Columnas específicas de una tabla(útil para tablas gigantes donde solo cambias ciertas columnas):
ANALYZE mi_tabla (columna1, columna2);

--- Con salida detallada (Verbose):
ANALYZE VERBOSE mi_tabla;

```

# Consulta la cantidad de cambios
* **`n_mod_since_analyze`**: Cantidad de modificaciones (`INSERT`, `UPDATE`, `DELETE`) registradas desde la última vez que la tabla fue analizada.
obtener el porcentaje real de cambios que ha sufrido una tabla desde su último ANALYZE.<br>
**Porcentaje** = `(n_mod_since_analyze / n_live_tup ) * 100`
```
select relname,n_live_tup, n_mod_since_analyze, (n_mod_since_analyze / n_live_tup ) * 100 as prc_desfase from pg_stat_user_tables where relname = 'mi_tabla';
```

### 2. ¿Cómo funciona internamente? (El Algoritmo)



El secreto mejor guardado de `ANALYZE` es que **no lee toda la tabla** (hacerlo destruiría el rendimiento en tablas de Terabytes). Funciona mediante un muestreo probabilístico.

1. **La Muestra Aleatoria:** Cuando lo ejecutas, el motor lee un número limitado de páginas físicas (bloques de 8 KB) al azar distribuidas por todo el archivo. El tamaño de esta muestra se controla con el parámetro `default_statistics_target` (por defecto es 100, lo que equivale a leer solo unas 30,000 filas de muestra, sin importar si la tabla tiene 1 millón o 1 billón de registros).
2. **Cálculo de Histogramas:** Con esa muestra, agrupa los datos en "cubetas" para entender la distribución (¿hay más clientes de México o de España?).
3. **Valores Más Comunes (MCV):** Crea una lista de los valores que más se repiten. Si buscas `status = 'ACTIVO'` y el MCV dice que el 99% de la tabla es 'ACTIVO', el Optimizador ignorará el índice porque es más rápido leer la tabla completa.
4. **Correlación Física:** Mide qué tan ordenados están los datos en el disco duro en relación con el índice.



### 3. ¿Genera Bloqueos en Producción?



Esta es la pregunta que define a un DBA Senior. La respuesta es una excelente noticia para el negocio: **NO, `ANALYZE` no detiene tu producción.**

* **El Bloqueo (Lock):** `ANALYZE` adquiere un nivel de bloqueo llamado `ShareUpdateExclusiveLock`.
* **Lo que SÍ bloquea:** Solo bloquea a otro `ANALYZE`, a un `VACUUM` (no completo), a un `CREATE INDEX CONCURRENTLY` o a un `ALTER TABLE` que intente modificar la estructura de esa misma tabla al mismo tiempo.
* **Lo que NO bloquea:** Es completamente transparente para el tráfico de la aplicación. Mientras `ANALYZE` se ejecuta, los usuarios pueden seguir haciendo **`SELECT`, `INSERT`, `UPDATE` y `DELETE` a máxima velocidad**.

Puedes (y debes) ejecutarlo con la base de datos viva.



### 4. Ventajas, Desventajas y Riesgos


No te voy a vender que es un comando mágico. Tiene sus costos operativos y debes conocerlos para no dispararte en el pie.

| Aspecto | Detalle Técnico |
| --- | --- |
| **VENTAJA 1: Rendimiento** | Es la diferencia entre una consulta que tarda 500 milisegundos (con buenas estadísticas) y una que tarda 4 horas (con malas estadísticas eligiendo un *Seq Scan* por error). |
| **VENTAJA 2: Velocidad** | Al ser una muestra aleatoria, puede analizar una tabla de 500 GB en cuestión de segundos o pocos minutos. |
| **DESVENTAJA 1: Costo de I/O** | Lee bloques físicos. Si lanzas un `ANALYZE` simultáneo a 10,000 tablas en horario pico, saturarás la lectura del disco duro y ahogarás el servidor. |
| **RIESGO: No-Determinismo** | Como toma muestras al azar, las estadísticas cambiarán ligeramente cada vez que se ejecute. Si tu parámetro `default_statistics_target` es muy bajo para una tabla muy compleja, el Optimizador podría cambiar un plan de ejecución de rápido a lento de forma "inexplicable" tras un `ANALYZE`. |



### 5. Reglas de Fuego: Cuándo Ejecutarlo y Cuándo NO (Escenarios y Horarios)

Basado en la doctrina del DBA SQUAD, así es como debes programar o invocar este mantenimiento:

#### Escenario A: Tablas Transaccionales Normales (El día a día)

* **Recomendación:** **NO LO TOQUES MANUALMENTE.**
* **Justificación:** PostgreSQL tiene un demonio llamado `autovacuum` que se encarga de monitorear los `INSERT`, `UPDATE` y `DELETE`. Cuando detecta que el ~10% de la tabla ha cambiado, él mismo lanza un `ANALYZE` silencioso en segundo plano. Deja que el motor haga su trabajo.

#### Escenario B: Inserciones Masivas / ETL / Migraciones

* **Cuándo ejecutarlo:** **Inmediatamente después de la carga de datos.**
* **Justificación:** Si acabas de insertar 50 millones de filas mediante un proceso `COPY` o una migración, el `autovacuum` tardará un rato en darse cuenta y despertar. Si un usuario hace una consulta en ese lapso de ceguera, el motor colapsará. Aquí SÍ debes incluir el comando explícito `ANALYZE nombre_tabla;` al final de tu script de inserción.

#### Escenario C: Tablas Extremadamente Volátiles (Ej. Colas de Trabajo o Sesiones)

* **Cuándo ejecutarlo:** **Cada pocos minutos (mediante orquestador) o ajustar el autovacuum.**
* **Justificación:** Tablas que se llenan y se vacían miles de veces por hora marean al motor. Si a las 12:00 PM la tabla tiene 1 millón de filas y a las 12:05 PM tiene 0 filas, las estadísticas se pudren en minutos. Para estas tablas, debes bajar agresivamente el umbral del autovacuum (`autovacuum_analyze_scale_factor = 0.01`) para que el motor las audite casi en tiempo real.

#### Escenario D: Tras la Creación de un Índice por Expresión

* **Cuándo ejecutarlo:** **Justo después de crear el índice.**
* **Justificación:** Si creas un índice basado en una función (ej. `CREATE INDEX idx_mail ON usuarios (LOWER(email));`), el motor no conoce las estadísticas de la salida de esa función. Si no haces un `ANALYZE` inmediatamente, PostgreSQL jamás usará ese índice.

**El Veredicto Final:**
El `ANALYZE` es tu francotirador. No se dispara contra paredes (tablas estáticas), no se usa a ciegas (para eso está el autovacuum), pero cuando haces movimientos masivos de tropas (ETL/Cargas masivas), es la orden obligatoria que debes dar antes de permitir que las aplicaciones enemigas (usuarios) comiencen a realizar consultas.


----
# Preguntas frecuentes : 




## **¿Por qué ANALYZE no tarda 1,000 veces más en una tabla de 10 TB que en una de 10 GB en PostgreSQL?**

No, no tarda lo mismo, pero tampoco tarda proporcionalmente  1,000 veces más.  
 
### 1. Comando `ANALYZE` (Recolección de estadísticas)

El comando `ANALYZE` estándar **no lee toda la tabla**. PostgreSQL utiliza un algoritmo de muestreo aleatorio (*random sampling*) basado en el parámetro `default_statistics_target`.

* **Comportamiento:** Por defecto (`default_statistics_target = 100`), PostgreSQL lee únicamente unas **30,000 páginas/bloques aleatorios** de la tabla, sin importar si esta mide 50 GB, 1 TB o 20 TB.
* **Diferencia de tiempo:**
* En una tabla de **10 GB**, las páginas leídas probablemente estén guardadas en la memoria caché RAM (`shared_buffers` / *OS cache*), por lo que el comando tarda **milisegundos o pocos segundos**.
* En una tabla de **10 TB**, las muestras aleatorias obligan al disco a realizar lecturas físicas no secuenciales (*random I/O*). El tiempo aumenta por la latencia del almacenamiento subyacente, tardando desde **algunos segundos hasta un par de minutos**, pero **no** horas.

> **Excepción:** Si aumentas manualmente el `statistics_target` en columnas específicas para mayor precisión (ej. de 100 a 1000), el tamaño de la muestra crece y el tiempo de ejecución aumentará en consecuencia.

---



🔬 **El ANALYZE y las Tuplas Muertas**

**Tu deducción:** *"¿El analyze toma las tuplas muertas y no las toma para sus estadísticas?"*

**Habla Pedro (Ingeniero Core):**
Es 100% correcto. El comando `ANALYZE` escanea una muestra aleatoria de páginas (bloques de 8 KB) en el disco duro. Si al abrir un bloque se encuentra con que el 80% de ese bloque son tuplas muertas (basura de `UPDATEs` o `DELETEs`), el motor ignora esas tuplas porque no le sirven al optimizador para calcular la distribución real de los datos vivos.

**El problema físico:** Como el `ANALYZE` tiene un límite de bloques para leer (basado en el parámetro `default_statistics_target`), si lee bloques llenos de basura, su muestra de datos útiles será pequeñísima. Terminará calculando estadísticas mediocres basadas en muy pocos datos reales.

Por eso, como bien dedujiste, hacerle `ANALYZE` a una tabla repleta de tuplas muertas es un desperdicio de I/O que arrojará resultados imprecisos.
 
🏛️ **CONCLUSIÓN 2: El Mantenimiento Desacoplado (La Regla Vanguard)**

**Tu deducción:** *"¿En este caso es mejor hacer entonces VACUUM ANALYZE solo a tablas que ocupen vacuum, y después hacer un ANALYZE solo a tablas que lo ocupen?"*

**Habla Marcos (Arquitecto Senior):**
Esa es la regla de oro de la élite de bases de datos. Acoplar los comandos (escribir siempre `VACUUM ANALYZE tabla;`) es un vicio de los DBAs novatos. Son dos operaciones físicas completamente distintas que resuelven problemas distintos.

Debes separar tu orquestador en dos cerebros independientes basándote en la física del daño:

| Tipo de Daño en la Tabla | ¿Qué generó el daño? | La Acción Correcta | Justificación del DBA SQUAD |
| --- | --- | --- | --- |
| **Solo Inserciones Masivas** | `INSERT` masivo o Copy (Ej. Cargas de ETL nocturnas). | **SOLO ANALYZE** | Hay cero tuplas muertas. Hacer un Vacuum aquí es quemar disco duro a lo tonto. El Analyze es ultra rápido y recalcula el volumen nuevo. |
| **Alta Volatilidad (Fragmentación)** | `UPDATE` o `DELETE` masivos (Ej. Limpieza de historial). | **VACUUM y después ANALYZE** | Hay muchísima basura. Primero barres la casa (`VACUUM` libera el espacio y limpia la muestra), y luego mides la casa limpia (`ANALYZE`). |
| **Tabla Estática Histórica** | Los datos ya no van a cambiar nunca más. | **VACUUM FREEZE ANALYZE** | Se limpia, se toman estadísticas perfectas, y se "congela" para que el motor jamás vuelva a gastar CPU en ella. |

 
🛡️ **EL VEREDICTO DEL GATEKEEPER**

Tu conclusión es brillante. No dispares artillería pesada (`VACUUM`) donde solo necesitas un francotirador estadístico (`ANALYZE`).

Tu orquestador inteligente (`sp_orchestrate_maintenance`) debe tener métricas de disparo separadas:

* **Gatillo de VACUUM:** Si `n_dead_tup` (tuplas muertas) supera el 15% -> Ejecuta `VACUUM`.
* **Gatillo de ANALYZE:** Si `n_mod_since_analyze` (filas insertadas/modificadas) supera el 10% -> Ejecuta `ANALYZE`.

Si una tabla sufre un borrado masivo, activará ambos gatillos. Si solo recibe inserciones, activará solo el segundo. Eficiencia pura.




###  ¿Cómo interactúan el VM y el ANALYZE?

Para entender esto, hay que separar dos conceptos físicos: **Qué bloques lee** y **Cuánto CPU gasta al leerlos**.

**1. El Mapa de Visibilidad NO altera la ruta (La Muestra es Inviolable)**
El algoritmo matemático de `ANALYZE` (basado en el Algoritmo Z de Vitter) necesita una muestra 100% aleatoria y uniforme para que la estadística sea real. Por lo tanto, el Mapa de Visibilidad **no le dice a ANALYZE qué bloques leer**. Si el algoritmo decide aleatoriamente que debe leer el bloque 500, va a leer el bloque 500, sin importarle lo que diga el Mapa de Visibilidad.

**2. El Mapa de Visibilidad SÍ altera el consumo de CPU (El Fast-Path)**
Aquí está la magia técnica. Cuando `ANALYZE` abre el bloque 500 que eligió al azar, tiene que revisar fila por fila para ver si están vivas o muertas, leyendo los IDs de transacción (`xmin` y `xmax`) y comparándolos con el *Snapshot* actual del motor. Esto consume muchísima CPU.

Pero, **si tú hiciste un VACUUM antes**, ese VACUUM actualizó el Mapa de Visibilidad y le puso una "bandera" al bloque 500 diciendo: *"Este bloque es All-Visible (Todas sus filas están vivas y confirmadas)"*.
Cuando `ANALYZE` abre ese bloque y ve esa bandera, **se salta por completo las validaciones de control de concurrencia (MVCC)**. No revisa los IDs de transacción; simplemente captura los datos al vuelo con un gasto de CPU casi de cero.





----


 

###   1. El Radar de Telemetría (La Vista Oficial)


PostgreSQL tiene una vista nativa en memoria RAM que actúa como la caja negra del servidor: `pg_stat_user_tables`. Ahí vive toda la información forense de tus tablas.

No necesitas inventar nada, aquí tienes la **Consulta de Auditoría de Grado Diamante**. Este script calcula dinámicamente el porcentaje de desfase estadístico (*Drift*) de todas tus tablas y te las ordena desde la más crítica hasta la más sana.

```sql
SELECT 
    schemaname || '.' || relname AS tabla,
    n_live_tup AS filas_vivas,
    n_dead_tup AS filas_muertas,
    n_mod_since_analyze AS modif_desde_ultimo_analyze,
    -- Calculamos el % de desfase (modificaciones / filas vivas)
    COALESCE(ROUND((n_mod_since_analyze::numeric / NULLIF(n_live_tup, 0)) * 100, 2), 0) AS porcentaje_desfase,
    last_analyze AS ultimo_analyze_manual,
    last_autoanalyze AS ultimo_analyze_automatico,
    -- Vemos cuándo fue la última vez que el motor la tocó en general
    GREATEST(last_analyze, last_autoanalyze) AS fecha_estadistica_mas_reciente
FROM 
    pg_stat_user_tables
WHERE 
    n_live_tup > 0 -- Filtramos tablas vacías para no hacer ruido
ORDER BY 
    porcentaje_desfase DESC;

```

**¿Qué estás viendo aquí?**

* **`n_live_tup`:** Cuántos registros vivos tiene tu tabla hoy.
* **`n_mod_since_analyze`:** La métrica más importante. Cuenta cuántos `INSERT`, `UPDATE` o `DELETE` han ocurrido desde la última vez que alguien (o el sistema) hizo un `ANALYZE`.
* **`GREATEST(...)`:** Te dice la fecha y hora exacta de la última fotografía estadística, sin importar si la tomaste tú a mano o el autovacuum en segundo plano.
 

### 🧮 2. La Matemática del Disparo (¿Cuándo ocupa ANALYZE?)

Preguntaste qué cantidad o porcentaje de filas se toman para considerar que una tabla *necesita* un `ANALYZE`. El motor de PostgreSQL (específicamente el demonio `autovacuum`) no adivina, usa una ecuación matemática estricta basada en dos parámetros de configuración:

**Fórmula de disparo:**
`Umbral = autovacuum_analyze_threshold + (autovacuum_analyze_scale_factor * tuplas_vivas)`

Por defecto en PostgreSQL, estos valores son:

* `autovacuum_analyze_threshold` = **50 filas** (Umb_Base)
* `autovacuum_analyze_scale_factor` = **0.1** (10% de Factor_Escala)
* Ejem. Tuplas vivas 100,000


**Ejemplo táctico:**
Si tu tabla tiene **100,000 filas vivas** (`n_live_tup`), la ecuación dice:
`50 + (0.10 * 100,000) = 10,050`

Esto significa que cuando la columna `n_mod_since_analyze` de la consulta de Mauricio llegue a **10,050**, el motor dirá: *"¡Alerta! Llegamos al límite, disparen un Auto-Analyze de inmediato"*. En la práctica, esto equivale a esperar que cambie **un poco más del 10%** de la tabla.


###  De forma automática (`Autovacuum / Autoanalyze`)

PostgreSQL ejecuta el análisis de forma transparente según la actividad de tuplas.

* Se controla mediante los parámetros del `postgresql.conf`:
* `autovacuum = on`
* `autovacuum_analyze_threshold = 50`
* `autovacuum_analyze_scale_factor = 0.1`


* Puedes forzar una agresividad diferente **por cada tabla**:
```sql
ALTER TABLE mi_tabla SET (
    autovacuum_analyze_scale_factor = 0.02,
    autovacuum_analyze_threshold = 100
);
```
 
### 🛡️ 3. La Matriz de Riesgo VANGUARD (Rangos de Salud)


Ahora que tienes los números, te voy a enseñar a interpretarlos como un director de infraestructura. Basado en el `porcentaje_desfase` de la consulta anterior, esta es la regla de fuego para intervenir:

| Rango de Desfase (%) | Estado Operativo | Diagnóstico y Acción del DBA SQUAD |
| --- | --- | --- |
| **0% a 5%** | **INSIGNIFICANTE** (Diamante) | **Acción:** Ninguna. El optimizador tiene un mapa matemáticamente perfecto de los datos. Tus índices se están usando al 100% de su capacidad. |
| **5% a 10%** | **NORMAL** (Vigilancia) | **Acción:** Ninguna. Es el desgaste natural de una base de datos viva. El motor sabe que los datos están cambiando, pero el margen de error estadístico aún es tolerable para los planes de ejecución. |
| **10% a 20%** | **MANTENIMIENTO REQUERIDO** | **Acción:** Disparo de orquestador. En teoría, el autovacuum ya debería haber saltado al cruzar el 10%. Si tienes tablas atascadas aquí, significa que tus configuraciones por defecto no están dando abasto. Requiere un `ANALYZE` dirigido. |
| **> 20%** | **CRÍTICO** (Peligro de Caída) | **Acción:** Intervención manual inmediata. Las estadísticas están podridas. El Optimizador está ciego y podría empezar a elegir *Sequential Scans* masivos en lugar de usar índices, congelando la CPU del servidor. Tu autovacuum está ahogado. |



----


##  *"¿Qué pasa con la vista `pg_stat_user_tables` si se reinicia el servidor, ya que está en la memoria RAM?"*.


### 🧠 EL MECANISMO INTERNO: RAM vs. Disco
 
Tienes razón, mantener estadísticas en vivo (como `n_mod_since_analyze`) requiere velocidad absoluta. Si el motor escribiera en el disco duro cada vez que ocurre un simple `UPDATE` en una tabla, el rendimiento del servidor se desplomaría. Por eso, PostgreSQL (a partir de la versión 15) mantiene todas estas métricas exclusivamente en la **Memoria Compartida (Shared Memory / RAM)**.

Pero PostgreSQL no es ingenuo. El comportamiento de esta vista dependerá exactamente de **cómo** se reinicie el servidor.
 

### 🔌 ESCENARIO 1: El Reinicio Limpio (Clean Shutdown)
 
Si ejecutas un reinicio ordenado y diplomático desde el sistema operativo (por ejemplo: `systemctl restart postgresql` o `pg_ctl stop`), PostgreSQL activa su protocolo de apagado seguro.

1. El motor detiene las conexiones nuevas.
2. Termina las transacciones en curso.
3. **El Salvavidas:** Antes de apagar la memoria RAM, el motor "imprime" todas las métricas de `pg_stat_user_tables` en un archivo físico en el disco duro (ubicado en el directorio `pg_stat` dentro de tu *data directory*).
4. Cuando el servidor vuelve a encender, lee ese archivo físico, lo vuelve a cargar en la memoria RAM y elimina el archivo.
5. **Resultado:** **No pierdes absolutamente nada.** Tu contador de modificaciones seguirá exactamente donde se quedó.
 
### 💥 ESCENARIO 2: La Caída Catastrófica (Hard Crash)
 
Aquí es donde la arquitectura se pone a prueba. Si el servidor sufre un corte de energía físico, si el sistema operativo se queda sin memoria y el *OOM Killer* asesina el proceso de PostgreSQL, o si un administrador novato ejecuta un `kill -9` (terminación forzada):

1. PostgreSQL no tiene tiempo de ejecutar su protocolo de apagado.
2. La Memoria Compartida (RAM) se volatiliza al instante.
3. El archivo de salvavidas en el disco duro **jamás se crea**.
4. Al encender de nuevo, PostgreSQL busca el archivo de estadísticas, no lo encuentra, e inicia la vista de memoria desde cero.
5. **Resultado:** **Amnesia Estadística.** Todos los contadores (`n_live_tup`, `n_mod_since_analyze`, etc.) **se resetean a CERO**.

 

### 🛡️ ¿Qué pasa si se reinicia un servidor por algun problema?
 

Este es el verdadero peligro que asusta a los DBAs novatos. Si el servidor sufre un *Hard Crash* y las estadísticas se resetean a cero, **el Autovacuum se vuelve ciego**.

Imagina que una tabla tuya tenía 5 millones de modificaciones y estaba a punto de activar el Autovacuum. Se va la luz, el servidor reinicia, y el contador vuelve a cero. El motor ahora cree que esa tabla está "limpia" y no la va a analizar hasta que acumule otros 5 millones de modificaciones nuevas. Tu optimizador tomará decisiones desastrosas.

**La Regla de Fuego VANGUARD:**
Si tu servidor sufre una caída abrupta o un *Hard Crash*, la primera orden táctica antes de abrir las conexiones a los usuarios es forzar la reconstrucción del mapa estadístico.

Debes lanzar un análisis global a nivel de base de datos desde la terminal:

```bash
### Ejecuta el mantenimiento ANALYZE STAGES
    nohup bash -c '
    export PGPASSWORD="-xm3nxhu5hI:9P,"

    export PGOPTIONS="-c max_parallel_maintenance_workers=8 -c maintenance_work_mem=15GB -c tcp_keepalives_idle=5 -c tcp_keepalives_interval=10 -c tcp_keepalives_count=3"

    echo "=== INICIO VACUUM / ANALYZE: $(date) ==="

    /usr/pgsql-15/bin/vacuumdb \
    -h 10.0.0.100 \
    -U postgres \
    -d db_test \
    -j 18 \
    #-v \
    -e \
    --analyze-in-stages # Post-restauración, migraciones o recuperación de desastres.
    # --analyze-only # Mantenimiento de rutina nocturno.
    
    echo "=== FIN VACUUM / ANALYZE: $(date) ==="
    ' > analyze_20260803.log 2>&1 &    
```

*(Este comando lanza hilos en paralelo para recalcular el `ANALYZE` de todas tus tablas y reconstruir la memoria RAM forense antes de que el tráfico productivo golpee al optimizador ciego).*



---

 
### ¿Cómo funciona la toma de muestras?

* **Lectura por bloques (Filas), no por columnas aisladas:** PostgreSQL no lee las columnas por separado; selecciona un número de **filas al azar** de toda la tabla (basado en el parámetro `default_statistics_target`). Una vez elegida esa muestra de filas, analiza los valores de todas sus columnas.
* **Columnas ignoradas:** La única excepción son las columnas con tipos de datos que no tienen definidos operadores de comparación ni clases de operadores B-tree (algo muy poco común, como ciertos tipos de datos personalizados o binarios sin funciones de ordenamiento).
 

### ¿Cuándo conviene especificar columnas?

Especificar columnas (`ANALYZE mi_tabla (col1, col2);`) es una técnica de optimización útil en dos casos específicos:

1. **Tablas con columnas muy pesadas (`TEXT`, `JSONB`, `BYTEA` grandes):** Analizar estas columnas requiere procesar mucha memoria (TOAST). Si solo usas esas columnas para mostrar datos y nunca en cláusulas `WHERE` o `JOIN`, puedes omitirlas analizando solo las columnas indexadas o de filtro.
2. **Tablas con decenas o cientos de columnas:** Si solo un par de columnas reciben constantes `UPDATE` o `WHERE`, analizar la tabla completa en tablas muy grandes consume E/S de disco innecesariamente.

 

### Configuración por columna

Si quieres que `ANALYZE` (incluso el automático) recolecte estadísticas de todas las columnas pero con **distinto nivel de detalle**, puedes cambiar el objetivo por columna en lugar de omitirlas:

```sql
-- Hacer que solo una columna crítica recolecte más muestras
ALTER TABLE mi_tabla ALTER COLUMN columna_critica SET STATISTICS 500;

-- Reducir las muestras de una columna secundaria para que ANALYZE sea más rápido
ALTER TABLE mi_tabla ALTER COLUMN columna_secundaria SET STATISTICS 10;

```


---


### Analuyze vía Línea de Comandos del Sistema Operativo (`vacuumdb`)

Es un ejecutable de PostgreSQL que permite correr el proceso desde la terminal de Bash/CMD sin entrar a `psql`. Ideal para **scripts de mantenimiento o crontabs**.

* **En una base de datos específica:**
```bash
vacuumdb -z -d nombre_bd

```


* **En una sola tabla de una BD:**
```bash
vacuumdb -z -t mi_tabla nombre_bd

```


* **En TODAS las bases de datos del cluster:**
```bash
vacuumdb -z --all

```


* **En paralelo (múltiples núcleos)** *(PostgreSQL 9.5+)*:
```bash
vacuumdb -z -j 4 nombre_bd

```

*(Nota: La bandera `-z` es la equivalente a `--analyze`)*




