# Load test

Simulates people using the deployed server, to learn what it can handle and what breaks first. Story A1 (#173). Results go in `docs/loadtest/`.

**It runs against production, so it only runs in an agreed window**, with no testers or admins working.

## What it simulates

- **Navigating users** copy the app: sign in, read the lists, `find_or_create`, then a real photo and a log per tick, waiting after each answer as the app does. A slow server therefore shows up as a longer gap between photos, which is what users feel. They replay real EAFIT walks (photos and GPS), each starting at a different point.
- **Admins** open the home screen (five whole lists), create points with a photo, connect them, rename them, and verify them, which runs the photo model in the service users' searches need. They reload after each change, except connecting, as the app does.

## Why it can't damage real data

- **`loadtool/guards.py`:** every write goes through a guard that refuses anything but the user's own trip and the sandbox. Real points and connections are only read. `tests/test_locustfile.py` runs the real scenario against a stub and checks every write.
- **The sandbox** is an inactive university ("Prueba de carga") far from any campus, so users are never offered it, and its photos can't match a search, which only looks within 60 m.
- **Users** only ask for a saved route that's still walkable, which the server returns without writing (`trips.choose_route`).
- **Accounts** are `loadtest-*`, created with the admin API, which sends no email. Sessions and logs go when they're deleted.
- **`cleanup.py`** always runs after a run, even on Ctrl-C. It removes all of it, then compares real row counts with those from before. Run it by hand if a machine dies mid-run.
- **Automatic stop:** a run ends at over 5% errors, photo p95 over 15 s, 45 s with no answers, or containers at 2800 MB of memory, and the heavier steps after it are skipped. This reduces the risk of freezing the server but doesn't remove it (it happened at 10 users, see `docs/loadtest/baseline.md`), so check the server's health on a timer during a run, and be ready to reboot.

## Running it

From this folder, needing `packages/.env` and `application/.env`, and fresh AWS credentials for SSH:

```bash
uv sync
uv run python prepare.py                 # read-only: downloads the walks, picks a route
uv run python run.py smoke --window      # 3 minutes: try this first
uv run python run.py all --window        # about 1.5 hours
```

| Run | Who | Length | Answers |
|---|---|---|---|
| `smoke` | 1 user, 1 admin | 3 min | Does the tool work; does cleanup restore everything |
| `baseline` | 1 user | 5 min | Does it match real trips (about 3 s between photos, 0.9 s of server time)? If not, fix the tool before trusting the rest |
| `users` | 5, 10, 15, 20 users | 5 min each | Where it stops keeping up |
| `admins` | 5, 10 admins | 5 min each | What many admins cost alone |
| `mixed` | 10 users + 5 admins | 10 min | The real case |
| `long` | 10 users | 30 min | Whether CPU credits run out |

Results and the report are in `.data/results/<time>/`. `.data/` is never committed: it holds passwords and photos that can show people. Copy the conclusions to `docs/loadtest/`.

To calibrate against real trips, `LOADTEST_CAPTURE_SECONDS` sets how long a simulated phone takes to capture a photo.

## Limits

It can't test phones, campus Wi-Fi or real walking. It also adds real load to Qdrant and Supabase, and uses their quotas.

## Overloading ai-training locally

`local_ai_training.py` overloads the photo service on your own computer, pinned to 2 CPUs like the server, so changes can be tried without touching production. It reproduces the server's collapse at 10 users (about 6.6 s per photo, 2.7 GB).

```bash
uv run python local_ai_training.py --build --rate 3.3 --seconds 120
```

Compare runs with each other, not with production: Qdrant is local and empty here. Pick CPUs your desktop isn't busy on with `--cpuset`: a browser on them made 5 users look worse than 10.

## Event tools

For running an event alone: see `docs/event/checklist.md` and `docs/event/runbook.md`. Only `event_accounts.py` writes anything.

| Tool | Does |
|---|---|
| `watch.py` | The live view, every 15 s: services, errors and rate limits, photos (matched, busy, server time against network time), each machine's CPU and memory, and how long the AWS credentials have left. Red names the runbook section to use. |
| `check_map.py` | Whether a route is ready, checking the path the server would give today: blockers (not verified, not searchable, not connected) and warnings (few photos, wide gaps). `--place 050022` lists EAFIT's routes and pending points. |
| `event_accounts.py` | Attendee accounts through the admin API, with no sign-up emails. The list, with passwords, goes to `.data/event-accounts.csv`, readable only by you. `--delete --yes` also deletes their trips. |
| `event_report.py` | After an event: phone by phone, photos matched, failed ticks, and how much of each photo's time was the network. Phones are numbered, never named. |

## Trip report (B3)

What happened on a test walk, in one command, read-only:

```bash
uv run python trip_report.py b73b686d          # one trip, by id or its first characters
uv run python trip_report.py --since 2026-11-20T14:00 --until 2026-11-20T17:00
uv run python trip_report.py b73b686d --save session.json   # for backend-positioning's replay.py
```

**Per trip:**
- the phone and app version (from 0.6 on; older trips say "not logged");
- stops reached, with when;
- photos matched and failures, the correction size;
- the heading: trusted share, compass disagreement, source;
- what was said, with a timeline of instructions;
- **likely problems**, each with its time.

**The problems it looks for** (rules in `loadtool/trip.py`, tested on made-up trips in `tests/test_trip.py`):
- **spinning:** 3 or more turn cues in 60 s, with GPS moving under 10 m;
- **stuck:** the app's stall events, or 3 m less of progress in 60 s;
- **long silence:** 30 s with nothing said;
- **pause:** a tick gap over 20 s, or the app going to the background;
- **no photo matches on a stretch;**
- **compass disagreement:** over 45° on more than 20% of ticks;
- **floor timeout;**
- **a reported wrong instruction;**
- **not arrived.**

Several trips start with a comparison table. On the 2026-11-05 Icesi trips it finds what `docs/TUNING.md` §10 found by hand: spinning in b73b686d, with the compass far off on 81% of ticks, and pauses on the stuck trips. `--save` writes what `export_session.py` does, so `replay.py` checks a positioning change against the trip. Replaying the app's guidance offline isn't covered.
