 

### 1. ¿Qué es `VACUUM FULL` y por qué surge la necesidad?

Para entender por qué existe el `VACUUM FULL`, primero debes entender la gran limitación del `VACUUM` estándar: **el estándar limpia la basura, pero no encoge el archivo**.

Imagina un edificio de 100 pisos (tu tabla). Si borras los datos de 90 pisos, el `VACUUM` normal limpiará esos pisos y los dejará vacíos para futuros inquilinos. Pero el edificio físicamente sigue midiendo 100 pisos de altura, ocupando todo ese espacio en el disco duro de tu servidor (*Table Bloat* masivo).

¿Qué pasa si necesitas urgentemente devolverle esos 90 pisos de espacio al Sistema Operativo (Linux) porque tu disco duro está al 99% de capacidad? Aquí nace la necesidad del **`VACUUM FULL`**. Es el comando que demole el edificio viejo y construye uno nuevo, compactado y del tamaño exacto de los datos que realmente están vivos.

### 2. ¿Cómo funciona internamente? (El Algoritmo)

El secreto más peligroso de `VACUUM FULL` es que **no es un proceso de limpieza, es un proceso de reescritura física total desde cero**. Funciona en cuatro pasos tácticos pesados:

1. **Creación de un Archivo Espejo:** El motor pide espacio nuevo al sistema operativo y crea un archivo físico en blanco junto al archivo original de tu tabla.
2. **Copia de Supervivientes:** Lee la tabla vieja bloque por bloque, extrae **únicamente** las tuplas vivas (ignorando toda la basura) y las inserta de forma densa y compacta en el archivo nuevo.
3. **Reconstrucción de Índices:** Como las filas cambiaron de dirección física (se mudaron a un archivo nuevo), **todos** los índices asociados a la tabla quedan inservibles. El motor tiene que reconstruir cada índice desde cero.
4. **El Intercambio Forense (`Swap & Drop`):** Aquí radica la magia del motor. En PostgreSQL, tu tabla tiene una identidad lógica (`oid`) y un nombre de archivo físico en el disco (`relfilenode`).
* Durante el intercambio, PostgreSQL actualiza el catálogo interno apuntando al nuevo archivo y borra el viejo.
* **El Truco de Auditoría:** El `oid` se mantiene intacto para que no se rompan tus llaves foráneas, permisos ni vistas. Pero el `relfilenode` cambia porque el archivo es nuevo. Si consultas la tabla de sistema (`SELECT oid, relfilenode FROM pg_class`) y ves que ambos números son idénticos, **significa que esa tabla jamás ha sido reconstruida desde que se creó**. Si son diferentes, la tabla ya sufrió un `VACUUM FULL` o un `TRUNCATE`.

### 3. ¿Genera Bloqueos en Producción?

Esta es la advertencia de fuego que define si eres un DBA Senior o un novato a punto de causar un desastre. La respuesta es: **SÍ, ES UN BLOQUEO ABSOLUTO Y LETAL.**

* **El Bloqueo (Lock):** `VACUUM FULL` adquiere el nivel de bloqueo más agresivo que existe en PostgreSQL: `AccessExclusiveLock`.
* **Lo que SÍ bloquea:** Detiene absolutamente **TODO**. Ninguna aplicación, usuario o proceso podrá hacer `INSERT`, `UPDATE`, `DELETE`, **ni siquiera un simple `SELECT**` a esa tabla.
* **El Impacto:** Si lanzas este comando a una tabla de 500 GB, todo el tráfico de tu aplicación hacia esa tabla se quedará colgado (en estado de espera) durante los minutos u horas que tarde en reescribirse el archivo. En términos de negocio, esto significa una **caída total del servicio (Downtime)**.

* **Nota** : Si tu tabla pesa 10 GB debes de 

### 4. Ventajas, Desventajas y Riesgos

Este comando no es un mantenimiento de rutina; es una cirugía mayor a corazón abierto.

| Aspecto | Detalle Técnico |
| --- | --- |
| **VENTAJA 1: Recuperación Real de Disco** | Es el único comando nativo que devuelve los Gigabytes muertos directamente al Sistema Operativo, salvándote de un colapso de almacenamiento. |
| **VENTAJA 2: Defragmentación Perfecta** | Los datos quedan ordenados físicamente de forma impecable, lo que acelera masivamente las consultas de escaneo secuencial (`Seq Scan`). |
| **DESVENTAJA 1: Downtime Absoluto** | Bloquea todas las lecturas y escrituras. Requiere ventanas de mantenimiento programadas en la madrugada y autorización de negocio. |
| **RIESGO: La Paradoja del Espacio (Out of Space)** | Como PostgreSQL crea una copia exacta de los datos vivos antes de borrar el original, **necesitas espacio extra en disco para ejecutarlo**. Si tu disco está al 80% y lanzas `VACUUM FULL`, el servidor colapsará por falta de espacio al intentar crear el archivo nuevo. |

### 5. Reglas de Fuego: Cuándo Ejecutarlo y Cuándo NO (Escenarios y Horarios)

Basado en la doctrina del DBA SQUAD, así es como debes programar o invocar esta artillería pesada:

#### Escenario A: Tablas Transaccionales Normales (Mantenimiento de Rutina)

* **Recomendación:** **JAMÁS LO EJECUTES.**
* **Justificación:** Usar `VACUUM FULL` como mantenimiento semanal o mensual es un vicio destructivo. Para eso está el Autovacuum. Si tienes que usar `FULL` de forma rutinaria, tu arquitectura o tu configuración del Autovacuum estándar están mal diseñadas.

#### Escenario B: Después de un DELETE del 10% - 20% de la tabla

* **Recomendación:** **NO LO TOQUES.**
* **Justificación:** Deja el espacio como "cráteres vacíos". El `VACUUM` normal los registrará en el Free Space Map (FSM) y los próximos `INSERTs` de tu aplicación rellenarán esos huecos naturalmente sin necesidad de tirar el sistema.

#### Escenario C: Inflación Crítica (Table Bloat > 60%) y Peligro de Disco Lleno

* **Cuándo ejecutarlo:** **Solo en ventanas de mantenimiento de madrugada (Corte de Servicio).**
* **Justificación:** Si borraste millones de registros históricos y tienes cientos de Gigabytes de puro aire que Linux necesita urgentemente, coordina una ventana de caída con el negocio, corta el tráfico de la aplicación y lanza el `VACUUM FULL` para encoger el archivo.

#### Escenario D: El Estándar VANGUARD (La Alternativa Concurrente)

* **Recomendación:** **Usa extensiones de terceros como `pg_repack` o `pg_squeeze`.**
* **Justificación:** En infraestructuras de élite con Alta Disponibilidad 24/7, no podemos darnos el lujo de bloquear una tabla por horas. Extensiones como `pg_repack` hacen exactamente lo mismo que el `VACUUM FULL` (crean un archivo nuevo y recuperan espacio), pero **lo hacen en caliente**, mediante triggers temporales, permitiendo que los usuarios sigan leyendo y escribiendo sin bloqueos paralizantes.

---

# Preguntas frecuentes

### *"¿Por qué `VACUUM FULL` falla diciendo 'No space left on device' si precisamente lo estoy usando para liberar espacio?"*

**Por la Arquitectura de Reescritura.**
A diferencia del `VACUUM` estándar que limpia "in-place" (en el mismo lugar), el `VACUUM FULL` requiere crear una tabla espejo. Si tu tabla pesa 100 GB, de los cuales 50 GB son datos vivos y 50 GB son basura, el motor necesita al menos **50 GB de espacio extra disponible en el disco duro** temporalmente para escribir el archivo nuevo antes de poder borrar el viejo de 100 GB. Si solo te quedan 10 GB libres en el servidor, el comando fracasará por falta de espacio físico.

### *"Si hago un `VACUUM FULL`, ¿tengo que hacer también un `REINDEX` a mis tablas?"*

**NO.**
El comando `VACUUM FULL` reconstruye automáticamente todos los índices asociados a la tabla como parte de su proceso interno. Ejecutar un `REINDEX` después sería una pérdida total de tiempo y CPU. Sin embargo, **SÍ debes ejecutar un `ANALYZE**` después de que termine, ya que la distribución física de los datos ha cambiado drásticamente y el Optimizador necesita nuevas estadísticas para sus planes de ejecución.

### *"¿Por qué el DBA SQUAD recomienda `pg_repack` en lugar del comando nativo?"*

Porque el diseño nativo del bloqueo `AccessExclusiveLock` es inaceptable para corporaciones con tráfico global 24/7 (como e-commerce, banca o aerolíneas). `pg_repack` crea la tabla nueva en segundo plano, crea un log temporal para rastrear los `INSERT/UPDATE` que ocurren mientras trabaja, y solo aplica un bloqueo de fracciones de segundo al final para hacer el intercambio de archivos. Es la evolución táctica del mantenimiento masivo.







###  1. EL MITO DEL ESPACIO (¿Necesito 50 GB de disco?)

**"Si mi tabla pesa 50 GB, ¿ocupo otros 50 GB de espacio libre? ¿Y qué pasa con el WAL?"**

La respuesta corta es: **NO necesitas 50 GB. Necesitas el espacio equivalente a tus DATOS VIVOS más tus ÍNDICES.**

`VACUUM FULL` no hace una copia exacta de la tabla. Extrae solo lo que sirve y lo guarda en un archivo nuevo. Para saber cuánto espacio necesitas realmente, tienes que ver el nivel de toxicidad (bloat) de tu tabla actual.

* **Escenario A (Poca Basura):** Tu tabla de 50 GB tiene 45 GB de datos vivos y solo 5 GB de basura.
* *Espacio extra necesario:* Necesitarás **45 GB** libres en el disco, porque el archivo nuevo será casi del mismo tamaño. (En este escenario, hacer un `VACUUM FULL` es un error táctico, el beneficio es nulo).


* **Escenario B (Mucha Basura - Table Bloat Crítico):** Tu tabla de 50 GB sufrió un `DELETE` masivo. Tienes 10 GB de datos vivos y 40 GB de basura.
* *Espacio extra necesario:* Solo necesitarás **10 GB** libres para la tabla nueva + el espacio para reconstruir los índices.



**El peligro oculto:** Mientras el `VACUUM FULL` se ejecuta, **ambos archivos existen al mismo tiempo**. Si estabas en el Escenario B, tu disco duro temporalmente estará alojando los 50 GB de la tabla vieja + los 10 GB de la tabla nueva. Al finalizar, borra los 50 GB originales.



###  2. EL TSUNAMI TRANSACCIONAL (El problema del WAL)


Aquí es donde los servidores explotan. Mencionaste el WAL (Write-Ahead Log) y diste en el clavo.

`VACUUM FULL` no es una operación silenciosa; para el motor, es equivalente a ejecutar un gigantesco `INSERT` masivo desde cero. **Absolutamente cada byte de dato vivo que se mueve al archivo nuevo, y cada byte de cada índice que se reconstruye, se tiene que escribir en los archivos WAL.**

Si tu tabla nueva (datos vivos) va a pesar 10 GB, vas a generar **al menos 10 GB a 15 GB de archivos WAL de golpe**.

¿Por qué esto es una emergencia en una tabla transaccional?

1. **Saturación de Disco:** Si tu partición de `pg_wal` no tiene esos 15 GB libres, la base de datos abortará con un error crítico (`No space left on device`) y el motor hará un *Crash/Panic*, tirando todos los servicios.
2. **Saturación de Red (Replicación):** Si tienes un nodo secundario (Réplica) de Alta Disponibilidad, esos 15 GB de WAL se van a enviar por el cable de red a máxima velocidad. Si tu red es de 1 Gbps, vas a saturar el canal de comunicación del clúster entero.
3. **Destrucción de Archivers:** Si tu sistema está enviando los WAL a AWS S3 o GCP Cloud Storage para tus respaldos *Point-in-Time*, generarás un cuello de botella masivo de subida.


###  3. LA FÓRMULA DE SUPERVIVENCIA DEL GATEKEEPER



No dispares artillería si no sabes si el retroceso va a destruir tu propio cañón. Antes de lanzar un `VACUUM FULL` en producción a una tabla pesada, debes aplicar la **Fórmula VANGUARD de Capacidad**.

1. Averigua tu tamaño real (Ej. con `pgstattuple_approx` viste que la tabla es de 50 GB, pero los datos vivos e índices suman **15 GB**).
2. Calcula la necesidad de disco de datos: **15 GB**.
3. Calcula la necesidad de disco de WAL: **~20 GB** (Siempre suma un margen del 30% por el *Full Page Writes*).

**Veredicto Táctico:**
Si los datos de tu tabla y tus archivos WAL viven en el mismo disco duro físico, necesitas tener **absolutamente garantizados 35 GB de espacio libre** antes de presionar Enter. Si no los tienes, el servidor colapsará.


---

## **un *Hard Crash* a mitad de una reescritura masiva.**

Mencionaste que la tabla pesa 50GB y el servidor se apagó cuando el `VACUUM FULL` iba por 40GB copiados. Te preguntas qué pasa con todo ese espacio temporal (los 40GB copiados y los WAL generados).

 
 

### 💥 EL ESCENARIO DEL CRASH (Lo que sucede internamente)

**Habla Pedro (Ingeniero Core):**

A nivel de motor, debes entender que un `VACUUM FULL` opera dentro de una transacción única gigante. En PostgreSQL rige el principio atómico: **Todo o Nada**.

1. El motor pidió espacio al sistema operativo y empezó a llenar un archivo espejo.
2. Llegó a copiar 40GB de datos vivos.
3. **SE FUE LA LUZ (Hard Crash).**
4. El motor *nunca* pudo ejecutar la última línea de su código, que era el paso final: "Actualiza el catálogo (`relfilenode`), cambia la tabla vieja por la nueva y haz `COMMIT`".
5. Por lo tanto, la base de datos aborta la operación completa. **Para el catálogo de PostgreSQL, la tabla original sigue intacta y el `VACUUM FULL` jamás ocurrió.**

 

###   EL ARCHIVO FANTASMA (¿Qué pasa con los 40GB que ya se copiaron?)

**Habla Samuel (Experto en S.O. Linux):**

Aquí es donde entra la interacción entre el motor y el sistema operativo.

Al irse la energía, tienes un archivo físico de 40GB (el archivo espejo temporal) flotando en tu disco duro, pero el catálogo de PostgreSQL no sabe que existe porque el `COMMIT` falló. **Este es un archivo huérfano.**

Pero no entres en pánico. PostgreSQL está diseñado para sobrevivir a esto:

* **La Recuperación Automática (Crash Recovery):** Cuando vuelves a encender el servidor de Linux y arrancas PostgreSQL, el motor ejecuta un proceso de inicio obligatorio para asegurar la consistencia.
* **La Limpieza:** Durante ese arranque, el motor escanea su propio directorio de datos en busca de "basura huérfana" (archivos temporales o espejos no completados).
* **El Resultado:** PostgreSQL identifica el archivo temporal de 40GB que quedó a medias y **lo borra automáticamente antes de aceptar la primera conexión de usuario**, devolviendo inmediatamente el espacio a Linux.

**Respuesta a tu duda:** No, no se queda ciclado ni perdido. Se restaura solo durante el reinicio del servicio.

 
###   EL TSUNAMI IRREVERSIBLE (¿Qué pasa con los WAL?)

**Habla Héctor (Arquitecto de Respaldos y DRP):**

Aquí es donde recibes el daño real. Los archivos de datos (espejos) se limpian solos, pero **los Archivos WAL (Write-Ahead Logs) son irreversibles.**

* Mientras el `VACUUM FULL` avanzaba hasta el 80%, fue escribiendo esos 40GB en los archivos WAL en la partición `pg_wal` (o `pg_xlog` en versiones viejas).
* Cuando el servidor se apaga y vuelve a encender, el motor lee los WAL para ver en qué se quedó. Al ver que la transacción del `VACUUM FULL` no tiene un `COMMIT`, simplemente la ignora y la marca como abortada.
* **El Daño:** El espacio en disco de tu partición de WAL ya fue consumido. Esos WAL ya se generaron y ya se enviaron a tu bóveda de respaldos o a tus servidores de réplica. Gastaste todo ese I/O, disco y red en un proceso que falló y tendrás que volver a empezarlo desde cero.
 
###   EL VEREDICTO DEL GATEKEEPER

**Habla Rodrigo (Gatekeeper Crítico):**

Tu escenario demuestra exactamente por qué el `VACUUM FULL` es un comando destructivo y por qué lo evitamos en entornos de alta disponibilidad.

Si lanzas un `VACUUM FULL` masivo, fallas por falta de recursos (o energía) al 99%, y tienes que volver a empezarlo... **estás multiplicando tu carga de WAL por dos**. Si no tenías espacio en tu partición `pg_wal` para la primera vuelta, definitivamente no la tendrás para la segunda, y tu servidor colapsará.

Si te ves obligado a ejecutar un `VACUUM FULL` de una tabla que compromete seriamente tu capacidad de WAL, la única forma segura de operarlo en VANGUARD es pausando temporalmente a tus réplicas y ajustando las métricas de retención, sabiendo que es una jugada de vida o muerte.
