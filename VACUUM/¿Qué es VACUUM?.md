 
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
* **Justificación:** Si borraste el 90% de una tabla y **necesitas urgentemente** que esos Gigabytes regresen libres a tu sistema operativo (Linux) porque tu disco está al 99% de capacidad, el `VACUUM` normal no te servirá. Debes usar `VACUUM FULL`. Avisa al negocio, detén las aplicaciones y ejecútalo sabiendo que la tabla estará 100% bloqueada hasta que termine.

**El Veredicto Final:**
El `VACUUM` es tu sistema inmunológico. Mantenerlo afinado de forma asíncrona salva tu servidor del colapso físico. Aplícalo con inteligencia: usa el estándar para prevenir y reserva el `FULL` únicamente como cirugía de emergencia.
