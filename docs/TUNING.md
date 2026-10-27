# Tuning the GPS correction and turn guidance

A field test on a long path showed three problems: wrong "turn 30-45°" cues while walking straight, the position jumping forward and back, and the trip ending ~40 m early because the position snapped onto the destination. This page explains the knobs that control those behaviours and how to tune them from real walks.

## 1. Measure it: test walks along the route

For testing, walk the planned route **exactly**. Any distance between the reported position and the route is then correction error.

1. Start the route with **Test as user** (admin drawer). In this mode:
   - Each camera frame is saved, so photo models can be compared later on real photos (bucket `navigation-frames`, linked from `navigation_logs.raw_image_url`).
   - Arrival is announced, but the trip stays open.
2. Tap **I'm at …** while standing exactly on each checkpoint: the start, every corner, the destination. The button names the next one. A long press undoes the last tap. The destination tap ends the walk.
   - At a checkpoint the true position is known exactly.
   - Between two checkpoints, assuming a steady pace gives it for every tick. That catches forward/backward errors, not only sideways ones.
3. Tap **✗ Wrong instruction** whenever the app says something wrong.
4. **Sessions → the user → Watch** opens the map with a card on top:
   - Distance from the route for raw GPS and for the corrected position (mean and p90).
   - How often the correction was closer.
   - The error at the checkpoints.
   - Blue flags mark the checkpoints.

### Replaying a walk offline

Export the session on the server (read-only), copy it here, and replay it through the filter with different settings, without walking again:

```bash
ssh ec2-user@<instance> 'cd ~/4u && sudo docker compose exec -T positioning \
  /app/.venv/bin/python scripts/export_session.py [SESSION_ID]' > session.json
cd backend-positioning
uv run python scripts/replay.py session.json
uv run python scripts/replay.py session.json --grid gps_bias_sigma_m=0,2.5,4,6 gps_bias_tau_s=60,120,300
```

It prints the error for raw GPS, for the logged correction, and for the replayed one: distance from the route, plus 2D error when checkpoints were tapped. Any `MatchConfig` field can be set with `--set name=value`. Pick values that improve the 2D error, not just the distance from the route. Sessions recorded before the switch to EigenPlaces have EfficientNet scores, so replay them with `--set min_score=0.75`.

### Comparing photo models

`backend-ai-training/scripts/benchmark_models.py session.json photos_dir` scores models on the anchor photos. Each photo queries the *other* anchors near it that face the same way, and should find the nearest one. Download the photos named `<photo id>.jpg` from `anchor_point_photos.image_url`.

Results on the 236 campus anchor photos (2 CPU threads):

| Model | Top match is the right anchor | Near ranked above far (AUC) | Time per photo |
|---|---|---|---|
| EfficientNet-B0 (first model) | 31% | 0.75 | 26 ms |
| DINOv2 ViT-S/14 | 39% | 0.77 | 142 ms |
| **EigenPlaces ResNet50 (in use)** | 36% | 0.83 | 285 ms |
| MegaLoc, 224 px | 42% | 0.87 | 531 ms |
| MegaLoc, 322 px | 44% | 0.86 | 1068 ms |

EigenPlaces is the best within the ~0.5 s budget on the server. MegaLoc is a little better again, but 2–4× slower; the frames from test walks will show whether that's worth it. To switch model, set `EMBEDDING_MODEL` in `backend-ai-training/.env`, restart, run **Re-index verified points** in the admin menu, and set `POSITIONING_MIN_MATCH_SCORE` for its scale.

## 2. Collect data

1. Walk the route with **Test as user** (admin drawer). Tap **✗ Wrong instruction** every time the app says something wrong.
2. Open **Sessions → the user → Watch**. Compare:
   - the **orange dashed** raw GPS path,
   - the **green** corrected path,
   - the **purple dots** (photo matches) and their thin lines to the anchor point each one matched,
   - the **red ✗** marks.
3. Tap a point or an ✗ to see what was logged there. Every tick's full diagnostics are in `navigation_logs.debug`; every mark is in `guidance_reports`.

## 3. Server side: when a photo match may correct the position

Set these as environment variables in `backend-positioning/.env` on the server, then run `sudo docker compose up -d --force-recreate positioning`. No app release is needed. In each tick's `debug.correction.candidates`, every candidate has a `verdict` naming the gate that stopped it.

| Variable (default) | What it does | Symptom it addresses |
|---|---|---|
| `POSITIONING_MIN_MATCH_SCORE` (0.25) | Minimum photo similarity, on the scale of the photo model in use (0.25 for EigenPlaces, 0.75 for the old EfficientNet). | Raise it if many `applied` matches have low `score`s and pull the position wrongly. |
| `POSITIONING_MAX_MATCH_DISTANCE_M` (20), `POSITIONING_MATCH_ACCURACY_FACTOR` (2.5) | A match farther than max(20 m, 2.5 × GPS accuracy) from the GPS fix is ignored (`too_far`). | Jumps forward or back, and snapping onto anchors the camera sees in the distance. |
| `POSITIONING_HEADING_GATE_DEG` (60) | The matched photo must face within ±60° of where the phone faces (`heading_mismatch`). | Matches on photos taken the other way. |
| `POSITIONING_VISUAL_BASE_SIGMA_M` (3), `POSITIONING_VISUAL_SIGMA_PER_M` (0.3) | How hard an accepted match pulls: noise = 3 m + 0.3 × distance from the fix. | Raise them if accepted matches still pull too far in one tick. |
| `POSITIONING_MAHALANOBIS_GATE` (9.21) | A match inconsistent with the current estimate is refused (`mahalanobis`). | Sudden jumps. Lower it to be stricter. |
| `POSITIONING_SEARCH_RADIUS_M` (60), `POSITIONING_SEARCH_LIMIT` (5) | Which anchors are compared at all. | Fewer far-away candidates. |
| `POSITIONING_GPS_BIAS_SIGMA_M` (4), `POSITIONING_GPS_BIAS_TAU_S` (120) | GPS is modelled as off by a slowly changing amount: typically this many metres, changing over this many seconds. A photo match corrects that offset, and the correction persists instead of fading at the next GPS fix. 0 turns it off. | On a known path GPS was 3–5 m to one side for a whole straight. Without this, each fix pulled the position back to that side. Replaying that walk: distance from the route 3.64 m (off), 2.70 m (2.5), 2.28 m (4). |
| `POSITIONING_GPS_SIGMA_FACTOR` (1.0) | Scales the phone's reported GPS accuracy. | Raise it if GPS is worse than it claims, so matches count for more. |

The filter doesn't fuse the same GPS fix twice. Instead, a repeated fix means "not moving": the app's GPS stream only reports a new fix after 1 m of movement. Debug shows this as `gps_fused: false, stationary: true`. Without it, standing ~12 s while orienting let the next photo match move the position ~9 m. Process noise grows with real elapsed time.

Debug also shows the estimated GPS offset (`gps_bias`, metres east/north), `score_margin` (how far the best anchor's score stands out from the next one's), and timings (`search_ms`, `total_ms`; the app adds `timing_ms.capture/correct`).

What to look at in the debug: `score`, `distance_m`, `heading_diff`, `sigma_m`, `innovation_m` and `mahalanobis2` per candidate. If correct matches are being rejected as `too_far`, raise the distance; if wrong ones get through, lower it or raise the score.

## 4. App side: turn guidance (needs an app build)

The constants are in `application/lib/services/turn_guidance.dart` and `application/lib/user/navigation_screen.dart`.

- **Bearing:** guidance follows the route segment's own direction while the position is within 10 m of the line (`guidanceBearing`, `toleranceMeters`). It steers back gently (20 m look-ahead) only when farther off. A sideways wobble no longer asks for a turn.
- **Compass:** smoothed over 1 s (`HeadingSmoother.timeConstant`), and corrected from magnetic to true north with `MAGNETIC_DECLINATION` in `application/.env` (−7.5 for Medellín).
- **Thresholds:** aligned within 25°, turn cue beyond 35°, off-course when the median of the last 5 samples is beyond 50° for 3 s.
- **Corners:** guidance stops only where the route turns more than 30°, at named places and at the destination (`routeCorners` in `geo_utils.dart`), so a 40 m straight is one instruction, not six. A corner is reached within 8 m, or once you've walked to 8 m before it along the straight (`_kCornerMeters`). A 20 m radius announced turns ~15 m early.
- **Arrival:** the corrected position within twice the GPS accuracy (5–15 m, and never more than half the last leg), *and* raw GPS within that plus 10 m, on 2 ticks in a row (`arrivalRadius` in `turn_guidance.dart`). A fixed 15 m ended a trip at the last corner because the last leg was 13 m. Skipping past the next waypoint also needs raw GPS to agree.
- **Source switch:** when the correction is older than 5 s, guidance blends to raw GPS over 2 s instead of jumping.

In the debug, `turn`, `target_bearing`, `compass`, `position_source` and `guidance` show what guidance saw when it spoke (`cues`).

## 5. Findings from the third test walk (session f0fb7820, 2026-10-27)

The route was 131 m with four straights. It produced 27 ticks, 5 checkpoints and 6 "wrong instruction" reports.

**The correction works; it was showing up late.**
- Each `/correct_position` round trip took 5–7 s, so ticks ran every ~6 s. On the server, `total_ms` was ~1.7 s, of which the photo search (`search_ms`) was ~1.4 s.
- The app kept showing each answer until the next one arrived, so it described where the user had been 5–11 s earlier.
- Scored at the moment each photo was taken (not when the log was posted), the error was 7.6 m for raw GPS and 4.2 m corrected.
- At the checkpoints:

  | Checkpoint | 0 | 1 | 2 | 3 | 4 | mean |
  |---|---|---|---|---|---|---|
  | raw GPS | 6.2 | 4.0 | 3.0 | 5.1 | 9.6 | 5.6 |
  | corrected, as shown (stale) | 7.7 | 15.0 | 12.1 | 7.8 | 11.1 | 10.7 |
  | live fix + last correction offset | 0.8 | 3.8 | 1.8 | 3.6 | 7.5 | 3.5 |

**What changed:**
- **Position:** the app now applies the latest correction's offset to the live GPS fix for up to 20 s (`_kCorrectionFreshness`). That offset is mostly the GPS's own slowly changing error. Checkpoints record that live value and its age (`correction_age_s`).
- **Scoring:** `scripts/replay.py` scores each tick at its photo time (`debug.photo_at`, or the log time minus `timing_ms` for older logs). It also prints each checkpoint's error.

**Every report came from the compass.**
- `flutter_compass` (Android's rotation vector, referenced to the magnetometer) counted about 70° for each real 90° left turn. Its error grew at every corner: +20, +50, +65 and +80° on the four straights, while the GPS course matched the route within ~10°.
- The user turned by the angle they were told, and was told to turn more. On the third straight, guidance never left "orienting" and kept repeating "turn left".
- The same error made the heading gate refuse good photo matches. Replaying with that gate off scored better: 3.98 m against 4.80 m.
- **Fix:** `HeadingTracker` (`application/lib/services/heading_tracker.dart`).
  - The gyroscope, projected on the vertical, measures turns.
  - The GPS course anchors the absolute direction while walking a steady straight: ≥ 0.7 m/s, 3 courses within 20°, time constant 3 s.
  - The compass only sets the starting direction, and pulls weakly (60 s) after a minute with no walking.
  - The heading sent to positioning is the tracked one, converted back to magnetic.
  - Logs carry `heading`, `heading_source` and `compass_vs_heading`.

**Latency changes:**
- ai-training prepares its Qdrant collection once per process; it used to make 4 Qdrant Cloud round trips on every search.
- Verified tokens are cached for 60 s (`packages`).
- The admin check for test-walk frames runs alongside the search.
- New in the positioning `debug` output: `upload_ms` (the photo arriving), `auth_ms`, and `search_timing` (`embed` and `qdrant`), to show where the rest of the round trip goes.

**Not retuned yet.** With only 15 corrected ticks, and the heading gate fed a broken compass, this walk is too small to tune on. In the grid, `gps_bias_sigma_m=6` with the heading gate off scored best. Re-run the grid on the next walk.

## 6. Fourth test walk (session f4e3fd25, 2026-10-27)

The same route, with the live corrected position and the gyroscope heading:

| | raw GPS | corrected |
|---|---|---|
| off route (mean) | 3.58 m | **0.73 m** |
| 2D at photo time (mean) | 6.04 m | **3.15 m** |
| checkpoints 0 / 1 / 2 / 3 / 4 | 3.4 / 4.2 / 5.9 / 8.8 / 15.2 m | 1.0 / 5.5 / 1.1 / 1.0 / 8.8 m |

- **Ticks:** every ~2 s, with `/correct_position` taking a median 1.3 s. On the server, embedding takes 440 ms and the Qdrant query 350 ms. Auth and upload are now ~0.
- **Heading:** the gyroscope heading was anchored to walking on 74 of 86 ticks. Every turn was announced as about 90°, which was right.
- **Photo index:**
  - **Finding:** the new model's collection held 176 of 298 photos. The re-index had silently stopped short, and 10 anchors on this route were missing, including the corner before leg 3 and the point before the destination.
  - **Effect:** on the last leg, the only match was the corner behind the user, which held the position back. The destination ended 8.8 m off, and arrival didn't fire.
  - **Fix:** all 298 are indexed now. `GET /index_status` and the admin re-index show and fill any gap.
- **Corner timing:**
  - **Finding:** all 3 reports were turn instructions spoken 5–8 s before the user reached the corner. The 8 m reach radius was sized for 5–10 m position error.
  - **Fix:** the corner now counts as reached at 3 m (`cornerProgress`), or as soon as the user has turned onto the next leg near it. A heads-up comes at 8 m.
- **Turn repeats:** "Turn left about 60°" came halfway through a turn. Repeats now wait until the needed turn has stopped changing.
- **Tried and not adopted:** a match fixing only the position across the camera's view, not along it. In replay the 2D error ranged from 2.79 to 3.65 m depending on settings, so it isn't worth the complexity yet.
