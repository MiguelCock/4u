# Tuning the GPS correction and turn guidance

A field test on a long path showed three problems: wrong "turn 30-45°" cues while walking straight, the position jumping forward and back, and the trip ending ~40 m early because the position snapped onto the destination. This page explains the knobs that control those behaviours and how to tune them from real walks.

## 1. Collect data

1. Walk the route with **Test as user** (admin drawer). Tap **✗ Wrong instruction** every time the app says something wrong.
2. Open **Sessions → the user → Watch**. Compare:
   - the **orange dashed** raw GPS path,
   - the **green** corrected path,
   - the **purple dots** (photo matches) and their thin lines to the anchor point each one matched,
   - the **red ✗** marks.
3. Tap a point or an ✗ to see what was logged there. Every tick's full diagnostics are in `navigation_logs.debug`; every mark is in `guidance_reports`.

## 2. Server side: when a photo match may correct the position

Set these as environment variables in `backend-positioning/.env` on the server, then run `sudo docker compose up -d --force-recreate positioning`. No app release is needed. In each tick's `debug.correction.candidates`, every candidate has a `verdict` naming the gate that stopped it.

| Variable (default) | What it does | Symptom it addresses |
|---|---|---|
| `POSITIONING_MIN_MATCH_SCORE` (0.75) | Minimum photo similarity. | Raise it if many `applied` matches have low `score`s and pull the position wrongly. |
| `POSITIONING_MAX_MATCH_DISTANCE_M` (20), `POSITIONING_MATCH_ACCURACY_FACTOR` (2.5) | A match farther than max(20 m, 2.5 × GPS accuracy) from the GPS fix is ignored (`too_far`). | Jumps forward or back, and snapping onto anchors the camera sees in the distance. |
| `POSITIONING_HEADING_GATE_DEG` (60) | The matched photo must face within ±60° of where the phone faces (`heading_mismatch`). | Matches on photos taken the other way. |
| `POSITIONING_VISUAL_BASE_SIGMA_M` (3), `POSITIONING_VISUAL_SIGMA_PER_M` (0.3) | How hard an accepted match pulls: noise = 3 m + 0.3 × distance from the fix. | Raise them if accepted matches still pull too far in one tick. |
| `POSITIONING_MAHALANOBIS_GATE` (9.21) | A match inconsistent with the current estimate is refused (`mahalanobis`). | Sudden jumps. Lower it to be stricter. |
| `POSITIONING_SEARCH_RADIUS_M` (60), `POSITIONING_SEARCH_LIMIT` (5) | Which anchors are compared at all. | Fewer far-away candidates. |

The filter doesn't fuse the same GPS fix twice. Instead, a repeated fix means "not moving": the app's GPS stream only reports a new fix after 1 m of movement. Debug shows this as `gps_fused: false, stationary: true`. Without it, standing ~12 s while orienting let the next photo match move the position ~9 m. Process noise grows with real elapsed time.

What to look at in the debug: `score`, `distance_m`, `heading_diff`, `sigma_m`, `innovation_m` and `mahalanobis2` per candidate. If correct matches are being rejected as `too_far`, raise the distance; if wrong ones get through, lower it or raise the score.

## 3. App side: turn guidance (needs an app build)

The constants are in `application/lib/services/turn_guidance.dart` and `application/lib/user/navigation_screen.dart`.

- **Bearing:** guidance follows the route segment's own direction while the position is within 10 m of the line (`guidanceBearing`, `toleranceMeters`). It steers back gently (20 m look-ahead) only when farther off. A sideways wobble no longer asks for a turn.
- **Compass:** smoothed over 1 s (`HeadingSmoother.timeConstant`), and corrected from magnetic to true north with `MAGNETIC_DECLINATION` in `application/.env` (−7.5 for Medellín).
- **Thresholds:** aligned within 25°, turn cue beyond 35°, off-course when the median of the last 5 samples is beyond 50° for 3 s.
- **Corners:** guidance stops only where the route turns more than 30°, at named places and at the destination (`routeCorners` in `geo_utils.dart`), so a 40 m straight is one instruction, not six. A corner is reached within 8 m, or once you've walked to 8 m before it along the straight (`_kCornerMeters`). A 20 m radius announced turns ~15 m early.
- **Arrival:** the corrected position within twice the GPS accuracy (5–15 m, and never more than half the last leg), *and* raw GPS within that plus 10 m, on 2 ticks in a row (`arrivalRadius` in `turn_guidance.dart`). A fixed 15 m ended a trip at the last corner because the last leg was 13 m. Skipping past the next waypoint also needs raw GPS to agree.
- **Source switch:** when the correction is older than 5 s, guidance blends to raw GPS over 2 s instead of jumping.

In the debug, `turn`, `target_bearing`, `compass`, `position_source` and `guidance` show what guidance saw when it spoke (`cues`).
