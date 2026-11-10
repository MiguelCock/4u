# C1: One admin map, and the map-first flow (#183)

**Status: proposal, waiting for approval.** C2 to C4 build on it. The parity check is [`c1-parity.md`](c1-parity.md).

## What's shared today

Five screens each build their own `FlutterMap`:
- `anchor_points_map.dart` (Anchor points tab)
- `connect_anchor_points_screen.dart`
- `location_picker_screen.dart`
- `session_tracking_screen.dart`
- `map.dart`'s `SimpleMapWidget` (navigation)

They repeat the same pieces:

| Piece | Repeated in |
|---|---|
| Tiles (`map_tile_config.dart`), no double-tap zoom | all five |
| Opening fit with `initialCameraFit` (moving the camera later dropped the tiles) | points map, session, navigation |
| Tap → nearest item on screen (`nearestOnScreen`), the selected floor first | points map, Connect, session |
| Floor selector, ▲/▼ for adjacent floors, "only this floor" | points map, Connect, picker, session |
| Status colour `verified/rejected/pending` → green/red/grey | points map, picker (and Connect, its own way) |
| Connection lines, dashed across floors | points map, Connect |

## The component

```
AdminMap                       lib/widgets/admin_map/admin_map.dart
 ├─ base: tiles, interaction flags, opening fit, floor state + FloorSelector,
 │        one onTap that asks each layer for its nearest hit, top layer first
 ├─ layers (each: what it draws, and hitTest(camera, tapped) → item?)
 │   ├─ PlacesLayer        flag + building count
 │   ├─ BuildingsLayer     building icon + point count
 │   ├─ PointsLayer        status colour, floor relation, selected / moving
 │   ├─ ConnectionsLayer   lines, dashed across floors, line hit-test (Connect's 16 px)
 │   └─ PinLayer           the location pin for picking / moving
 └─ mode: browse | pick | move | connect, with a banner and Cancel
```

- **Layers are data, not screens.** A screen passes the layers it needs. The session view keeps its own route/trail layers, on the same base.
- **Floor state lives in the base.** "Only this floor" is saved once (`saveOnlySelectedFloor` already exists), so every map agrees.
- **Navigation (`SimpleMapWidget`)** is the user's screen. It only takes the base's tiles and fit, not the admin layers.

## Hundreds of markers

Icesi has about 270 points. Each one is a `Marker` widget today, rebuilt on every frame of a pan.
- **Points on the selected floor as a `CircleLayer`.** It's drawn on one canvas, not one widget per point. Taps already go through `nearestOnScreen`, so markers don't need their own gestures.
- **Adjacent floors (▲/▼):** the same, through one painter.
- **What's shown follows the zoom:**
  - below about zoom 15, universities only
  - 15–17, buildings
  - from 17, points and connections

  This is also C2's drill-down, and it keeps the far-out view light.
- **Computed once per data change, not per build:** positions, floor relations and lines, keyed by the list's identity.
- **Target:** panning stays smooth with 1000 points on a mid-range Android, the admins' field phone. Checked with a profile build, and with a widget test that builds 1000 points within a time budget.

## The flow (C2, C3)

1. **The Anchor points tab's map becomes the admin's first screen**, showing every university. The lists stay one tap away (parity P3), so nothing is lost while admins get used to it.
2. **Drill down:**
   - Tap a university: the camera fits its buildings.
   - Tap a building: its points, connections and floor selector appear.
   - A breadcrumb at the top (`Todas › EAFIT › Biblioteca`) goes back up, and so does system back, one level at a time, like today's tab history.
3. **Search** at the top finds universities, buildings and points together, and moves the camera to the result.
4. **Details:**
   - **Phone:** tapping selects and opens the bottom sheet (today's point sheet, extended to buildings and universities).
   - **900 px or wider:** the same content in a side panel, plus a tooltip on hover. Nothing needs hover.
5. **Connect, move and pick are modes of the same map** (C3), with the banner and Cancel today's move already has. Connect keeps chaining and line deletion. The separate Connect screen goes once the parity rows C2, C6 and C7 pass on the new map.
6. **Colours** stay as they are in C1. C4 picks one palette for status, floors and connections, since red means *rejected* today.

## C1's own scope

- `AdminMap` with the base, `PointsLayer`, `ConnectionsLayer` and `PinLayer`.
- The Anchor points tab's map runs on it, with no lost function (parity P3, P12, F1–F3). `shot:points-map`, `points-map-floor2`, `points-map-only-floor`, `point-sheet` and `point-moving` are retaken and compared.
- Widget tests: tap → nearest point on the selected floor first; move mode reports the tap; the floor choice is shared; 1000 points build within budget.

## Needs your decision

1. **Map as the first admin screen**, with the lists one tap away (point 1)?
2. **Zoom levels** for universities, buildings and points: about 15 and 17, tuned on EAFIT and Icesi?
3. **Removing the separate Connect screen** once its rows pass on the map (point 5)?
4. **Side panel at 900 px or wider** on the web, bottom sheet on phones?
