# C1: Admin parity list, checked (#183)

The admin parity list (everything admins could do before the overhaul) as rows to tick. The rule for C2 to C4 is that **admins can do everything they can today**, though not necessarily in the same place. A PR that moves a capability updates its row: where it lives now, and how it was checked.

**Check** says how the row is proved today:
- `shot:<name>` is a picture from `docs/admin-guide/tools/take_screenshots.mjs`, compared before and after.
- `test:<file>` is an automated test.
- `manual` is someone trying it.

**C2–C4** is ticked (☑) once the overhaul keeps it, with the new place if it moved.

## Overall

| ID | Capability | Today | Check | C2–C4 |
|---|---|---|---|---|
| O1 | Sign in, sign up | Login, Signup | `shot:login` | ☐ |
| O2 | Open the guide; help for the current page (web) | Drawer, app bar **?** | `test:widgets/admin_guide_test.dart` | ☑ C6: and the menu notices' **How to fix** (`test:widgets/review_list_test.dart`) |
| O3 | Refresh (button and pull) | App bar, every list | `test:widgets/tab_refresh_test.dart` | ☐ |
| O4 | Settings (detail, contrast, language, text size, voice) | App bar gear | manual | ☐ |
| O5 | Log out | Drawer | manual | ☐ |
| O6 | Narrow-window menu; side menu at ≥ 900 px | Drawer | `shot:home-menu` | ☐ |

## Menu notices

| ID | Capability | Today | Check | C2–C4 |
|---|---|---|---|---|
| N1 | Verified points with no connections → filtered list | Drawer | manual | ☑ C3: a review list, each to the map |
| N2 | Named points users can't choose → open, change type | Drawer sheet | manual | ☑ C3: each opens on the map |
| N3 | Connections over the limit → delete | Drawer sheet | manual | ☑ C3: each opens on the map |
| N4 | Floor changes with no stairs → delete | Drawer sheet | manual | ☑ C3: each opens on the map |

## Universities

| ID | Capability | Today | Check | C2–C4 |
|---|---|---|---|---|
| U1 | Search; list with building count | Universities tab | `shot:universities` | ☐ |
| U2 | Open a university's buildings, chip clears it | Row tap | manual | ☑ C2: also from the map (tap, or Details → list) |
| U3 | Add (code, name, address, lat/lng, pick on map) | FAB → form | `shot:university-form` | ☐ |
| U4 | Edit; change active state | Row → edit | manual | ☐ |
| U5 | Delete, saying what else goes | Row | manual | ☐ |

## Buildings

| ID | Capability | Today | Check | C2–C4 |
|---|---|---|---|---|
| B1 | Search; list with university and point count | Buildings tab | `shot:buildings` | ☐ |
| B2 | Open a building's points, chip clears it | Row tap | manual | ☑ C2: also from the map (tap, or Details → list) |
| B3 | Add (university, code, name, address, lat/lng, map, floors, elevator, stairs) | FAB → form | `shot:building-form` | ☐ |
| B4 | Edit, including moving to another university; active state | Row → edit | manual | ☐ |
| B5 | Delete, saying what else goes | Row | manual | ☐ |

## Anchor points

| ID | Capability | Today | Check | C2–C4 |
|---|---|---|---|---|
| P1 | Search; status filter with counts | Points tab | `shot:points-list` | ☑ C3: the list, and the map (search, status chips) |
| P2 | Filters: category/type, floor, in/outdoors, lighting, photos, connections; clear | Filters sheet | `shot:points-filters`, `test:services/anchor_filters_test.dart` | ☑ C3: the list and the map share them |
| P3 | List and map views | Segmented button | `shot:points-map` | ☑ C3: the Points tab is the list, the Map section the map |
| P4 | Create: university, building, floor, type (search, categories), description, in/outdoors, lighting, surface | FAB → Capture | `shot:point-form` | ☑ unchanged |
| P5 | Create: pick on map, seeing existing points | Location picker | `shot:location-picker` | ☑ C3: the picker runs on `AdminMap` |
| P6 | Create: use GPS on a phone (±8 m) | Capture | manual (phone) | ☑ unchanged |
| P7 | Warnings: point under 3 m; name on an in-between type | Capture, Edit | `test:services/capture_checks_test.dart` | ☑ unchanged |
| P8 | Form remembers the last point | Capture | manual | ☑ unchanged |
| P9 | Edit all of the above; status; move on map; thumbnails | Edit screen | `shot:point-edit`, `test:widgets/map_conflict_test.dart` | ☑ unchanged, also from the map's details |
| P10 | Photos: web upload with direction; phone camera with heading; delete; done | Photo screen | `shot:point-photos` | ☑ unchanged, also from the map's details |
| P11 | Verify from list, map or edit; refused with no photos; warning with no connections; unverify | Row, sheet, edit | `shot:verify-needs-photo`, `shot:verify-unconnected` | ☑ C3: list, map details, edit page |
| P12 | From the map: data, connect, move (pin, save, cancel), verify, add photo, edit | Map sheet | `shot:point-sheet`, `shot:point-moving` | ☑ C3: the Map section |
| P13 | Delete with what else goes | Row menu | `shot:points-row-menu` | ☑ unchanged (row menu) |
| P14 | Another admin's change: conflict dialog; edit screen notice | Every save | `test:widgets/map_conflict_test.dart`, `test:services/map_sync_test.dart` | ☑ unchanged |

## Floors

| ID | Capability | Today | Check | C2–C4 |
|---|---|---|---|---|
| F1 | Up and down | Every admin map | `shot:points-map-floor2`, `test:services/floor_view_test.dart` | ☑ C1: `AdminMap`; C4: re-checked in the new colours |
| F2 | Adjacent floors shown differently, and tappable | Every admin map | `test:services/floor_view_test.dart` | ☑ C1: `AdminMap`; C4: re-checked in the new colours |
| F3 | Only this floor, remembered | Every admin map | `shot:points-map-only-floor` | ☑ C1: `AdminMap`; C4: re-checked in the new colours |

## Connections

| ID | Capability | Today | Check | C2–C4 |
|---|---|---|---|---|
| C1 | Search; list with distance and warning | Connections tab | `shot:connections` | ☑ C3: with University and Building |
| C2 | Add on the map by tapping: chain, deselect, across floors | Connect screen | `shot:connect-map`, `shot:connect-selected` | ☑ C3: Connect mode on the map |
| C3 | Add by form (university, building filter, A, B, distance, warning) | Connection form | `shot:connection-form` | ☑ unchanged |
| C4 | Refused over the limit or a wrong floor change; warning over 15 m | Connect, form | `test:services/capture_checks_test.dart`, `shot:connection-warning` | ☑ C3: `connectTap` and the backend |
| C5 | Edit a warning | Row tap | manual | ☑ C3: a row, or the line's details |
| C6 | Delete from the list or the map line | Row, Connect map | manual | ☑ C3: a row, or the line's details |
| C7 | Jump from a point's row, with it selected | Points row tap | manual | ☑ C3: opens Connect mode with it selected |

## Users, sessions, feedback, re-index, phone only

| ID | Capability | Today | Check | C2–C4 |
|---|---|---|---|---|
| X1 | Users: list, promote/demote, activate/deactivate, repair, not on own row | Users tab | `shot:users` | ☐ |
| X2 | Sessions by user with counts; a user's sessions; comment; delete; refresh | Sessions | `shot:sessions`, `shot:user-sessions` | ☐ |
| X3 | Watch a session: route, raw, corrected, matches, reports, card, legend, tap details, live, floors | Session tracking | `test:services/route_error_test.dart`, manual | ☐ |
| X4 | Feedback: who, when, how the trip ended | Feedback screen | manual | ☐ |
| X5 | Re-index; "N photos not searchable"; what failed | Drawer | `test:services/anchor_indexing_test.dart` | ☐ |
| X6 | Phone: camera photos; Test as user (wrong-instruction, checkpoints, start check) | Drawer | manual (phone) | ☐ |

The users, sessions and feedback rows aren't part of the map overhaul. They're here so nothing reachable today gets lost from the menu (N15).
