# API and app speed, before and after E2 (#194)

Measured on 2026-11-08, 05:45 and 05:59 UTC, against production (t3.medium), with the model machines off, as on an ordinary day. `loadtest/measure.py` did each of the app's main actions 30 times, one person at a time, through the public address, the way the app does them. "Before" is the server as it was. "After" adds the three fixes in #221.

## Result

**Every main action now answers within 1.2 s for 95% of tries, and the slowest three got about 30–55% faster.** Photo correction's server time fell from 0.78 to 0.50 s, and the rest of that is almost all the model.

| Action | Before, p50 | Before, p95 | **After, p50** | **After, p95** | Proposed p95 target |
|---|---:|---:|---:|---:|---:|
| App start (sign in, profile, version) | 1.06 s | 1.47 s | 1.03 s | 1.20 s | 1.5 s |
| Home ready (four lists) | 0.51 s | 0.65 s | 0.50 s | 0.74 s | 1.0 s |
| Find a route | 0.58 s | 0.87 s | 0.59 s | 0.75 s | 1.0 s |
| **Start a trip** (22-point route) | 1.04 s | 1.85 s | **0.47 s** | **0.70 s** | 1.0 s |
| **A photo correction** | 1.16 s | 1.60 s | **0.82 s** | **1.10 s** | see below |
| ↳ of which the server | 0.78 s | 1.38 s | **0.50 s** | **0.85 s** | |
| Admin opens (five lists) | 0.75 s | 1.03 s | 0.66 s | 0.90 s | 1.5 s |
| **Admin refresh** (`/changes`) | 0.90 s | 1.16 s | **0.42 s** | **0.66 s** | 1.0 s |

The times include the network from the measuring computer in Colombia to the server in Virginia, as a phone's would, but not a phone's own time to take the photo (418 ms p50 in the trip logs).

The gateway's own timing (`loadtest/endpoint_times.py`, which reads the `rt=` it now logs) agrees: `/map/changes` 0.83 → 0.35 s p50, `/positioning/correct_position` 1.09 → 0.75 s, `/user/profiles/[id]` 0.47 → 0.33 s.

## The three fixes

1. **Photo search's Qdrant on the main machine.** Qdrant Cloud was in São Paulo, while the server is in Virginia. The same 10 searches took 119 ms there and 4 ms locally, and returned the same top 5 every time. Each photo saves about 0.3 s. The data was copied with `scripts/qdrant_copy.py` (236 + 880 points, counts and a sample of 25 checked), so nothing was re-computed.
2. **Starting a trip in one request** instead of 44 (`GET /map/anchor-points/by-ids`). The app part ships with 0.6. Until then, phones keep making the 44 requests, which still work.
3. **`/changes` runs its queries in parallel,** and three more services' endpoints stopped blocking each other (plain `def`).

App start barely changed: most of it is Supabase's sign-in, outside this server.

## Photo correction's target (#122)

The original target was 500 ms. The server's part is now 0.50 s p50 and 0.85 s p95 with only the main machine, and 0.42 / 0.73 s with the model machines on (a 5-photo check). What's left is the model itself, about 0.5 s on this CPU. Proposed: **server p95 ≤ 0.9 s on the main machine alone and ≤ 0.75 s with the model machines, and the phone's whole round trip p95 ≤ 2.5 s.** Making the model faster (ONNX, or a smaller input checked with `scripts/benchmark_models.py`) is a follow-up story, not part of E2.

## Found while deploying

- **Recreating services without recreating the gateway sent map requests to the wrong service** for about 5 minutes (05:53–05:58 UTC, about 1 am in Colombia). nginx looks up each service's address once, at start, and the four recreated containers' addresses changed places. Recreating the gateway fixed it. The deploy notes already say to do that after every service deploy.
- **The old trip start runs out the gateway's per-user allowance when repeated quickly** (44 requests, against 30/s with bursts of 60). One trip start doesn't, so users never saw it. `measure.py` waits 2 s between them.
- **The server's `~/4u/.env` had a stray line** holding only the instance id, with no newline after it. It's now `QDRANT_BIND`; the old file is kept as `.env.bak-e2`.

## Rolling back Qdrant

ai-training's previous `.env` is kept on the server as `backend-ai-training/.env.bak-cloud-qdrant`. To go back to the cloud: copy it over `.env`, then run `sudo docker compose up -d --force-recreate ai-training`. Point the model machines back with `deploy.sh`. The cloud cluster is untouched, but anything indexed after 2026-11-08 05:55 UTC is only in the local Qdrant.
