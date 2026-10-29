# Guía del administrador

Esta guía es para los administradores que usan la aplicación para agregar y gestionar los datos que hacen funcionar el sistema de navegación: lugares (places), edificios (buildings), puntos de anclaje (anchor points) y las conexiones entre ellos. Explica qué hacer, en qué orden, y qué significa realmente cada campo de cada pantalla — no solo si es obligatorio u opcional.

> Esta guía describe la aplicación tal como existe hoy. La aplicación está en español e inglés (sigue el idioma del teléfono, o el elegido en Ajustes). Los nombres de campos de abajo son las etiquetas en inglés; en español las mismas pantallas muestran su traducción. Todo esto funciona en la aplicación del teléfono, y casi todo también en la [aplicación web](#6c-la-aplicación-web).

## 1. Primeros pasos

Se accede al área de administración automáticamente al iniciar sesión con una cuenta de administrador — no hay un inicio de sesión separado para administradores; la aplicación te dirige a la vista de administración según el rol de tu cuenta.

La navegación vive en un menú lateral (drawer), que se abre con el ícono de hamburguesa (☰) en la esquina superior izquierda de la pantalla. En una pantalla ancha, como la aplicación web en un computador, queda abierto a la izquierda. El encabezado del menú muestra "Admin" y tu correo electrónico de la sesión iniciada, y debajo, cinco secciones:

- **Universidades** (ícono de bandera)
- **Edificios** (ícono de edificio)
- **Puntos de anclaje** (ícono de pin)
- **Conexiones** (ícono de línea)
- **Usuarios** (ícono de personas), ver [§6d](#6d-usuarios)

Debajo están **Sesiones** y **Comentarios** ([§6b](#6b-probar-una-ruta-y-revisarla)), **Reindexar puntos verificados** ([§5.3](#53-revisar-y-verificar)) y **Test as user** (solo en el teléfono).

Toca una sección para cambiar a ella; el menú se cierra automáticamente. El título en la parte superior de la pantalla siempre indica en qué sección te encuentras. La esquina superior derecha siempre tiene un ícono de actualizar (recarga todo desde el servidor), uno de ajustes (idioma, alto contraste, tamaño del texto, voz) y uno de cerrar sesión (te desconecta de inmediato, sin confirmación).

En esta guía, "lugar" (place) y "universidad" son lo mismo: la aplicación llama *universidades* a los lugares.

## 2. Orden recomendado de trabajo

Las cuatro secciones no son independientes — cada una se construye sobre la anterior:

1. **Place (lugar)** — el campus o sede. Todo lo demás pertenece a uno.
2. **Building (edificio)** — un edificio físico dentro de un lugar. No se puede crear un edificio hasta que exista su lugar.
3. **Anchor point (punto de anclaje)** — un punto físico específico dentro de (o justo afuera de) un edificio. No se puede crear uno hasta que exista su edificio.
4. **Fotos** — todo punto de anclaje necesita al menos una foto, idealmente entre 4 y 8 tomadas en direcciones distintas, antes de que sea útil.
5. **Verificación** — después de revisar las fotos de un punto de anclaje, se cambia su estado (Status) a Verified. Este es el paso que realmente lo hace utilizable por la aplicación — ver la explicación en [5.3](#53-revisar-y-verificar).
6. **Connections (conexiones)** (necesarias para las rutas) — una vez que tienes dos o más puntos de anclaje verificados, marca entre qué pares se puede caminar directamente. Las rutas solo se calculan a lo largo de conexiones, así que un destino sin conexiones no se puede alcanzar.

**Marca primero los lugares importantes y luego rellena entre ellos.** Empieza por los lugares a los que la gente realmente quiere ir: entradas, salones, oficinas, baños, la cafetería, el auditorio. Dale a cada uno una descripción clara, porque es el nombre que los usuarios eligen y escuchan. Después agrega puntos *intermedios* (pasillos, intersecciones, escaleras, rampas) donde hagan falta para unir esos lugares con conexiones caminables. Los puntos intermedios no necesitan descripción y nunca se ofrecen a los usuarios como destino.

Si intentas saltarte un paso (por ejemplo, agregar un edificio antes de que exista su lugar), el menú desplegable correspondiente simplemente estará vacío, con un mensaje indicando qué agregar primero.

## 3. Places (lugares)

Un **place** es la parte más alta de la jerarquía — típicamente un campus o sede completa. Cada edificio pertenece exactamente a un lugar.

### Agregar un lugar

1. Desde el menú, ve a **Places**.
2. Toca el botón **+** (abajo a la derecha).
3. Completa los campos (ver la tabla abajo).
4. Toca **Save place**.

### Editar un lugar

Toca el ícono de lápiz (✏️) en la fila del lugar. Nota: el campo **Code** no se puede cambiar aquí — queda fijo una vez creado el lugar (ver por qué en la tabla de campos).

### Eliminar un lugar

Toca el ícono de basura en la fila del lugar. Verás exactamente cuántos edificios, puntos de anclaje, fotos y conexiones se eliminarán junto con él, porque eliminar un lugar elimina en cascada todo lo que depende de él — ver [§7](#7-eliminar-datos).

### Campos de Place

| Etiqueta en pantalla | ¿Obligatorio? | Qué significa | Ejemplo |
|---|---|---|---|
| **Code** | Obligatorio (solo aparece al crear — no se puede cambiar después) | Un identificador corto y único para el lugar, distinto de su nombre completo — piénsalo como una abreviatura o código de referencia interno. Como otros datos pueden terminar referenciando un lugar, no es posible cambiarlo después. | `CAMPUS` (para un lugar llamado "Main Campus") |
| **Name** | Obligatorio | El nombre completo y legible del lugar. Es lo que verás en el resto de la aplicación (listas, menús desplegables). | `Main Campus` |
| **Address (optional)** | Opcional | Una dirección de referencia — no se usa funcionalmente en ninguna otra parte. | `Cra 80 #65-223, Medellín` |
| **Latitude** / **Longitude** | Obligatorios | Las coordenadas GPS del punto central aproximado del lugar, en grados decimales. Se pueden escribir directamente, o usar **Pick on map** (un botón debajo de los campos) para tocar la ubicación en un mapa en su lugar — útil cuando no se conocen las coordenadas exactas de memoria. | `6.2442`, `-75.5812` |
| **Active** (solo al editar) | — | Un interruptor para marcar un lugar como inactivo sin eliminarlo (ni todo lo que contiene). Se desactiva para un lugar que ya no está en uso pero cuyo historial se quiere conservar. | — |

## 4. Buildings (edificios)

Un **building** es un edificio físico dentro de un lugar.

### Agregar un edificio

1. Desde el menú, ve a **Buildings**.
2. Toca **+**.
3. Elige el **Place** al que pertenece este edificio (si aún no existen lugares, se te indicará agregar uno primero).
4. Completa el resto de los campos.
5. Toca **Save building**.

### Editar un edificio

Toca el ícono de lápiz en la fila del edificio. Igual que con los lugares, **Code** no se puede cambiar después de creado. El menú **Universidad** sí: úsalo para mover un edificio que quedó asignado a la universidad equivocada.

### Eliminar un edificio

Mismo patrón de advertencia en cascada que los lugares — verás cuántos puntos de anclaje, fotos y conexiones se eliminan junto con él.

### Campos de Building

| Etiqueta en pantalla | ¿Obligatorio? | Qué significa | Ejemplo |
|---|---|---|---|
| **Universidad** | Obligatorio | A qué universidad pertenece este edificio. Filtra la lista de edificios que se verá en el resto de la aplicación. Se puede cambiar al editar. | Main Campus |
| **Code** (solo al crear) | Obligatorio | Misma idea que el código de un lugar — un identificador corto, único e inmutable para este edificio específico. | `B1` |
| **Name** | Obligatorio | El nombre completo del edificio, mostrado en toda la aplicación. | `Main Building` |
| **Address (optional)** | Opcional | Dirección de referencia. | — |
| **Latitude** / **Longitude** | Obligatorios | La posición GPS propia de este edificio — un punto distinto al del lugar, ya que un edificio se ubica en un punto específico dentro del lugar. Se escribe directamente o se usa **Pick on map**. | `6.2445`, `-75.5810` |
| **Floors** | Por defecto `1` | Cuántos pisos tiene el edificio. Los puntos de anclaje dentro de este edificio luego indicarán en qué piso están. | `3` |
| **Has elevator** (casilla) | Desmarcada por defecto | Si el edificio tiene ascensor. Esta es información real de accesibilidad — el propósito completo de la aplicación es ayudar a usuarios con discapacidad visual a navegar, así que saber cómo se mueve alguien realmente entre pisos importa. | — |
| **Has stairs** (casilla) | Marcada por defecto | Misma idea, para las escaleras. | — |
| **Active** (solo al editar) | — | Mismo significado que el interruptor Active de un lugar. | — |

## 5. Anchor points (puntos de anclaje)

Un **anchor point** es un punto físico específico — una puerta, una intersección de pasillos, el vestíbulo de un ascensor — que el sistema de reconocimiento visual de la aplicación aprende a identificar a partir de fotos reales. Cuando la cámara del teléfono de un usuario más adelante detecta algo que coincide con una de estas fotos, la aplicación lo usa para corregir la posición GPS de ese usuario. Es decir: un punto de anclaje no es solo un pin en un mapa, es un lugar que la aplicación realmente ha aprendido a "ver".

### 5.1 Crear un punto de anclaje

1. Desde el menú, ve a **Anchor points**.
2. Toca el botón **+** con ícono de cámara (abajo a la derecha) — etiquetado "New anchor point".
3. Elige el **Place**, luego el **Building** (filtrado según ese lugar).
4. Elige el **Location type** — qué tipo de lugar es este (ver la lista completa en [§8](#8-referencia-rápida)). Por ejemplo, si estás parado en la puerta principal de un edificio, elige **entrance**.
5. Completa la **Description**. Es **obligatoria para los tipos de destino** (entrance, classroom, office, restroom, cafeteria, parking, lobby, auditorium, bus_stop), porque es el nombre que los usuarios eligen y escuchan, así que describe el lugar real: "Puerta principal, lado norte" es mucho más útil que "Punto 1". Para los **tipos intermedios** (hallway, intersection, stairwell, elevator, ramp, outdoor_path, courtyard, crosswalk, other) es opcional. Si la dejas vacía, el punto sigue sirviendo para rutas y para corregir la posición, pero no aparece en la lista de destinos del usuario. En las listas de administración los puntos sin nombre se muestran por su tipo, por ejemplo "Pasillo · 3f2a". Los puntos nuevos empiezan como **hallway**.
6. Configura **Indoor location** (activado por defecto) — si el punto está dentro de un edificio o afuera. Esto importa porque la precisión del GPS es mucho peor en interiores, que es exactamente por qué los puntos de anclaje interiores son los más importantes para el sistema de corrección de posición.
7. Opcionalmente configura **Lighting** (Bright / Moderate / Dim) y **Surface** (texto libre, ej. "tile", "carpet", "concrete", "grass") — ver la tabla de campos abajo para entender por qué vale la pena completarlos.
8. Confirma la posición — ya sea la ubicación GPS actual del dispositivo (se muestra automáticamente) o, si tocas **Pick on map**, una ubicación que toques en un mapa. Una ubicación elegida manualmente siempre tiene prioridad sobre el GPS. Úsalo cuando la deriva del GPS (común cerca de edificios altos) ubicaría el punto en el lugar equivocado.
9. Toca **Create and add photos** — esto guarda el punto de anclaje y te lleva directamente a la pantalla de captura de fotos ([§5.2](#52-tomar-fotos)).

#### Campos de Anchor point (creación y edición)

| Etiqueta en pantalla | ¿Obligatorio? | Qué significa | Ejemplo |
|---|---|---|---|
| **Place** / **Building** | Ambos obligatorios | A qué edificio pertenece este punto (el menú de Place solo filtra la lista de edificios). | — |
| **Location type** | Obligatorio, los puntos nuevos empiezan como "hallway" | Qué tipo de lugar es este, elegido en un selector con búsqueda agrupado por categorías. Lista completa en [§8](#8-referencia-rápida). | `entrance` |
| **Floor** | Obligatorio | En qué piso del edificio está el punto. "Piso 1" es la planta baja; la lista ofrece los pisos del edificio. | `Piso 1` |
| **Description** | Obligatoria para los tipos de destino (★ en [§8](#8-referencia-rápida)), opcional para los demás | El nombre legible del punto — el que los usuarios eligen y escuchan. Describe el lugar real, no una etiqueta genérica. | `Puerta principal, lado norte` |
| **Indoor location** (interruptor) | Activado por defecto | Interior vs. exterior — ver arriba por qué importa. | — |
| **Lighting** (menú desplegable) | Opcional, por defecto "Not set" | La iluminación típica de este lugar exacto: Bright / Moderate / Dim. Es un contexto útil para quien revise las fotos después (una foto oscura puede simplemente significar un pasillo con poca luz, no una mala foto), y con el tiempo esta información está pensada para ayudar a que el sistema de reconocimiento visual sea más confiable en distintas condiciones de luz. | Un lugar junto a una ventana grande al mediodía → `Bright`; una escalera interior con solo luces de techo → `Dim` |
| **Surface (optional)** | Opcional, texto libre | La superficie física del suelo. Puede servir como una pista útil de orientación (por ejemplo, un cambio de baldosa a alfombra puede marcar el límite de una sala). | `tile`, `carpet`, `concrete`, `grass` |
| **Location** | Obligatoria (GPS o selección en mapa) | Las coordenadas reales del punto. Una selección en el mapa siempre tiene prioridad sobre la lectura GPS en vivo del dispositivo. | — |

**El formulario recuerda tu último punto.** Un punto de anclaje nuevo empieza con la universidad, el edificio, el tipo de lugar, el piso, el ajuste de interior, la iluminación y la superficie del último que creaste en este teléfono. Solo la descripción y la posición empiezan vacías. Si abriste el formulario filtrado a un edificio, se usa ese edificio.

**Filtrar la lista.** El botón **Filtros** encima de la lista (y del mapa) acota los puntos de anclaje por categoría y tipo, piso, interior o exterior, iluminación, y si tienen fotos o conexiones. Se combina con los chips de estado y la búsqueda. **Quitar filtros** (o el botón atrás) los elimina.

### 5.2 Tomar fotos

Por qué varias fotos: una persona podría acercarse al mismo lugar físico desde cualquier dirección, así que la aplicación necesita reconocer cómo se ve desde cada lado — no solo desde un ángulo.

1. En la pantalla de fotos verás una vista previa de la cámara en vivo. Una pequeña insignia en la esquina superior derecha muestra **"Facing: N°"** — el rumbo de la brújula en vivo del dispositivo (no la dirección del GPS), actualizándose en tiempo real. Esto se guarda automáticamente con cada foto, para que la aplicación sepa hacia dónde apunta esa foto.
2. Toca **Take photo** para capturar una. Se sube automáticamente y aparece en una cuadrícula de miniaturas debajo, con el rumbo con el que fue tomada mostrado en la esquina de cada miniatura.
3. Repite apuntando en direcciones distintas — como guía, apunta a 4-8 fotos, más o menos hacia norte/sur/este/oeste desde el mismo lugar (ajusta según el espacio real — un punto en una esquina quizás solo tenga dos o tres direcciones sensatas para fotografiar). La aplicación no exige un mínimo, así que esto depende de ti.
4. ¿Te equivocaste? Toca el ícono de basura en una miniatura para eliminar esa foto (con una confirmación).
5. Cuando termines, toca la marca de verificación (✓) en la esquina superior derecha de la pantalla — etiquetada "Done".

Siempre puedes volver más adelante a agregar o quitar fotos desde el botón **Manage photos** de un punto de anclaje (ver abajo).

### 5.3 Revisar y verificar

**Verificación rápida desde la lista o el mapa:** cada fila de punto de anclaje tiene un botón ✔ que lo verifica (o, en un punto verificado, lo devuelve a pendiente). Un punto necesita al menos una foto antes de poder verificarse. El selector **Lista / Mapa** encima de la lista muestra los mismos puntos en un mapa, coloreados por estado: verde verificado, gris pendiente, rojo rechazado. Toca un punto en el mapa para ver sus datos y para **Editar**, **Mover**, verificar, **Conectar** o agregar fotos. **Mover** te pide tocar la nueva posición; la punta del pin marca exactamente dónde quedará, y **Guardar nueva posición** la guarda. Mover un punto verificado también actualiza la búsqueda por fotos y las distancias de sus conexiones.


La pantalla de edición de un punto de anclaje es también donde lo revisas y decides si está listo para uso real. Esto es más que solo cambiar una etiqueta:

- **Status: Verified** — al guardar con este estado, las fotos del punto se indexan automáticamente en el sistema de búsqueda de la aplicación, convirtiéndose en datos reales y activos que la aplicación puede usar para comparar con la cámara de un usuario. Este es el paso que hace que un punto de anclaje realmente *sirva* para algo.
- **Status: Pending** o **Rejected** — al guardar con cualquiera de estos, el punto se elimina de ese índice de búsqueda (si estaba en él), por lo que un punto degradado o rechazado deja de ser utilizable por la aplicación en vivo, sin eliminar el punto en sí.

Así que antes de poner un punto en Verified, revisa primero sus fotos de verdad (esta pantalla muestra una tira de miniaturas de solo lectura) — ¿son claras, están correctamente orientadas, realmente muestran el lugar correcto? Usa **Manage photos** para corregir lo que haga falta antes de verificar.

Para editar un punto de anclaje: toca el ícono de lápiz en su fila. Verás los mismos campos que al crearlo (todos editables), más:

| Etiqueta en pantalla | Qué significa |
|---|---|
| **Status** (menú desplegable: pending / verified / rejected) | Ver arriba — este es el interruptor real que convierte un punto capturado en datos de navegación utilizables, o lo revierte. |
| Tira de miniaturas de fotos (solo lectura) | Una revisión visual rápida antes de decidir el estado. |
| Botón **Manage photos** | Abre la misma pantalla de fotos de [§5.2](#52-tomar-fotos) para agregar o eliminar fotos. |
| Botón **Move on map** | Permite volver a elegir la posición del punto en un mapa, por ejemplo si resulta estar en el lugar equivocado. |

**Si al verificar aparece un error de indexación:** el punto queda guardado como Verified, pero la búsqueda por fotos no lo recibió, así que la app todavía no puede reconocerlo. Cuando se arregle el problema del servidor, abre el menú y toca **Reindexar puntos verificados**. Primero quita de la búsqueda por fotos lo que ya no debería estar (fotos eliminadas, puntos que ya no están verificados). Luego envía solo los puntos verificados cuyas fotos todavía no se pueden buscar, reintenta cada fallo dos veces y termina con la lista de los puntos que aun así fallaron. Cuando hay fotos verificadas que no se pueden buscar, la opción del menú muestra un aviso rojo "N fotos no se pueden buscar": esa es la señal para usarla.

## 6. Connections (conexiones)

Una **connection** registra que una persona puede caminar directamente entre dos puntos de anclaje. Juntas forman el grafo de transitabilidad: las rutas se calculan solo a lo largo de las conexiones, y las instrucciones paso a paso las siguen.

Hay dos formas de crear una — elige la que se ajuste a la situación:

### Conectar tocando en el mapa

Más rápido, y funciona especialmente bien para conectar toda una secuencia de puntos a lo largo de un pasillo:

1. Desde el menú, ve a **Connections**, luego toca el botón **+** — etiquetado "Connect on map".
2. Elige un **Place**, y opcionalmente un **Building** para acotar más el mapa.
3. Toca un punto de anclaje en el mapa para seleccionarlo. No hace falta acertar exactamente en el punto: un toque cerca también cuenta, y el teléfono vibra al seleccionarlo.
4. Toca un segundo punto de anclaje — esto crea la conexión entre ambos, y el segundo punto **queda seleccionado**, así puedes tocar de inmediato un tercer punto para seguir encadenando conexiones a lo largo del mismo pasillo sin empezar de nuevo cada vez.
5. Las conexiones existentes entre puntos visibles se dibujan como líneas verdes en el mapa, para que puedas ver de un vistazo qué ya está conectado. Una conexión nueva se ve un momento como línea gris punteada mientras se guarda. Puedes seguir tocando mientras tanto.

**Atajo desde la lista de puntos de anclaje:** en la pantalla **Anchor points**, toca la fila de un punto (no sus íconos de foto, editar o eliminar). Se abre el mapa de conexiones ya ubicado en la universidad y el edificio de ese punto, con zoom sobre él y con el punto ya seleccionado. Tu siguiente toque en otro punto los conecta.

### Formulario con menús desplegables

Más preciso — úsalo cuando no estés mirando un mapa, o cuando necesites corregir la distancia estimada automáticamente:

1. Desde la pantalla de Connections, toca el ícono de lista en la esquina superior derecha — etiquetado "Add connection (form)".
2. Elige **Place**, opcionalmente un filtro de **Building**, luego **Anchor point A** y **Anchor point B** en los menús desplegables.
3. Opcionalmente completa **Distance** y **Notes** (ver tabla).
4. Toca **Save connection**.

### Campos de Connection (formulario)

| Etiqueta en pantalla | ¿Obligatorio? | Qué significa | Ejemplo |
|---|---|---|---|
| **Place** / **Building (optional filter)** | Place obligatorio, Building opcional | Acota qué puntos de anclaje aparecen en los menús desplegables de abajo. | — |
| **Anchor point A** / **Anchor point B** | Ambos obligatorios, deben ser puntos distintos | Los dos puntos de anclaje que se están conectando. | — |
| **Distance in meters (optional)** | Opcional | Cuánto caminaría realmente una persona entre los dos puntos. Si se deja en blanco, la aplicación la estima como una línea recta entre sus coordenadas — lo cual es incorrecto si el camino real tiene curvas (por ejemplo, al doblar una esquina) o no es un trayecto directo (por ejemplo, vía ascensor o escaleras en vez de un camino directo). Complétalo siempre que la estimación en línea recta no sea precisa. | `12.5` |
| **Notes (optional)** | Opcional | Texto libre para anotar cualquier cosa relevante sobre esta conexión en particular. | `via elevator, not stairs`, `blocked during exam periods` |

Eliminar una conexión no tiene efecto en cascada: no afecta a los dos puntos de anclaje en sí. No hay opción de editar, así que elimínala y vuelve a crearla si necesitas cambiarla. Hay dos formas de eliminarla:

- En la lista **Connections**, toca su ícono de basura.
- En la pantalla **Connect on map**, toca la línea verde (lejos de los puntos, porque tocar cerca de un punto lo selecciona) y confirma.

Cualquier ruta guardada que pasaba por una conexión eliminada se recalcula automáticamente la próxima vez que alguien la pida.

## 6b. Probar una ruta y revisarla

Usa **Test as user** (menú) para recorrer una ruta tú mismo. Durante el viaje aparece un botón rojo **✗ Instrucción incorrecta** encima de **Terminar navegación**. Tócalo cada vez que la app diga algo incorrecto (un giro cuando deberías seguir derecho, una distancia equivocada, una llegada antes de tiempo). Guarda lo que se acababa de decir, dónde estabas y lo que la app estaba viendo.

Para medir qué tan precisa es la posición, recorre la ruta planeada **exactamente** y usa el botón azul **Estoy en …**:
- Tócalo parado en cada punto que nombra: el inicio, cada esquina, el destino.
- Una pulsación larga deshace el último toque.
- En este modo la llegada se anuncia, pero el recorrido sigue hasta que marques el destino.
- La app también guarda cada foto de la cámara de un recorrido de prueba, para comparar luego modelos de reconocimiento de fotos.

Después, abre **Sesiones** en el menú, elige el usuario y toca **Ver** en la sesión. Una tarjeta arriba muestra qué tan lejos de la ruta estuvieron el GPS sin corregir y la posición corregida, y el error en tus puntos de control (banderas azules). El mapa muestra:
- **Línea gris azulada:** la ruta planeada.
- **Línea naranja punteada:** el recorrido del GPS sin corregir.
- **Línea verde:** la posición corregida.
- **Puntos morados:** coincidencias de foto, cada uno con una línea delgada al punto de anclaje reconocido. Las líneas largas muestran desde dónde se jaló la posición.
- **✗ rojas:** tus marcas de instrucción incorrecta.

Toca cualquiera para ver los detalles registrados ahí.

**Lo que ve el usuario y lo que ves tú.** Un usuario normal no ve coordenadas ni mapa durante el viaje: solo un botón grande **Repetir instrucción** y **Terminar navegación**. Su punto de partida sale del GPS, sin fotos. En **Test as user** sigues viendo el mapa, las coordenadas (GPS y corregida) y la revisión del punto de partida con la cámara (toca la fila **Inicio**).

**Cómo sostener el teléfono.** Para que las fotos se reconozcan, el teléfono va vertical frente al pecho, con la cámara trasera mirando hacia adelante. Explícaselo así al usuario; el tutorial de la app (botón **?**) también lo dice.

## 6c. La aplicación web

Todo lo de esta guía, salvo tomar fotos con la cámara y **Test as user**, también funciona en un navegador, en una pantalla más grande: **https://184-195-103-237.sslip.io/admin/**. Entra con tu cuenta de administrador; a una cuenta que no es de administrador se le indica usar la aplicación del teléfono.

- **Menú lateral:** en una ventana ancha, el menú queda abierto a la izquierda en vez de deslizarse.
- **Fotos:** la pantalla de fotos de un punto tiene **Subir fotos** en lugar de la cámara. Elige uno o más archivos de imagen tomados parado en el punto. Antes de subirlas, elige hacia dónde miran (N, NE, E…). Elige **No sé** si no estás seguro: esa foto nunca se descarta por mirar hacia otro lado.
- **Usuarios:** cada fila tiene además **Desactivar cuenta**. Una cuenta desactivada no puede usar la aplicación ni la web hasta que un administrador la vuelva a activar. No puedes desactivarte a ti mismo.

## 6d. Usuarios

La sección **Usuarios** lista todas las cuentas.

- **Ascender / quitar administrador:** el ícono de escudo de una fila convierte a esa persona en administradora, o le quita los permisos (con confirmación). Está desactivado en tu propia fila.
- **Desactivar / activar:** el ícono de persona bloquea una cuenta sin eliminarla. Una cuenta desactivada no puede usar la aplicación ni la web hasta que se vuelva a activar. Está desactivado en tu propia fila.
- **Cuentas sin perfil:** si un registro no terminó, la cuenta aparece en una tarjeta resaltada arriba. Su botón crea el perfil que falta, y la persona aparece luego en la lista normal.
- **El primer administrador** se asigna a mano en la base de datos (`UPDATE profiles SET role_id = 2 WHERE id = ...`), como dice la nota arriba de la lista.

**Versiones de la aplicación.** La aplicación funciona en su versión más nueva y en la anterior. Quien tenga la versión anterior ve "Nueva versión disponible" una vez cada vez que abre la aplicación, con un botón para descargarla. Las versiones más viejas solo muestran "Actualización necesaria" con el enlace de descarga, hasta que se instale el APK nuevo. Las versiones están en la página de releases del proyecto en GitHub. Para quienes prueban, la [guía del usuario](../../user-guide/README.md) explica cómo instalar y actualizar.

## 7. Eliminar datos

Las universidades y los edificios tienen un ícono de basura en su fila. En la fila de un punto de anclaje, **Agregar foto** y **Eliminar** están en el menú ⋮, junto a los botones de verificar y editar.

Se puede eliminar cualquier cosa que se haya usado en viajes. Las rutas guardadas que pasan por los puntos eliminados se eliminan con ellos, y el historial de viajes se conserva. Si algo aún no se puede eliminar, el mensaje dice por qué.

Eliminar un place, building o anchor point siempre muestra un cuadro de confirmación que indica exactamente qué más se eliminará junto con él, porque los datos son jerárquicos (place → building → anchor point → fotos/conexiones):

- **Eliminar un place** también elimina sus buildings, los anchor points de esos buildings, las fotos de esos puntos, y cualquier connection que los involucre.
- **Eliminar un building** también elimina sus anchor points, sus fotos, y cualquier connection que los involucre.
- **Eliminar un anchor point** también elimina sus fotos y cualquier connection que lo involucre.
- **Eliminar una connection** no afecta nada más.

La confirmación siempre muestra los números reales (por ejemplo, "will also delete 3 buildings, 12 anchor points, 45 photos, and 8 connections") antes de confirmar — léelo con atención. Nada de esto se puede deshacer.

## 8. Referencia rápida

### Location types (tipos de lugar)

Toca el campo **Location type** para abrir el selector de tipos. Los tipos están agrupados por categorías, y el buscador de arriba encuentra uno por su nombre (por ejemplo "biblioteca"). Los tipos marcados con ★ son **destinos**: necesitan descripción y aparecen en la lista de destinos de los usuarios. Los demás son puntos intermedios para conectar rutas.

| Categoría | Tipos |
|---|---|
| Caminos y conexiones | Pasillo, Camino exterior, Intersección, Escaleras, Ascensor, Rampa, Paso peatonal, Patio |
| Entradas y desplazamiento | Entrada ★, Salida / portería ★, Vestíbulo ★, Parqueadero ★, Parqueadero de bicicletas ★, Paradero de bus ★, Zona de espera / bancas ★ |
| Académico | Salón ★, Laboratorio ★, Biblioteca ★, Sala de cómputo ★, Zona de estudio ★, Auditorio ★, Oficina ★ |
| Comida, tiendas y servicios | Cafetería ★, Papelería ★, Centro de copias ★, Tienda ★, Cajero / banco ★, Baño ★, Bebedero ★ |
| Bienestar y deporte | Enfermería / servicio médico ★, Gimnasio / zona deportiva ★, Capilla ★ |
| Otro | Otro |

### Status del anchor point

| Status | Significado |
|---|---|
| **pending** | Capturado, aún no revisado — todavía no utilizable por la aplicación en vivo |
| **verified** | Revisado y confirmado como correcto — indexado en el sistema de búsqueda, utilizable por la aplicación en vivo |
| **rejected** | Revisado y rechazado (malas fotos, ubicación incorrecta, duplicado, etc.) — excluido del sistema de búsqueda |

### Lighting (iluminación)

| Opción | Significado |
|---|---|
| Not set | Sin información de iluminación registrada |
| Bright | Bien iluminado, por ejemplo luz natural por ventanas |
| Moderate | Iluminación interior normal |
| Dim | Poco iluminado, por ejemplo una escalera interior |
