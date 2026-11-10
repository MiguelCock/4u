# Field tests: one round, written once (B5)

*Versión en español abajo.*

One walking round answers several stories at once:
- **B1:** point spacing;
- **B2:** phones;
- **B6:** day and night;
- **B5:** how usable it is (SUS).

**Afterwards, send the time window** (start and end, with the date). One command (`loadtest/trip_report.py --since … --until …`) turns every trip into a report, and the conclusions go into each story. You don't need to write anything else down beyond the sheet below.

## Before the round
- **Every phone on the same app version** (Settings shows it). Note each phone's make and model on the sheet. From 0.6 the trip records it by itself.
- **Admin:** run **Re-index verified points**, and check the drawer shows no "photos not searchable".
- **Check the routes:** `loadtest/check_map.py`, or open each route in "Test as user".
- **Charge the phones,** and turn off battery saver: it stopped GPS before.

## The routes
- **The standard route:** the four stretches around the library, the one with history to compare against.
- **B1, spacing:** two routes also differ in light, buildings, GPS and photos, so comparing a close route with a far-apart one can't tell what caused a difference. Instead, compare **stretches that are alike apart from their spacing**:
  - choose them with an admin: same kind of place (both indoor corridors, or both open paths), similar light and buildings around;
  - one with points close together (4–5 m), one far apart (12 m or more);
  - **within the same route if it has both**, which is best.

  Note the stretches on the sheet. The report compares them stretch by stretch. Don't move or unverify points to make a test: other people's routes use them. A same-route comparison done offline (thinning a copy of a logged walk and replaying it) is planned, and would back this up.

## Each walk
1. **As an admin (a test walk):** use "Test as user", and tap **I'm at …** exactly on the start, each corner and the destination. This gives the true position. Long-press undoes a tap.
2. **As a participant:** a normal user account. Someone walks beside them, only stepping in for safety, and notes on the sheet where they had to.
3. **"Wrong instruction":** in a test walk, tap it the moment an instruction is wrong. Each tap is a timestamped problem in the report.

## Covering the stories in one round

| Story | What to do in the round |
|---|---|
| B1 spacing | a close and a far-apart stretch that are otherwise alike, best on the same route |
| D5 carrying | the standard route with the phone held in front, then at the ear or in a chest mount, noted on the sheet |
| B2 phones | each phone available walks the standard route once, cheap ones included |
| B6 night | the standard route once at dusk, or after dark, with one phone already used by day |
| B5 / SUS | each participant answers the 10 questions below right after their walk |

## The sheet (one row per walk)

| Time started | Phone | Route | Stretches compared (B1) | How carried | Who walked | Day/dusk/night | Arrived? | Had to help where? | SUS score |
|---|---|---|---|---|---|---|---|---|---|

## SUS: the System Usability Scale
Answer each from 1 (strongly disagree) to 5 (strongly agree).
1. I think I would like to use this app often.
2. I found the app unnecessarily complex.
3. I thought the app was easy to use.
4. I think I would need help from a technical person to use this app.
5. I found the various functions of this app well integrated.
6. I thought there was too much inconsistency in this app.
7. I imagine most people would learn to use this app very quickly.
8. I found the app very cumbersome to use.
9. I felt very confident using the app.
10. I needed to learn a lot of things before I could get going with this app.

**Score:**
1. odd items: the answer − 1;
2. even items: 5 − the answer;
3. add them up and × 2.5, for a score from 0 to 100.

Above 68 is about average.

## Before merging, and before a release (no walking)
- **Merging:** the changed components' tests pass, and CI is green, e2e included.
- **A release:** in addition,
  - one test walk of the standard route with the release APK, and its report shows no new kind of problem;
  - `deployment/deploy.sh` for the changed services ends in `OK`.

---

# Pruebas de campo: una ronda, escrita una vez (B5)

Una sola ronda de caminatas responde varias historias a la vez:
- **B1:** la separación de los puntos;
- **B2:** los teléfonos;
- **B6:** el día y la noche;
- **B5:** qué tan fácil es de usar (SUS).

**Al terminar, envía la ventana de tiempo** (inicio y fin, con la fecha). Un comando convierte cada recorrido en un informe, y las conclusiones van a cada historia. Aparte de la hoja de abajo, no hay que anotar nada más.

## Antes de la ronda
- **Todos los teléfonos con la misma versión de la app** (se ve en Ajustes). Anota en la hoja la marca y el modelo de cada uno; desde la 0.6 el recorrido lo guarda solo.
- **Admin:** ejecuta **Reindexar puntos verificados**, y revisa que el menú no muestre "fotos no buscables".
- **Revisa cada ruta** en "Probar como usuario".
- **Carga los teléfonos** y apaga el ahorro de batería: antes detenía el GPS.

## Las rutas
- **La ruta estándar:** los cuatro tramos alrededor de la biblioteca, la que tiene historia para comparar.
- **B1, separación:** dos rutas también difieren en luz, edificios, GPS y fotos, así que comparar una ruta cercana con una lejana no dice qué causó la diferencia. En su lugar, compara **tramos parecidos salvo por la separación**:
  - escógelos con un admin: el mismo tipo de lugar (dos pasillos interiores, o dos caminos abiertos), luz y edificios parecidos;
  - uno con los puntos cercanos (4–5 m) y otro con los puntos lejanos (12 m o más);
  - **mejor si están en la misma ruta.**

  Anota los tramos en la hoja; el informe los compara tramo a tramo. No muevas ni desverifiques puntos para una prueba: las rutas de otras personas los usan. Está planeada una comparación en la misma ruta hecha sin caminar (quitar puntos de una copia de una caminata registrada y repetirla), que respaldaría esto.

## Cada caminata
1. **Como admin (caminata de prueba):** "Probar como usuario", y toca **Estoy en…** justo en el inicio, en cada esquina y en el destino. Esto da la posición real. Una pulsación larga deshace un toque.
2. **Con un participante:** una cuenta de usuario normal. Alguien camina a su lado, solo interviene por seguridad, y anota en la hoja dónde tuvo que hacerlo.
3. **"Instrucción incorrecta":** en una caminata de prueba, tócalo en el momento en que una instrucción esté mal. Cada toque es un problema con su hora en el informe.

## Cubrir las historias en una ronda

| Historia | Qué hacer en la ronda |
|---|---|
| B1 separación | un tramo cercano y uno lejano parecidos en lo demás, mejor en la misma ruta |
| D5 cómo se lleva | la ruta estándar con el teléfono al frente, y luego en la oreja o en un soporte de pecho, anotado en la hoja |
| B2 teléfonos | cada teléfono disponible camina la ruta estándar una vez, también los económicos |
| B6 noche | la ruta estándar una vez al atardecer, o de noche, con un teléfono ya usado de día |
| B5 / SUS | cada participante responde las 10 preguntas de abajo justo después de caminar |

## La hoja (una fila por caminata)

| Hora de inicio | Teléfono | Ruta | Tramos comparados (B1) | Cómo se llevó | Quién caminó | Día/atardecer/noche | ¿Llegó? | ¿Dónde hubo que ayudar? | Puntaje SUS |
|---|---|---|---|---|---|---|---|---|---|

## SUS: escala de usabilidad del sistema
Responde cada una de 1 (totalmente en desacuerdo) a 5 (totalmente de acuerdo).
1. Creo que me gustaría usar esta app con frecuencia.
2. Encontré la app innecesariamente compleja.
3. Pensé que la app era fácil de usar.
4. Creo que necesitaría ayuda de una persona técnica para usar esta app.
5. Encontré que las funciones de esta app estaban bien integradas.
6. Pensé que había demasiada inconsistencia en esta app.
7. Imagino que la mayoría de las personas aprendería a usar esta app muy rápido.
8. Encontré la app muy incómoda de usar.
9. Me sentí muy seguro usando la app.
10. Necesité aprender muchas cosas antes de poder empezar a usar esta app.

**Puntaje:**
1. preguntas impares: la respuesta − 1;
2. preguntas pares: 5 − la respuesta;
3. suma todo y multiplica por 2,5, para un puntaje de 0 a 100.

Más de 68 es más o menos el promedio.
