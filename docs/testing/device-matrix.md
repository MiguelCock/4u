# Device matrix (B2)

*Versión en español abajo.*

What works on which phone. The measured columns come from the trips themselves: each trip records its phone (`navigation_sessions.device_info`) and each tick its sensors. After a round:

```bash
cd loadtest
uv run python round_report.py --since … --until …
```

prints the "By phone" table below (see `docs/testing/field-test.md`). The last four columns are checked by hand until the indoor module can test them (ARCore and Depth: I5 #314, I17 #327).

## The phones so far

| Phone | Android | App versions | Gyroscope | Barometer | Compass off the heading | GPS accuracy | Photo capture | Arrived | TalkBack | Jieshuo | ARCore | Depth |
|---|---|---|---|---|---:|---:|---:|---:|---|---|---|---|
| Xiaomi 2510DRA23L | 15 | 0.6.0-pre | yes | **no** | 63 % of ticks | 3.0 m | 0.39 s | 0/4 (4 trips, 2026-11-13) | to check | to check | to check | to check |

Trips before 0.6.0-pre recorded only the platform, so their phones are unknown. Wanted next: a low-end phone, one with Android 10, and any phone a participant uses with Jieshuo.

## When a sensor is missing or wrong

| Sensor | What the app does without it | Pinned by |
|---|---|---|
| Gyroscope | While walking a steady straight, the heading is the GPS course (trusted). Standing, it's the compass plus the offset learned while walking, not trusted, so no turn instructions. | `heading_tracker_test.dart`, "without a gyroscope" |
| Compass | No heading until a steady walk sets one from the GPS course; the gyroscope (if any) then keeps it through turns. The photo is sent without a heading, so the heading gate is skipped. | `heading_tracker_test.dart`, "without a compass (B2)"; `correction_request_test.dart` |
| Compass wrong (one phone was ~85° off) | It only sets the start; a steady walk overrides it and it's then ignored. The trip report flags "compass disagreement" over 45° on more than 20 % of ticks. | `heading_tracker_test.dart`, "walking a steady course corrects a wrong start" |
| Barometer | A floor change can't be heard: guidance waits 60 s per floor, then carries on and says so (`barometer_missing` event). | `route_progress_test.dart`, "with no barometer: 60 s per floor" |
| Camera (none, denied or covered) | Each tick logs raw GPS only; a covered lens is said once after three ticks. | `correction_loop_test.dart`, "no camera…", "a covered lens…" |
| GPS speed (iOS reports −1) | Standing still falls back to "the same fix again" (#310). | `backend-positioning/tests/test_session_store.py`, `test_stationary_reason` |

---

# Matriz de dispositivos (B2)

Qué funciona en qué teléfono. Las columnas medidas salen de los propios recorridos: cada recorrido guarda su teléfono (`navigation_sessions.device_info`) y cada tick sus sensores. Después de una ronda:

```bash
cd loadtest
uv run python round_report.py --since … --until …
```

imprime la tabla "By phone" de abajo (ver `docs/testing/field-test.md`). Las últimas cuatro columnas se revisan a mano hasta que el módulo de interiores pueda probarlas (ARCore y Depth: I5 #314, I17 #327).

## Los teléfonos hasta ahora

| Teléfono | Android | Versiones de la app | Giroscopio | Barómetro | Brújula lejos del rumbo | Precisión GPS | Captura de foto | Llegó | TalkBack | Jieshuo | ARCore | Depth |
|---|---|---|---|---|---:|---:|---:|---:|---|---|---|---|
| Xiaomi 2510DRA23L | 15 | 0.6.0-pre | sí | **no** | 63 % de los ticks | 3,0 m | 0,39 s | 0/4 (4 recorridos, 2026-11-13) | por revisar | por revisar | por revisar | por revisar |

Los recorridos anteriores a la 0.6.0-pre solo guardaban la plataforma, así que no se sabe en qué teléfono fueron. Lo siguiente: un teléfono de gama baja, uno con Android 10 y cualquier teléfono que un participante use con Jieshuo.

## Cuando falta un sensor o falla

| Sensor | Qué hace la app sin él | Lo fija |
|---|---|---|
| Giroscopio | Caminando en línea recta y constante, el rumbo es el del GPS (confiable). Quieto, es la brújula más la diferencia aprendida al caminar, no confiable, así que no da instrucciones de giro. | `heading_tracker_test.dart`, "without a gyroscope" |
| Brújula | No hay rumbo hasta que una caminata constante lo fija con el GPS; el giroscopio (si hay) lo mantiene en los giros. La foto se envía sin rumbo, así que el filtro de rumbo no se aplica. | `heading_tracker_test.dart`, "without a compass (B2)"; `correction_request_test.dart` |
| Brújula desviada (un teléfono marcaba ~85° de más) | Solo fija el inicio; una caminata constante la corrige y desde ahí se ignora. El informe del recorrido marca "compass disagreement" si pasa de 45° en más del 20 % de los ticks. | `heading_tracker_test.dart`, "walking a steady course corrects a wrong start" |
| Barómetro | No se oye un cambio de piso: la guía espera 60 s por piso, sigue y lo dice (evento `barometer_missing`). | `route_progress_test.dart`, "with no barometer: 60 s per floor" |
| Cámara (sin cámara, sin permiso o tapada) | Cada tick guarda solo el GPS; una lente tapada se dice una vez tras tres ticks. | `correction_loop_test.dart`, "no camera…", "a covered lens…" |
| Velocidad del GPS (iOS da −1) | Estar quieto vuelve a "el mismo fix otra vez" (#310). | `backend-positioning/tests/test_session_store.py`, `test_stationary_reason` |
