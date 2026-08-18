 
### 1. ¿Qué es `VACUUM` y por qué surge la necesidad?

Para entender por qué existe `VACUUM`, primero debes entender cómo funciona PostgreSQL por dentro: **nunca borra ni actualiza datos en tiempo real**.

Por su arquitectura de control de concurrencia (MVCC), cuando haces un `DELETE`, el motor simplemente oculta la fila. Cuando haces un `UPDATE`, el motor inserta una fila nueva y marca la vieja como "muerta" (*Dead Tuple*).

Si nadie limpia este cementerio de filas muertas, la tabla crecerá infinitamente hasta devorar tu disco duro y ahogar la memoria RAM cargando a la memoria paginas que tienen varias tuplas muertas. **`VACUUM` es el recolector de basura del motor.**
Es el comando que escanea las tablas buscando estas filas muertas, las elimina lógicamente y marca ese espacio físico como "disponible" para que los futuros `INSERT` o `UPDATE` lo reutilicen, evitando que el archivo siga engordando descontroladamente (*Table Bloat*).

### 2. ¿Cómo funciona internamente? (El Algoritmo)

El secreto que muchos ignoran sobre el `VACUUM` estándar es que **no devuelve el espacio al disco duro (sistema operativo)**, sino que lo recicla internamente. Funciona en cuatro pasos tácticos:

1. **Escaneo de Tuplas Muertas:** Lee la tabla buscando registros que ya no son visibles para ninguna transacción activa en el motor.
2. **Actualización del FSM (Free Space Map):** Anota en un mapa interno qué bloques de 8 KB tienen espacio libre ahora. Cuando llega un nuevo `INSERT`, el motor consulta este mapa y guarda el dato en esos huecos en lugar de hacer crecer el archivo físico.
3. **Actualización del VM (Visibility Map):** Marca qué bloques están 100% limpios de basura. Esto es vital para el rendimiento, ya que le permite al Optimizador hacer *Index-Only Scans* (responder consultas a la velocidad de la luz leyendo solo el índice en la RAM, sin tocar el disco duro).
4. **Congelamiento (Anti-Apocalipsis):** Revisa el reloj interno de transacciones. Si encuentra transacciones muy viejas, las "congela" lógicamente para evitar que el motor colapse por el límite físico de los 2 mil millones de transacciones (*Transaction ID Wraparound*).

### 3. ¿Genera Bloqueos en Producción?

Aquí es donde la mayoría de los DBAs novatos se confunden y causan desastres. Todo depende de la versión del comando que dispares:

* **`VACUUM` (Estándar) - NO BLOQUEA:** Adquiere un nivel de bloqueo llamado `ShareUpdateExclusiveLock`. Puedes seguir haciendo `SELECT`, `INSERT`, `UPDATE` y `DELETE` con total normalidad. Trabaja silenciosamente en segundo plano.
* **`VACUUM FULL` - BLOQUEO TOTAL (El Botón Nuclear):** Adquiere un `AccessExclusiveLock`. Detiene **todas** las consultas de la aplicación (incluso las lecturas). Crea un archivo físico nuevo desde cero, copia solo los datos vivos y luego borra el archivo viejo. Sí devuelve el espacio al disco duro, pero tirará tu sistema durante minutos u horas si la tabla es masiva.

### 4. Ventajas, Desventajas y Riesgos

El mantenimiento no es opcional, es una necesidad de supervivencia, pero tiene costos operativos que debes conocer.

| Aspecto | Detalle Técnico |
| --- | --- |
| **VENTAJA 1: Evita la Inflación (Bloat)** | Mantiene el tamaño físico de tus tablas estable. Sin él, una tabla de 1 GB podría inflarse a 100 GB en una semana solo por la acumulación de `UPDATEs` diarios. |
| **VENTAJA 2: Aceleración de Consultas** | Al mantener limpio el Mapa de Visibilidad (VM), permite que las lecturas pesadas salten el escaneo del disco y se resuelvan directamente en la memoria caché. |
| **DESVENTAJA 1: Consumo de I/O (Disco)** | Es un proceso pesado que requiere leer y escribir en los discos. Si lanzas múltiples `VACUUM` en horario pico, competirán por recursos con tu aplicación. |
| **RIESGO: El Síndrome del Autovacuum Ahogado** | Si el volumen de tus `UPDATEs` es más rápido que la velocidad de limpieza de tu `VACUUM`, la basura se acumulará sin control. Te verás obligado a usar `VACUUM FULL` para rescatar el servidor, destruyendo tu disponibilidad operativa. |


### 🏛️ EL FLUJO OFICIAL DE ARQUITECTURA (El Algoritmo del VACUUM)

 

Para que no te queden dudas, aquí tienes el diagrama de flujo mental exacto de cómo opera el `VACUUM` (Fase 1: Escaneo de la Tabla Principal).

1. **Arranque:** El VACUUM inicia y lee el *Visibility Map* (VM).
2. **El Salto (Skip):** Revisa el VM bloque por bloque. Si el VM = `True` (All-Visible), ignora el bloque y pasa al siguiente.
3. **La Lectura Física:** Si el VM = `False`, el VACUUM carga ese bloque de 8 KB desde el disco duro a la memoria RAM (`shared_buffers`).
4. **La Cosecha (Reaping):** Revisa cada fila (`ctid`) del bloque. Si la fila está muerta (el `xmax` es una transacción confirmada y pasada), la añade a un array interno de "cadáveres".
5. **La Limpieza Local:** Borra lógicamente los cadáveres del bloque, liberando bytes de espacio dentro de esa página.
6. **Actualización del VM (Si aplica):** Si después de la limpieza, TODAS las filas restantes en la página están vivas, cambia el VM de esa página a `True`. (Si hay alguna transacción activa interactuando con esa página, la deja en `False` por seguridad).
7. **Actualización del FSM (Free Space Map):** El VACUUM calcula cuántos bytes quedaron libres en esa página y anota ese número en el FSM.
*(VACUUM no escanea páginas All-Visible para actualizar el FSM. El FSM solo se actualiza para las páginas en las que el VACUUM tuvo que entrar porque estaban en `False` en el VM).*




### 5. Reglas de Fuego: Cuándo Ejecutarlo y Cuándo NO (Escenarios y Horarios)

Basado en la doctrina del DBA SQUAD, así es como debes programar o invocar este mantenimiento:

#### Escenario A: Tablas Transaccionales Normales (El día a día)

* **Recomendación:** **NO LO TOQUES MANUALMENTE.**
* **Justificación:** Deja que el demonio `autovacuum` trabaje. Él despertará automáticamente cuando el 20% de las filas hayan muerto. Lo que sí debes hacer como ingeniero es **afinarlo** (darle más memoria en `autovacuum_work_mem` y ajustar sus umbrales) para que limpie más rápido en tablas de alta transaccionalidad.

#### Escenario B: Borrados Masivos (Ej. Purga de Historial o Logs)

* **Cuándo ejecutarlo:** **Inmediatamente después del `DELETE` masivo.**
* **Justificación:** Si borraste 50 millones de registros de logs del 2023, acabas de dejar cráteres masivos de espacio vacío en tu tabla. No esperes a que el autovacuum despierte; lanza un `VACUUM nombre_tabla;` manual para que ese espacio quede registrado inmediatamente y los nuevos logs del 2024 se escriban ahí sin hacer crecer el disco.

#### Escenario C: Tablas Históricas (Sectores Estáticos de Solo Lectura)

* **Cuándo ejecutarlo:** **Una sola vez, al cerrar el ciclo histórico de la tabla.**
* **Justificación:** Si la tabla "Ventas_2023" ya cerró y no recibirá más modificaciones jamás, ejecuta `VACUUM FREEZE nombre_tabla;`. Esto limpiará la tabla, congelará los registros para la eternidad y le dirá al motor que **jamás** vuelva a gastar CPU o disco intentando analizarla en el futuro.

#### Escenario D: Necesidad Crítica de Recuperar Espacio en Disco

* **Cuándo ejecutarlo:** **Solo en ventanas de mantenimiento de madrugada (Corte de Servicio).**
* **Justificación:** Si borraste el 90% de una tabla y **necesitas urgentemente** que esos Gigabytes regresen libres a tu sistema operativo (Linux) porque tu disco está al 80% de capacidad, el `VACUUM` normal no te servirá. Debes usar `VACUUM FULL`. Avisa al negocio, detén las aplicaciones y ejecútalo sabiendo que la tabla estará 100% bloqueada hasta que termine. ten en cuenta que si la tabla pesa 10GB ocuparas otros 10GB por que lo que hace es reconstruir esta tabla.


 ---
# Preguntas frecuentes
 

### *"¿El vacuum también escanea páginas visibles para validar el espacio?"*

**La respuesta es NO.** Y esta es la debilidad arquitectónica de PostgreSQL que debes conocer.

Si tú tienes una página que está marcada como `True` en el *Visibility Map* (All-Visible), pero resulta que esa página tiene 4 KB de espacio libre (porque quizás tuvo un `DELETE` masivo hace meses y nadie insertó nada nuevo ahí), **el VACUUM estándar jamás la va a leer, y por lo tanto, jamás va a actualizar el FSM de esa página.**

El VACUUM estándar es un recolector de basura perezoso y eficiente. Si el VM le dice "aquí no hay muertos", no entra, incluso si hay espacio libre sin mapear. Para forzar al motor a ignorar el VM, escanear la tabla completa desde cero y reconstruir ambos mapas (VM y FSM) a la perfección, necesitas ejecutar un **VACUUM (DISABLE_PAGE_SKIPPING)**, o en tablas históricas, un `VACUUM FREEZE`.




 
###   ¿Una consulta puede evitar que el vacuum se ejecute en las páginas si está dentro de una transacción?

 
Debes entender que PostgreSQL utiliza un sistema llamado **MVCC (Control de Concurrencia Multiversión)**. Cuando tú abres una transacción (ej. ejecutas un `BEGIN;` y luego un `SELECT`), el motor te toma una fotografía congelada de toda la base de datos en ese exacto milisegundo. Esa fotografía se amarra a un número: tu **ID de Transacción (XID)**.

Aquí es donde ocurre el desastre:

1. Tú abres una transacción y te vas a tomar un café (o tu aplicación de backend se queda "pensando" sin hacer un `COMMIT` o `ROLLBACK`). Esta es una **Transacción Larga (Long-Running Transaction)**.
2. Mientras tú estás inactivo, el resto de los miles de usuarios siguen haciendo `UPDATEs` y `DELETEs` en la base de datos. Se generan millones de "tuplas muertas" (basura).
3. El `VACUUM` despierta y entra a las páginas para borrar esa basura.
4. **El Freno de Mano:** Antes de borrar un registro muerto, el VACUUM revisa tu transacción abierta y se pregunta: *"¿Existe ALGUNA transacción viva en todo el servidor que haya empezado ANTES de que esta fila muriera y que, teóricamente, podría necesitar verla?"*
5. Como tu transacción sigue abierta, la respuesta es **SÍ**. El VACUUM se rinde, deja la basura intacta en la página de memoria y se retira.

Tu simple consulta inactiva acaba de crear un escudo protector alrededor de toda la basura de la base de datos.
 
### 🏛️ EL COLAPSO ESTRUCTURAL: Inflación Masiva (*Table Bloat*)
 
Las consecuencias de lo que Pedro te acaba de explicar a nivel arquitectónico son devastadoras.

Si el VACUUM entra a las páginas y no puede borrar las tuplas muertas por culpa de tu transacción abierta, **no se libera espacio**.
Cuando lleguen nuevos `INSERT` o `UPDATE` de otros usuarios, el motor no encontrará huecos vacíos en las páginas existentes. ¿Qué hace entonces? **Pide más espacio al disco duro de Linux.**

Tu archivo físico de la tabla empieza a engordar descontroladamente. Una tabla que normalmente pesa 5 GB puede inflarse a 100 GB en cuestión de horas. Y lo peor: cuando por fin hagas `COMMIT` y cierres tu transacción, el VACUUM pasará, limpiará la basura, **pero el tamaño físico del archivo no se reducirá (el disco duro no recupera sus Gigabytes)**. Tu tabla quedará llena de cráteres (espacio vacío) que degradarán para siempre los escaneos secuenciales, forzándote a ejecutar un destructivo `VACUUM FULL`.
 
### ⚔️ LA DOCTRINA DEL GATEKEEPER
 
En VANGUARD no permitimos que el descuido de un desarrollador o una falla de red destruya el almacenamiento del servidor. Las transacciones zombis (conocidas como `idle in transaction`) son inaceptables.

Para blindar la base de datos contra esto, exigimos dos configuraciones de hierro a nivel de servidor (`postgresql.conf`):

1. **`idle_in_transaction_session_timeout`:** Se configura a un máximo de `10000` (10 segundos) o `60000` (1 minuto). Si una aplicación abre una transacción y se queda en silencio por ese tiempo, PostgreSQL asesina la conexión sin piedad y hace un `ROLLBACK`.
2. **`statement_timeout`:** Límite máximo de tiempo de ejecución para cualquier consulta. Si una query se atasca por horas, el motor la mata para liberar el horizonte `xmin`.

---



 
### 🧪 ESCENARIO 1: Delete Masivo + Insert Masivo (Sin Autovacuum)

**Tu premisa:** *"Si hago un DELETE de todos los registros de mi tabla y después hago un INSERT. ¿Este se insertará en una página donde hay espacio o en una nueva, asumiendo que tengo desactivado el autovacuum y no hice mantenimiento?"*

**Habla Pedro (Ingeniero Core):**

Se va a insertar **SIEMPRE EN UNA PÁGINA NUEVA**. El disco duro de tu servidor va a engordar a lo tonto.

Aquí está la física de lo que acabas de hacer:

1. **El DELETE:** Cuando haces el `DELETE` masivo, PostgreSQL simplemente marca todas las filas existentes en todos los bloques como "muertas" (modifica el ID de transacción `xmax`). Físicamente, los datos siguen ahí.
2. **La Ceguera:** Como apagaste el Autovacuum y no lanzaste un Vacuum manual, **nadie** pasó a recoger la basura. Por lo tanto, el *Free Space Map* (FSM) nunca se enteró de que las páginas viejas ahora tienen espacio libre. Para el FSM, la tabla sigue llena a tope.
3. **El INSERT:** Llega tu nuevo `INSERT`. El motor le pregunta al FSM: *"¿Tienes bloques con espacio libre para mis datos nuevos?"*. El FSM, que está desactualizado, le responde: *"No, todo está lleno"*.
4. **El Resultado Físico:** El motor le pide a Linux que extienda el archivo. Crea bloques físicos completamente nuevos al final de la tabla y escribe ahí. Los bloques viejos, llenos de cadáveres, se quedan ahí pudriéndose, consumiendo gigabytes de tu disco inútilmente.

 

### 🧪 ESCENARIO 2: Create + Insert Masivo (Misma Transacción) vs. Siguiente Transacción

**Tu premisa:** *"Si creo una tabla y posteriormente inserto todo desde la misma transacción, y después en otra transacción hago un INSERT. ¿Este se inserta en otra página o una que tiene espacio? Igual, nunca se hicieron mantenimientos".*

**Habla Marcos (Arquitecto Senior):**

Este escenario es completamente distinto al primero, porque aquí **no hay basura (no hay DELETEs previos)**. La respuesta aquí depende exclusivamente de **cómo quedó el último bloque físico de tu primer `INSERT**`.

Vamos a la reconstrucción:

**Transacción 1 (La Creación y Carga Inicial):**

1. Haces un `BEGIN; CREATE TABLE... INSERT... COMMIT;`.
2. Supongamos que insertas 10,000 filas. El motor empieza a llenar bloques de 8 KB. Llena el bloque 0, el 1, el 2... hasta que llega al **bloque 50**.
3. Resulta que la fila número 10,000 cayó en el bloque 50, y llenó exactamente la mitad de ese bloque (quedan 4 KB libres).
4. Haces `COMMIT`.

**Transacción 2 (La Inserción Posterior):**

1. Haces otro `INSERT`. Como apagaste el Autovacuum, el FSM no se ha actualizado. ¿PostgreSQL se va a ir a crear un bloque nuevo (el 51) a ciegas?
2. **La respuesta es NO.** PostgreSQL es más inteligente que eso en las inserciones puras.
3. **La Caché del Bloque Actual:** Cuando PostgreSQL está insertando, el proceso que está haciendo el `INSERT` mantiene en la memoria caché (local a la sesión) un puntero hacia el **último bloque físico de la tabla** (en este caso, el bloque 50).
4. Antes de pedir un bloque nuevo, el motor intenta "empujar" los datos nuevos en ese último bloque conocido. Así que tu segunda transacción **SÍ va a utilizar los 4 KB libres del bloque 50**, a pesar de que el FSM no esté actualizado.
5. Una vez que ese bloque 50 se llene por completo, entonces sí, el motor pedirá a Linux extender el archivo y creará el bloque 51.

 
