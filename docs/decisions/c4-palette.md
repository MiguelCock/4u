# C4: One palette for the admin maps (#186)

**Decided on 2026-11-10: option C**, the Okabe–Ito colour-blind-safe set, with the marks a little larger. It lives in `application/lib/theme/admin_palette.dart` (`kAdminPalette`), and every admin screen takes its colours from there.

## Why it changed

Before C4, each screen chose its own colours:
- Floors were purple and orange, next to the green, grey and red of the statuses.
- Red meant *rejected*, so the issue's first idea, red floors, would have collided with it.

Measured, the old colours failed 11 checks:
- the dots were faint on the map (contrast 1.7 against OSM's land colour);
- verified and rejected nearly merged for deuteranopia, the most common colour blindness (CIEDE2000 distance 6.0);
- the floor below and rejected merged for tritanopia (2.3).

## How the options were measured

`application/lib/theme/palette_checks.dart`, tested in `test/theme/admin_palette_test.dart`:
- **Contrast:** WCAG's ratio between each mark and the map's light backgrounds (land, park, grass, water, building), taking the lowest. Graphics that carry meaning need 3.0 (WCAG 1.4.11). A filled dot passes through a dark outline instead. A ✕ or a ring has no outline, so it must pass on its own.
- **Telling colours apart:** the CIEDE2000 distance between each pair of meanings, under typical vision and simulated protanopia, deuteranopia and tritanopia (Machado 2009, full severity). Pairs that must differ:
  - the three statuses
  - each floor against each status
  - the selection against each status

  A pair the palette tells apart by shape (a ✕, a ring, ▲ against ▼) is exempt. Otherwise it needs at least 10.
- **The formulas** are checked against WCAG's black-on-white 21:1 and Sharma's published CIEDE2000 test pairs.

## The options

| | Today | A · floors red and blue | B · floors by shape | **C · colour-blind-safe** |
|---|---|---|---|---|
| Verified | #4CAF50 dot | #4DB6AC dot | #66BB6A dot | **#009E73 dot** |
| Pending | #9E9E9E dot | #616161 ring | #757575 dot | **#BDBDBD dot** |
| Rejected | #F44336 dot | #212121 ✕ | #8E0000 dot | **#A84400 ✕** |
| Floor above ▲ | #9C27B0 | #C62828 | #1A237E | **#0072B2** |
| Floor below ▼ | #FF5722 | #1565C0 | #1A237E | **#6A3D9A** |
| Selected | #2196F3 | #0D47A1 | #1565C0 | **#000000** |
| Dot outline | none | #263238 | #263238 | **#000000** |
| Checks failed | 11 | 0 | 0 | **0** |
| Closest colour-only pair | floor below / rejected, 2.3 | floor above / pending, 17.7 | selected / pending, 20.4 | **floor above / verified, 12.4** |

All three options were tuned until they passed:
- **A:** a light green beside a dark red, so they differ in lightness for protanopia.
- **B:** a lighter green and darker red, apart for deuteranopia.
- **C:** a darker orange for the ✕, and a purple floor below, apart from that orange for tritanopia.

## Why C

It's the set designed for colour blindness, and it needs the fewest exceptions:
- Each status and each floor has its own hue, so nothing relies on ▲ against ▼ alone.
- Black is kept for the selection and the outlines.

A would have changed how statuses read more (a ring, a black ✕). B gives up colour for floors entirely.

**The marks became a little larger** at the same time:
- points: a 9 px radius dot, about 18 px across;
- the ✕: 28 px; the selection ring: 34 px;
- ▲▼: 40 px; university and building icons: 34 px.

## Where it applies

- **Every mark on the admin maps** (Map section, location picker): statuses, floors, connections, selection, pins, universities and buildings.
- **A session's map:** planned, raw, corrected, photo matches, wrong-instruction reports, checkpoints.
- **Icons standing for those things** in the menu and lists, and the menu's notices.

Error text keeps the theme's error colour. The menu's tool entries (Sessions, Feedback, Re-index) keep their neutral teal: they don't stand for anything on the map. The user's navigation map is not an admin screen, so it isn't included.
