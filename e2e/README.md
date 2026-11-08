# Behavior test suite (E3)

Proof that the whole system still behaves the same: every flow the app runs, and every field it reads, through the gateway, the way the app calls it. It runs on a copy of the system on your computer or in CI, and **never on production.**

```bash
scripts/e2e.sh          # start everything from clean, run the suite, leave it running
scripts/e2e.sh -k trip  # pytest's own options pass through
scripts/e2e.sh down     # stop it all
```

Needs Docker, `uv`, and the [Supabase CLI](https://supabase.com/docs/guides/cli), pinned to 2.121.0 in CI. Use `SUPABASE_CLI=/path/to/supabase` if it isn't on your `PATH`. A first run takes some minutes to download and build; after that, about a minute.

## What runs

| Part | Where it comes from |
|---|---|
| Postgres, Auth, the REST API, Storage | Supabase's local stack (`supabase/config.toml`, `supabase start`) |
| The database | `db_schema/`, applied in dependency order by `scripts/e2e_db.sh`, which fails if a table file isn't listed or doesn't apply |
| Photo search's vectors | a local Qdrant, empty each run |
| The 7 services and the gateway | `docker-compose.yml`, with `docker-compose.e2e.yml` on top |

`docker-compose.e2e.yml` gives every service its settings and resets their `env_file` (`!reset`), so nothing reads a `.env`. **A computer whose `.env` files hold real keys still can't reach production from here.** It uses its own Compose project (`eyes4u-e2e`) and gateway port (18000), so it runs next to a development stack.

## What it checks

| File | Checks |
|---|---|
| `tests/test_1_accounts.py` | sign-up, the profile self-heal, roles, admin-only refusals, preferences |
| `tests/test_2_mapping.py` | the test campus: capture, photos, connections, verify, photo search; the 30 m and verify-needs-a-photo guardrails, duplicate connections, warnings, reconcile |
| `tests/test_3_trip.py` | a trip: route, session, a photo corrected to its point, logs, end, feedback, guidance reports; what an admin sees, and what another user can't |
| `tests/test_4_many_admins.py` | A5: a save over another admin's change is a 409, different fields both apply, older apps still save, `/changes` |
| `tests/test_5_contracts.py` | every read the app makes keeps the fields it uses (`contracts.py`), and the version policy: current and oldest supported work, older and missing get 426 |

The `campus` fixture (`conftest.py`) builds the smallest map a trip can use: a university, a building, and three verified points 10 m apart. Test photos are generated (`stack.photo`), never real camera frames, and differ in every run.

**When the app starts reading a new field, add it to `contracts.py`.** That's what stops a backend change from removing it unnoticed.

## Proven

**A field removed on purpose fails it.** Hiding `notes` from the connections response failed four tests, each naming the field: `connections: the app reads ['notes'], which are gone`.

**It found a real bug while being written.** Postgres stores coordinates with more digits than it sends back, so A5's conflict check refused every move of a GPS-placed point (#217).

## Found, not fixed here

- **A photo uploaded under a name already in storage answers 500, not a readable error.** The app never sends one, since it adds a random suffix.
- **`backend-user-management`'s endpoints are still `async def` around blocking calls,** the pattern A2 removed from map and navigation management. That's for E2.

## Not covered yet

The app's own screens: those stay with `flutter test`. Driving the real app against this stack, and B3's replays of logged walks, come once B3 exists.
