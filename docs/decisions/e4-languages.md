# E4: Another language or runtime? (#196)

**Recommendation: stay on Python and FastAPI.** Revisit only if a measured hot path appears that isn't the model or a round trip. The decision is yours.

## Where the time goes today

All figures are from E2 (`docs/loadtest/e2-results.md`), on production, one person at a time.

| What | p50 | Mostly |
|---|---:|---|
| A photo correction, server's part | 0.50 s | the photo model, about 0.5 s of CPU in PyTorch, which is C++ already |
| List endpoints (`/map/places`, `/map/anchor-points`…) | 0.12–0.22 s | the round trip to Supabase; E1 found the queries themselves average under 5 ms |
| `find_or_create` (route-finding) | 0.51 s | Supabase round trips for the graph; Dijkstra on ~300 points takes milliseconds |
| `/map/changes` | 0.35 s | six Supabase queries, now in parallel |

None of these is Python's own time. A rewrite in Rust, Go or JavaScript would make the same model call and the same Supabase round trips, so it would gain little, while every service and its tests would have to be redone and proven again with E3.

## What would help instead, if it's needed

- **The model:** ONNX Runtime or a smaller input, checked with `scripts/benchmark_models.py` so matches don't get worse (#122).
- **Round trips:** caching lists that rarely change, or fewer queries per request, as E2 did for trips and `/changes`.
- **Capacity:** more model machines (A3), already in place.

## Why no benchmark was run

The story planned prototypes in four languages. The numbers above already show where the time goes, so the prototypes would measure the same model and the same database from another language. This was skipped to keep the testing budget for the field tests.
