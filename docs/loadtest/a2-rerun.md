# Load test after A2's server changes (#174)

Run on 2026-11-06, 19:19–23:55 UTC, against production with the changes from #204, #205 and #206 deployed. The machine is the same as in [`baseline.md`](baseline.md): t3.medium, 2 vCPU, 3.8 GB, no swap. Production's health was checked every 30 s throughout, separately from the tool.

## Result

**The server now handles the event's 10 users, with 5 admins working at the same time.** The freeze is gone, and nothing degraded over 30 minutes. About a third of the photos get no visual correction, because the model is at capacity, and those positions come from GPS. Getting them back needs a second machine for the model (A3).

| Run | Between photos, p50 / p95 | Photo answers, p95 | Matched | Refused as busy | Errors | ai-training memory, peak |
|---|---:|---:|---:|---:|---:|---:|
| 10 users, before A2 | 8.76 / 9.48 s | 8.0 s | 22% | | froze | 2632 MB |
| **10 users** | 3.29 / 3.76 s | 2.3 s | **64%** | 31% | 0 | 988 MB |
| 15 users | 2.90 / 3.90 s | 2.4 s | 35% | 62% | 0 | 1207 MB |
| 5 admins, about 3× faster than the first admin test | | | | | 0 | 1108 MB |
| **10 users + 5 admins**, 10 min | 3.44 / 3.90 s | 2.4 s | **64%** | 32% | 14 (below) | 1132 MB |
| **10 users, 30 min** | 3.37 / 3.81 s | 2.3 s | **67%** | 29% | 0 | 1100 MB |
| 20 users, 3 min, deliberate overload | 2.82 / 3.94 s | 2.5 s | 23% | 75% | 0 | 1239 MB |

The 30-minute run was steady: 65–68% matched in every 5-minute slice, and memory stayed around 1.1 GB. The photo service never restarted in any run.

## Against A2's targets

| Target, at 10 users with admins working | Result | |
|---|---:|---|
| Photo answers p95 ≤ 3 s | 2.4 s | Met |
| Other calls p95 ≤ 1 s | up to 1.7 s (the point and list reads; logs 0.64 s) | **Not met** |
| Errors under 1% | 14 of about 5,000 requests | Met, but see verifying below |
| Guidance never stops | every photo was answered | Met in the simulation |
| At least 60% of photos matched (proposed) | 64% | Met, narrowly |
| Never freezes, recovers by itself | no freeze, even at 20 users | Met, but see below |
| Room up to 15 | safe, but 35% matched | **Not met** |

**Point reads improved from 11 s to about 0.8 s p50 at 10 users.** The 1 s target may not be reachable while each read also waits for Supabase. The reads that miss it are mostly made while a trip starts, not during it.

**"Recovers by itself" has only partly been shown on the server.** 20 users never reached the 1800 MB memory limit, so a memory kill and restart was only tested locally. Above 20 users is untested on the server.

## What the model's limit means

On the server, one photo takes about 0.9 s of model time on 1 thread, so its 2 slots serve about 2.3 photos per second, however many arrive. 10 phones send about 3, and 15 send about 4.5. This is why more users means a lower share of matches, but no slower answers. Locally the same model took about 0.5 s, which is why local runs looked better: 198 of 198 answered, where the server's share was about 70%.

## Verifying stops when users are at full load

In the mixed run, **13 of 21 verifications answered "server busy" after waiting 30 s.** That's the rule working: users' photos go first, and with 10 users there's nearly always one waiting. Admins alone had no problem (28 of 28).

The admin's save has already succeeded by then, so **a verified point can end up missing from the search** until "Re-index verified points" adds it. The app shows a warning when this happens.

So during the event, or any test with about 10 people navigating, **admins shouldn't verify points.** Other edits are unaffected.

## A bug this re-run found

The first attempt stopped itself with 7% errors, and the server stayed up. #205 made map endpoints run in threads, and the Supabase library's shared HTTP/2 connection fails when threads use it at once (`httpx.ReadError`). The old one-at-a-time queue had been hiding this. It affected production for about 11 minutes during the agreed window, with no other traffic on the server.

It's fixed in #206 with an HTTP/1.1 connection pool. In a direct trial against Supabase, the old client failed 24 of 480 threaded reads and the new one failed none, in half the time.

## Still unexplained

**One read of the admin photos list timed out at 60 s in the mixed run,** as one did in the first admin test. That's about 1 in 140 reads in that run. The server logged no error and no failed request, so it may even come from the test client. It's worth watching for in real use.

## How the test went

- My computer slept from about 19:26 to 22:36 UTC, pausing a cleanup. It finished on waking, and the gateway's log shows no other address used the server in that time. Later runs blocked sleep.
- After all the runs: no sandbox or test accounts remain, real counts are unchanged, and all 868 searchable photos are in the index. The 12 old entries from `baseline.md` are still there.

## Decisions

**A2:** the server's part is done. The phone sending fewer photos when busy remains, and comes with the 0.6 app. It should lower the share refused, but needs its own 10-user run to show by how much.

**A3:** still needed for 15 people, or for better correction at 10. The model is the limit, at about 170% of the 200% CPU. **The lab refuses every machine above `.large`,** by dry run on 2026-11-06: t3, m5, c5, c6i, c7i and m6i `.xlarge`, and t3, m5 and c5 `.2xlarge`. Every allowed size has 2 vCPUs, one physical core with 2 threads, today's machine included. `c5.large` has a faster clock (3.4 GHz against 2.5), which is unmeasured for the model, and `t3.large` only adds memory. So A3 means a second machine for the model. At about 2.3 photos/s per machine, two would serve about 4.6, about what 15 phones send, though that's arithmetic, not measured. Launching one is allowed, but a dry run doesn't show how many the lab permits.

**The event:** on today's machine, 10 people will work. Expect about two in three photos to correct their position, and admins shouldn't verify during it. 15 people are safe, but mostly on GPS. **Phones and campus Wi-Fi remain untested,** which is what A4's rehearsal is for.

## Reproducing

From `loadtest/`, in an agreed window, one at a time: `uv run python run.py users-10 --window`, then `users-15`, `admins-5`, `mixed`, `long`, `overload-20`. The faster admins used `LOADTEST_ADMIN_WAIT_SCALE=0.3`. Use `systemd-inhibit` so the computer can't sleep, and check production's health on a timer.
