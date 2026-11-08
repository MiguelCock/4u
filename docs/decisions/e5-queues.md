# E5: Kafka, RabbitMQ or another queue? (#197)

**Recommendation: no message queue at this size.** If a request ever waits on work it doesn't need, use FastAPI's `BackgroundTasks` first, in the service itself. The decision is yours.

## What was the candidate

The likely use was writing trip logs in the background, so a trip's calls don't wait on them. **The app already doesn't wait:** `NavigationScreen` sends each `POST /navigation/logs` without awaiting it before the next photo (`_postLog`), and puts a failed log's cues back in the queue. The photo's own path (`/positioning/correct_position`) writes nothing to the database.

## What the numbers say

- With 10 users and 5 admins (A2), the limit was the photo model's CPU, not logs or the database. Logs answered normally throughout.
- E1 found the database's queries average under 5 ms.
- `POST /navigation/sessions` answers in 0.12 s p50 (E2), most of it the round trip to Supabase.

## What a queue would cost

Kafka or RabbitMQ is one more container to run, watch and keep within the t3.medium's 3.8 GB, next to a model that already needs up to 1.8 GB. It also needs a worker, and another way for a log to get lost. A database queue or a background task gives the same benefit here, without either.

## When to look again

- if `/navigation/logs` ever shows up slow in the gateway's timing (`loadtest/endpoint_times.py`);
- or if a job appears that takes seconds and can wait, such as re-indexing many points at once.
