 
# 🚀 MANUAL VANGUARD: LA RECONSTRUCCIÓN ESTRUCTURAL (`REINDEX`)

### 1. ¿Qué es `REINDEX` y por qué surge la necesidad?

Para entender este comando, debes entender que un índice en PostgreSQL (por defecto) es una estructura matemática llamada **B-Tree (Árbol B)**.

---

Cuando haces consultas, el motor no lee la tabla, navega por este árbol de arriba hacia abajo para encontrar la dirección física de tus datos en milisegundos.
El problema es que cuando haces actualizaciones masivas (`UPDATE` o `DELETE`), las "ramas" y "hojas" de este árbol se llenan de huecos muertos. El árbol se vuelve asimétrico, profundo y fragmentado (*Index Bloat*). El motor tiene que dar más saltos lógicos y leer más bloques físicos para encontrar el mismo dato.

**`REINDEX` es el leñador del motor.**
Es el comando que toma ese árbol enfermo, lo destruye por completo, y construye un árbol matemático nuevo, denso, perfectamente balanceado y sin un solo byte de basura.

### 2. ¿Cómo funciona internamente? (El Algoritmo de Reconstrucción)

A diferencia del `VACUUM` que solo limpia, `REINDEX` es una operación de reescritura física desde cero. Funciona en cuatro pasos tácticos:

1. **Lectura de la Tabla Base (Heap Scan):** El motor ignora el índice viejo. Va directamente a la tabla real, extrae los datos de la columna indexada y sus direcciones físicas (`ctid`).
2. **Ordenamiento en Memoria:** Toma todos esos datos y los ordena en la memoria RAM utilizando el espacio asignado por el parámetro `maintenance_work_mem`.
3. **Construcción del Nuevo Archivo:** Crea un archivo físico nuevo en el disco duro y va ensamblando el árbol B-Tree perfecto, bloque por bloque, llenando las páginas de memoria con máxima densidad.
4. **El Intercambio (Swap & Drop):** Al igual que `VACUUM FULL`, realiza un cambio de identidad física. Actualiza el catálogo (`relfilenode`) para que la base de datos apunte al archivo nuevo, y finalmente borra el archivo del índice viejo, devolviendo el espacio libre al Sistema Operativo Linux.

### 3. ¿Genera Bloqueos en Producción?

Aquí radica la diferencia entre la caída de un servicio corporativo y un mantenimiento invisible.

* **`REINDEX` (Estándar) - BLOQUEO LETAL:** Adquiere un bloqueo exclusivo sobre el índice y un bloqueo compartido sobre la tabla. **Detiene todas las escrituras**. Nadie podrá hacer un `INSERT`, `UPDATE` o `DELETE` en la tabla mientras dure la reconstrucción. En una tabla transaccional masiva, esto es inaceptable.
* **`REINDEX CONCURRENTLY` - EL ESTÁNDAR VANGUARD:** Es la evolución táctica. Construye el índice nuevo en segundo plano mientras los usuarios siguen leyendo y escribiendo en la tabla a máxima velocidad. Requiere más CPU, más disco temporal y hace dos escaneos de la tabla, pero garantiza **Cero Downtime (Cero tiempo de inactividad)**.

### 4. Ventajas, Desventajas y Riesgos

El mantenimiento de índices es vital, pero la reconstrucción concurrente tiene sus propios peligros.

| Aspecto | Detalle Técnico |
| --- | --- |
| **VENTAJA 1: Recuperación de Velocidad** | Reduce drásticamente la profundidad del árbol matemático y el I/O de lectura, acelerando brutalmente los *Index Scans*. |
| **VENTAJA 2: Recuperación de Disco** | Devuelve los Gigabytes de "aire" (espacio muerto del índice) al Sistema Operativo, encogiendo el almacenamiento. |
| **DESVENTAJA 1: Consumo Temporal de Disco** | Necesitas espacio libre extra. Mientras se construye, tendrás el índice viejo y el nuevo coexistiendo en el disco duro. |
| **RIESGO: El Índice Zombi (INVALID)** | Si lanzas un `REINDEX CONCURRENTLY` y falla a la mitad (por falta de espacio o un error), el motor cancela la operación pero deja un índice "inválido" en el catálogo. Debes intervenir manualmente para hacer un `DROP INDEX` de esa basura. |

### 5. Reglas de Fuego: Cuándo Ejecutarlo y Cuándo NO

Basado en la doctrina del DBA SQUAD, así es como debes orquestar esta herramienta:

#### Escenario A: Mantenimiento Diario Preventivo

* **Recomendación:** **NO LO TOQUES.**
* **Justificación:** Los árboles B-Tree en PostgreSQL son excelentes reciclando páginas vacías si tu Autovacuum está bien afinado. Reconstruir índices "por si acaso" quema ciclos de CPU y satura los discos duros inútilmente.

#### Escenario B: Después de ejecutar un `VACUUM FULL`

* **Recomendación:** **JAMÁS LO EJECUTES.**
* **Justificación:** Es redundancia técnica. Como ya vimos en su manual, `VACUUM FULL` reconstruye implícitamente **todos** los índices de la tabla desde cero. Si lanzas un `REINDEX` después, estarás obligando al motor a reconstruir un árbol que acaba de ser creado a la perfección hace cinco minutos.

#### Escenario C: Fragmentación Crítica comprobada (> 40% de Bloat)

* **Cuándo ejecutarlo:** **En ventanas de bajo tráfico, SIEMPRE de forma concurrente.**
* **Justificación:** Si tu tabla de auditoría sufre purgas masivas mensuales, su índice se llenará de huecos que el Autovacuum no podrá encoger. Usa `REINDEX INDEX CONCURRENTLY nombre_indice;` para reconstruirlo en caliente y recuperar el rendimiento sin tirar las operaciones del negocio.

#### Escenario D: Corrupción de Datos o Falla de Hardware

* **Cuándo ejecutarlo:** **Intervención de Emergencia.**
* **Justificación:** Si los logs del servidor de Linux arrojan errores de I/O de hardware, o las consultas fallan con errores de *"index row requires XX bytes, maximum size is YY"*, el índice está físicamente corrupto. Un `REINDEX` estándar inmediato forzará al motor a leer la tabla limpia y reconstruir el mapa de navegación sano.

---

### 🧠 Preguntas Frecuentes y Micro-Arquitectura Forense

**"¿Cómo sé matemáticamente si mi índice necesita un REINDEX en lugar de adivinar?"**
En VANGUARD no operamos a ciegas. Usamos la extensión nativa `pgstattuple`. Si le pasas el nombre de tu índice a la función `pgstatindex('mi_indice')`, te devolverá una métrica vital: `avg_leaf_density`. Si esa densidad cae por debajo del 50%, significa que tu árbol es más aire que datos. Es momento de reconstruir.

**"Lanzé un REINDEX CONCURRENTLY, se cortó mi conexión de red a la mitad, y ahora veo un índice con el sufijo `_ccnew` en mi base de datos. ¿Qué hago?"**
Acabas de presenciar el Riesgo del "Índice Zombi". Como la operación se interrumpió, PostgreSQL abortó el cambio, dejó el índice viejo funcionando, pero dejó la construcción del nuevo a la mitad. Ese índice `_ccnew` está marcado como `INVALID` en el catálogo y no sirve para nada, pero está consumiendo Gigabytes de disco. Debes conectarte de inmediato y ejecutar un `DROP INDEX CONCURRENTLY` sobre el zombi para liberar el almacenamiento.

**"¿REINDEX afecta a mis archivos WAL y a la replicación?"**
Absolutamente. La creación del nuevo índice es una escritura física masiva. Cada bloque del nuevo árbol de datos se escribe en el archivo WAL y se transmite por la red hacia tus réplicas. Si el índice pesa 20 GB, generarás al menos 20 GB de tráfico de replicación. Planifica la concurrencia asumiendo este impacto en tu red de alta disponibilidad.


---

# **bloat en indices**

**los índices en PostgreSQL también sufren de *bloat* (hinchamiento/fragmentación)**, y en muchos casos el problema es más severo que en las propias tablas.

### 1. ¿Por qué ocurre el *bloat* en los índices?

Cuando realizas operaciones de `UPDATE` o `DELETE` en una tabla, el motor no elimina los datos físicamente de inmediato. En los índices (especialmente los B-Tree):

* Las claves antiguas que apuntan a registros eliminados quedan marcadas como muertas.
* Las operaciones intensivas de inserción o modificación dividen las páginas del índice (*page splits*).
* Si estas páginas divididas quedan medio vacías y el patrón de datos no vuelve a rellenarlas exactamente en ese rango, **el espacio queda desperdiciado de forma permanente dentro de la estructura de árbol del índice**.

---

### 2. ¿Cómo funciona `VACUUM` en los índices?

El comportamiento del espacio recuperado varía según la operación:

| Operación | ¿Cómo afecta al índice? | ¿Reutiliza el espacio? | ¿Reduce el tamaño del archivo en disco? |
| --- | --- | --- | --- |
| **`VACUUM` (Normal/Autovacuum)** | Limpia las punteros a tuplas muertas en las páginas del índice y marca la página como utilizable. | **Sí.** Si ingresan nuevos datos cuyos valores correspondan a esa misma página, PostgreSQL reutilizará ese espacio. | **No.** El archivo `.ibd`/filenode del índice en disco **no reduce su tamaño**. El espacio inflado se queda reservado dentro del índice. |
| **`REINDEX` / `VACUUM FULL**` | Destruye el índice antiguo y lo reconstruye desde cero de forma contigua. | **Sí.** Elimina todo el espacio desperdiciado por completo. | **Sí.** Libera el espacio en el sistema de archivos del sistema operativo inmediatamente. |

---

### 3. El problema del *Bloat* irreversible mediante `VACUUM` simple

En tablas con alta volatilidad o cuando los valores insertados son monótonos/crecientes (como un `TIMESTAMP` o una secuencia `SERIAL`):

1. `VACUUM` eliminará los punteros viejos.
2. Sin embargo, las claves viejas estaban en páginas con valores bajos (ej. IDs del 1 al 1000).
3. Si los nuevos datos que estás insertando tienen IDs más altos (ej. IDs del 5000 en adelante), **PostgreSQL jamás volverá a insertar datos en las páginas vacías del rango bajo**.
4. Esas páginas quedan "congeladas" y vacías dentro del índice, causando un *bloat* que `VACUUM` estándar no puede solucionar.

---

### 4. ¿Cómo solucionar el *bloat* en índices sin bloquear la base de datos?

Hacer `VACUUM FULL` o `REINDEX` tradicional bloquea las lecturas y escrituras en la tabla (`ACCESS EXCLUSIVE LOCK`), lo cual no es viable en producción.

La solución recomendada en entornos activos es reconstruir el índice de forma concurrente:

```sql
-- En PostgreSQL 12 o superior:
REINDEX INDEX CONCURRENTLY nombre_del_indice;

-- O reindexar la tabla entera sin bloquear lecturas ni escrituras:
REINDEX TABLE CONCURRENTLY nombre_de_la_tabla;

```

> **Nota:** `REINDEX CONCURRENTLY` crea una versión nueva del índice en segundo plano mientras la tabla sigue recibiendo transacciones, y intercambia el índice viejo por el nuevo al terminar sin causar caídas de servicio.
