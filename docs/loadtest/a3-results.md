# Load test with the model machines (A3, #175)

Run on 2026-11-07 against production, with two `c5.large` model machines (`deployment/model-machines/`) and positioning using them (`AI_TRAINING_URLS`). The main machine is unchanged: t3.medium. Compare with [`a2-rerun.md`](a2-rerun.md), the same server without them.

## Result

**15 people get about 92% of photos matched, the same as one person alone on today's server.** Verifying works while people navigate. Losing a machine mid-trip causes no errors, and with both off everything behaves as before A3.

| Run | Matched | Refused as busy | Corrections per second | Photo answers, p95 | Server time, p95 | Errors |
|---|---:|---:|---:|---:|---:|---:|
| 10 users, before A3 (`a2-rerun.md`) | 64% | 31% | 1.90 | 2.3 s | 1.94 s | 0 |
| 10 users | **92%** | 0% | 3.14 | 1.9 s | 1.21 s | 0 |
| 15 users, 5 min | **92%** | 0% | 4.13 | 3.6 s (see below) | 1.35 s | 0 |
| 10 users + 5 admins, 10 min | **92%** | 0% | 3.0 | 3.1 s | 1.25 s | 1, client side |
| **15 users, 30 min** | **93%** | 0.1% | 4.48 | **2.7 s** | 1.33 s | 1 of 8,700, client side |
| 10 users, one machine stopped at 2 min | 91% | 0% | 2.99 | 2.5 s | 1.34 s | 0 |
| 10 users, both machines off | 80% | 11% | 1.85 | 3.6 s | 1.81 s | 0 |

The 30-minute run was steady: 92–93% matched in every 5-minute slice, with server time flat at about 0.85 s p50. Main's model sat at 1–9% CPU on average, since it only takes the overflow. Each model machine averaged about 140% of its 200%.

**The phone's photo pause was simulated in every run** (see `a2-rerun.md`), so the fallback row compares with its 80%, not with 64%.

## Against the targets

| Target, at 15 users with admins working | Result | |
|---|---:|---|
| At least 80% of photos matched | 92–93% | Met |
| Photo answers p95 ≤ 3 s | 2.7 s over 30 min; 3.6 s in one 5-minute run | Met on the server side; see below |
| At least 90% of verifications succeed during trips | **30 of 30** at 10 users + 5 admins, against 8 of 21 before | Met at 10 users; 15 users + admins not run |
| One model machine failing causes no errors | 0 errors, 91% matched | Met |
| Other calls p95 ≤ 1 s | up to 2.5 s for the lists that load when a trip starts; 0.68 s for logs | **Not met**, partly the test's own connection |

## Where the photo answers' extra seconds come from

The server's own time stayed at about 1.3 s p95 in every run, but the time seen by the test was up to 3.6 s. To find the difference, the same 152 KB upload was sent every 2 s for 15 minutes during the 30-minute run, from two places at once, both through the public address:

| Probe | p50 | p95 | Worst | Over 1 s |
|---|---:|---:|---:|---:|
| From the computer running the test | 0.74 s | 2.12 s | 8.2 s | 83 of 450 |
| From the main machine | 0.02 s | 0.05 s | 0.27 s | 0 |

**The server path never stalled. The delay is between the test computer and AWS,** on a home Wi-Fi connection whose upload measured 14–20 Mbit/s, of which the test used about 6. The single read timeouts in some runs, here and in `a2-rerun.md`, fit the same cause.

**This matters for the event.** If one shared connection stalls like this with 15 simulated phones, a congested campus Wi-Fi could do the same to real ones. A4's rehearsal should measure it on site. It's also why "other calls ≤ 1 s" can't be judged from these runs.

## Outside services
- **Qdrant:** about 4.5 searches per second for 30 minutes, at 0.13–0.23 s p50, no slower than at lower loads. Your dashboard has room.
- **Supabase:** 30 minutes of 15 users wrote about 8,700 log rows, at about 2.4 KB each. So an hour of 15 people is about 18,000 rows and 40 MB. Your dashboard has room.

## Cost
The two machines ran for about 2 hours in total, plus 15 minutes for the first measurement. That's about $0.40 at the estimated $0.09 per hour. While stopped, they cost about $2.60 per month each for their disks. **Both are stopped,** and they stay off on ordinary days.

## How the test went
- **A mistake in the deploy:** adding `AI_TRAINING_URLS` to positioning's `.env` glued it onto the previous line, because the file had no final newline. That broke positioning's Supabase key for about 3 minutes, inside the window, with no other traffic on the server. It was found by checking the container's settings before testing, then repaired and verified: the key's fingerprint matches the other services, and a bad token gets 401 again. `deployment/model-machines/README.md` now says how to add the line safely.
- **The test computer slept** from about 03:50 to 17:39 UTC, despite blocking sleep, probably because the lid was closed. The fallback run started on waking, at 17:50, outside the agreed window. The gateway's log shows no other address in that time, and cleanup completed.
- After every run: no test data left, real counts unchanged. After the last one, both model machines were stopped.

## Decisions
- **A3 is done for the event's 10–15 people.** For the event, start the model machines with `deployment/phase1-ec2/start.sh --with-model-machines` or `deployment/model-machines/start.sh`, and stop them after.
- **Admins can verify during the event** with the machines running.
- **"Other calls ≤ 1 s" and campus Wi-Fi go to A4's rehearsal,** measured from phones on site rather than from one shared connection.
- **Not tested:** 15 users with admins at the same time, and more than 15 people.
