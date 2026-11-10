# Many admins at once (A5, #201)

Measured on 2026-11-07, after deploying #212 and its migration (`db_schema/migrations/2026-11-07_map_changes.sql`).

## Conflicts, against the real database

Two test admins edited one sandbox point through the public API:

| Case | Answer |
|---|---|
| A renames it, nothing changed meanwhile | 200 |
| B renames it from the name it had opened | **409**, `fields: [location_description]`, with A's name |
| B moves it, which A didn't touch, with the stored coordinates | 200: doubles compare exactly, and unrelated edits both apply |
| B rejects it after A already did | **409** on `status` |
| A stale `metadata` | **409** |
| No `expected`, as older apps send | 200, as before |
| `GET /changes` after the edits | lists the point |
| `GET /changes` after deleting it | the trigger reports its id, and it's no longer listed |

## Refresh cost, 5 simulated admins for 5 minutes each

The same run twice: the old app's behaviour (`LOADTEST_ADMIN_FULL_RELOADS=1`, all five lists after every edit), then the new one (`/changes` after every edit, with a full load only on opening).

| | Old: all five lists | New: `/changes` |
|---|---:|---:|
| Full list loads | 85 of each | 5 of each, on opening |
| Refresh data | 38.4 MB | 2.7 MB |
| One refresh | about 470 KB | 5.6 KB |
| One refresh, p50 / p95 | about 1.0 / 1.7 s | 1.0 / 1.6 s |
| Edits | 202 | 240 |
| Failures | 0 | 0 |

**About 80 times less data per refresh, but no faster.** `/changes` makes its six Supabase queries one after another, so it takes as long as the five lists did in parallel. Running them at the same time is the obvious next step. The size matters most for admins on mobile data, and for the load on Supabase.

Afterwards, cleanup left no test data, and real counts were unchanged.

## Still to do
- Two real admins editing the same point at once, as the story asks.
- Running `/changes`'s queries in parallel.
- Phone admins get this with the 0.6 APK. Until then, they behave as before.
