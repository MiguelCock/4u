# Guía del administrador

Esta guía es para los administradores que usan la aplicación para agregar y gestionar los datos que hacen funcionar el sistema de navegación: lugares (places), edificios (buildings), puntos de anclaje (anchor points) y las conexiones entre ellos. Explica qué hacer, en qué orden, y qué significa realmente cada campo de cada pantalla — no solo si es obligatorio u opcional.

> Esta guía describe la aplicación tal como existe hoy. Las pantallas de la aplicación están únicamente en inglés, así que cada campo a continuación muestra su etiqueta exacta tal como aparece en pantalla.

## 1. Primeros pasos

Se accede al área de administración automáticamente al iniciar sesión con una cuenta de administrador — no hay un inicio de sesión separado para administradores; la aplicación te dirige a la vista de administración según el rol de tu cuenta.

La navegación vive en un menú lateral (drawer), que se abre con el ícono de hamburguesa (☰) en la esquina superior izquierda de la pantalla. El encabezado del menú muestra "Admin" y tu correo electrónico de la sesión iniciada, y debajo, cuatro secciones:

- **Places** (ícono de bandera) — Lugares
- **Buildings** (ícono de edificio) — Edificios
- **Anchor points** (ícono de pin) — Puntos de anclaje
- **Connections** (ícono de línea) — Conexiones

Toca una sección para cambiar a ella; el menú se cierra automáticamente. El título en la parte superior de la pantalla siempre indica en qué sección te encuentras. Dos íconos siempre están disponibles en la esquina superior derecha: uno de actualizar (recarga todo desde el servidor) y uno de cerrar sesión (te desconecta de inmediato, sin confirmación).

## 2. Orden recomendado de trabajo

Las cuatro secciones no son independientes — cada una se construye sobre la anterior:

1. **Place (lugar)** — el campus o sede. Todo lo demás pertenece a uno.
2. **Building (edificio)** — un edificio físico dentro de un lugar. No se puede crear un edificio hasta que exista su lugar.
3. **Anchor point (punto de anclaje)** — un punto físico específico dentro de (o justo afuera de) un edificio. No se puede crear uno hasta que exista su edificio.
4. **Fotos** — todo punto de anclaje necesita al menos una foto, idealmente entre 4 y 8 tomadas en direcciones distintas, antes de que sea útil.
5. **Verificación** — después de revisar las fotos de un punto de anclaje, se cambia su estado (Status) a Verified. Este es el paso que realmente lo hace utilizable por la aplicación — ver la explicación en [5.3](#53-revisar-y-verificar).
6. **Connections (conexiones)** (opcional) — una vez que tienes dos o más puntos de anclaje verificados, puedes marcar que se puede caminar directamente entre ellos.

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

Toca el ícono de lápiz en la fila del edificio. Igual que con los lugares, **Code** no se puede cambiar después de creado — y nota que el campo **Place** ni siquiera aparece en la pantalla de edición: no es posible mover un edificio a otro lugar. Si un edificio quedó asignado al lugar equivocado, elimínalo y créalo de nuevo.

### Eliminar un edificio

Mismo patrón de advertencia en cascada que los lugares — verás cuántos puntos de anclaje, fotos y conexiones se eliminan junto con él.

### Campos de Building

| Etiqueta en pantalla | ¿Obligatorio? | Qué significa | Ejemplo |
|---|---|---|---|
| **Place** (solo al crear) | Obligatorio | A qué lugar pertenece este edificio. Filtra la lista de edificios que se verá en el resto de la aplicación. | Main Campus |
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
5. Completa la **Description** — obligatoria, e importante: este es el nombre que tú y otros administradores verán para este punto en toda la aplicación (resultados de búsqueda, listas, menús desplegables), así que debe describir el lugar real en vez de algo genérico. "Front door, north side" es mucho más útil después que "Point 1".
6. Configura **Indoor location** (activado por defecto) — si el punto está dentro de un edificio o afuera. Esto importa porque la precisión del GPS es mucho peor en interiores, que es exactamente por qué los puntos de anclaje interiores son los más importantes para el sistema de corrección de posición.
7. Opcionalmente configura **Lighting** (Bright / Moderate / Dim) y **Surface** (texto libre, ej. "tile", "carpet", "concrete", "grass") — ver la tabla de campos abajo para entender por qué vale la pena completarlos.
8. Confirma la posición — ya sea la ubicación GPS actual del dispositivo (se muestra automáticamente) o, si tocas **Pick on map**, una ubicación que toques en un mapa. Una ubicación elegida manualmente siempre tiene prioridad sobre el GPS. Úsalo cuando la deriva del GPS (común cerca de edificios altos) ubicaría el punto en el lugar equivocado.
9. Toca **Create and add photos** — esto guarda el punto de anclaje y te lleva directamente a la pantalla de captura de fotos ([§5.2](#52-tomar-fotos)).

#### Campos de Anchor point (creación y edición)

| Etiqueta en pantalla | ¿Obligatorio? | Qué significa | Ejemplo |
|---|---|---|---|
| **Place** / **Building** | Ambos obligatorios | A qué edificio pertenece este punto (el menú de Place solo filtra la lista de edificios). | — |
| **Location type** | Obligatorio, por defecto "entrance" | Qué tipo de lugar es este. Lista completa de opciones y significados en [§8](#8-referencia-rápida). | `entrance` |
| **Description** | Obligatoria | El nombre legible del punto — se muestra en todas partes. Describe el lugar real, no una etiqueta genérica. | `Front door, north side` |
| **Indoor location** (interruptor) | Activado por defecto | Interior vs. exterior — ver arriba por qué importa. | — |
| **Lighting** (menú desplegable) | Opcional, por defecto "Not set" | La iluminación típica de este lugar exacto: Bright / Moderate / Dim. Es un contexto útil para quien revise las fotos después (una foto oscura puede simplemente significar un pasillo con poca luz, no una mala foto), y con el tiempo esta información está pensada para ayudar a que el sistema de reconocimiento visual sea más confiable en distintas condiciones de luz. | Un lugar junto a una ventana grande al mediodía → `Bright`; una escalera interior con solo luces de techo → `Dim` |
| **Surface (optional)** | Opcional, texto libre | La superficie física del suelo. Puede servir como una pista útil de orientación (por ejemplo, un cambio de baldosa a alfombra puede marcar el límite de una sala). | `tile`, `carpet`, `concrete`, `grass` |
| **Location** | Obligatoria (GPS o selección en mapa) | Las coordenadas reales del punto. Una selección en el mapa siempre tiene prioridad sobre la lectura GPS en vivo del dispositivo. | — |

### 5.2 Tomar fotos

Por qué varias fotos: una persona podría acercarse al mismo lugar físico desde cualquier dirección, así que la aplicación necesita reconocer cómo se ve desde cada lado — no solo desde un ángulo.

1. En la pantalla de fotos verás una vista previa de la cámara en vivo. Una pequeña insignia en la esquina superior derecha muestra **"Facing: N°"** — el rumbo de la brújula en vivo del dispositivo (no la dirección del GPS), actualizándose en tiempo real. Esto se guarda automáticamente con cada foto, para que la aplicación sepa hacia dónde apunta esa foto.
2. Toca **Take photo** para capturar una. Se sube automáticamente y aparece en una cuadrícula de miniaturas debajo, con el rumbo con el que fue tomada mostrado en la esquina de cada miniatura.
3. Repite apuntando en direcciones distintas — como guía, apunta a 4-8 fotos, más o menos hacia norte/sur/este/oeste desde el mismo lugar (ajusta según el espacio real — un punto en una esquina quizás solo tenga dos o tres direcciones sensatas para fotografiar). La aplicación no exige un mínimo, así que esto depende de ti.
4. ¿Te equivocaste? Toca el ícono de basura en una miniatura para eliminar esa foto (con una confirmación).
5. Cuando termines, toca la marca de verificación (✓) en la esquina superior derecha de la pantalla — etiquetada "Done".

Siempre puedes volver más adelante a agregar o quitar fotos desde el botón **Manage photos** de un punto de anclaje (ver abajo).

### 5.3 Revisar y verificar

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

## 6. Connections (conexiones)

Una **connection** registra que una persona puede caminar directamente entre dos puntos de anclaje — va construyendo el grafo de transitabilidad que la aplicación podrá usar más adelante para dar indicaciones de ruta paso a paso, no es solo un enlace arbitrario entre dos pines.

Hay dos formas de crear una — elige la que se ajuste a la situación:

### Conectar tocando en el mapa

Más rápido, y funciona especialmente bien para conectar toda una secuencia de puntos a lo largo de un pasillo:

1. Desde el menú, ve a **Connections**, luego toca el botón **+** — etiquetado "Connect on map".
2. Elige un **Place**, y opcionalmente un **Building** para acotar más el mapa.
3. Toca un punto de anclaje en el mapa para seleccionarlo.
4. Toca un segundo punto de anclaje — esto crea la conexión entre ambos, y el segundo punto **queda seleccionado**, así puedes tocar de inmediato un tercer punto para seguir encadenando conexiones a lo largo del mismo pasillo sin empezar de nuevo cada vez.
5. Las conexiones existentes entre puntos visibles se dibujan como líneas verdes en el mapa, para que puedas ver de un vistazo qué ya está conectado.

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

Eliminar una conexión (ícono de basura, sin opción de editar — elimina y vuelve a crearla si necesitas cambiarla) no tiene efecto en cascada — no afecta a los dos puntos de anclaje en sí.

## 7. Eliminar datos

Eliminar un place, building o anchor point siempre muestra un cuadro de confirmación que indica exactamente qué más se eliminará junto con él, porque los datos son jerárquicos (place → building → anchor point → fotos/conexiones):

- **Eliminar un place** también elimina sus buildings, los anchor points de esos buildings, las fotos de esos puntos, y cualquier connection que los involucre.
- **Eliminar un building** también elimina sus anchor points, sus fotos, y cualquier connection que los involucre.
- **Eliminar un anchor point** también elimina sus fotos y cualquier connection que lo involucre.
- **Eliminar una connection** no afecta nada más.

La confirmación siempre muestra los números reales (por ejemplo, "will also delete 3 buildings, 12 anchor points, 45 photos, and 8 connections") antes de confirmar — léelo con atención. Nada de esto se puede deshacer.

## 8. Referencia rápida

### Location types (tipos de lugar)

| Opción mostrada en la aplicación | Significado |
|---|---|
| entrance | Entrada o puerta principal de un edificio |
| intersection | Intersección de pasillos |
| elevator | Zona de ascensor |
| stairwell | Zona de escaleras |
| classroom | Ubicación de un salón de clases |
| office | Ubicación de una oficina |
| restroom | Ubicación de un baño |
| cafeteria | Cafetería o zona de comedor |
| other | Cualquier cosa que no encaje en las anteriores |

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
