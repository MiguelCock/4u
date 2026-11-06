# Load test baseline (A1, #173)

Run on 2026-11-06 against the production server (t3.medium: 2 vCPU, 3.8 GB, no swap, CPU credits `unlimited`) with the `loadtest/` tool. Simulated users replay real EAFIT trips over the public address. The tool can't test phones, campus Wi-Fi or real walking.

## Result

**The server doesn't handle the event's 10 users today.** Guidance had already lost most of its visual correction within seconds, and after about 3.5 minutes the whole server froze until it was rebooted. 5 users work. The cause is the photo model's service (`backend-ai-training`), and nothing else came close to a limit.

| Users | Between photos, p50 / p95 | Server time, p50 / p95 | Photos matched | ai-training CPU, average (of 200%) | ai-training memory, peak |
|---:|---:|---:|---:|---:|---:|
| 1 | 2.83 / 4.12 s | 0.86 / 1.12 s | 91% | 15% | 707 MB |
| 5 | 3.35 / 4.51 s | 1.27 / 1.99 s | 91% | 99% | 1022 MB |
| 10 | 8.76 / 9.48 s | 6.71 / 6.90 s | **22%** | 144% | **2632 MB, then frozen** |

The 1-user run matches real trips (server time 0.87 / 1.15 s, about 3 s between photos), so the tool can be trusted.

Against A2's targets, 5 users pass (photo answers p95 3.0 s) and 10 users fail (8.0 s, and the freeze).

## What happened at 10 users

1. **The model couldn't keep up.** 10 phones send about 3.3 photos/s. At about 0.5 s of CPU each, that's about 1.6 of the 2 CPUs, plus everything else.
2. **Visual correction collapsed.** Positioning gives ai-training 2 s per attempt and retries (`backend-positioning/app/main.py:76`). Once answers took longer than that, photos used all their attempts, about 6.7 s, and came back with no match: 22% instead of 91%. Users were effectively on GPS alone. Each retry is another photo for the model to process. It probably also keeps working on the attempts positioning gave up on, since its endpoints run in threads that aren't cancelled. That wasn't measured.
3. **Memory ran out.** ai-training went from about 1 GB to 2.6 GB in about a minute, and the containers reached 3.2 GB of the machine's 3.8 GB. Why it grows wasn't measured; many photos being processed at once is the likely reason. It has no memory limit, and the machine has no swap.
4. **The machine froze** at about 12:20 UTC. Disk reads went from about 12 per 5 minutes to about 490,000, the pattern of a machine with no memory left. No process was killed, no container restarted, and the management agent stopped answering. **It didn't recover in the 52 minutes before the reboot**, even after the load stopped.

A freeze stops every service, not just photos: sign-in to the backends, routes, admin editing, everything.

CPU credits weren't the cause: the balance stayed around 560–576, and the instance is in `unlimited` mode.

## The outage this test caused

Production was down from about 12:20 to 13:17 UTC (57 minutes), inside the agreed window. No real navigation was logged that morning, but admin requests aren't checked here, so an admin could have been affected.

It lasted that long because of the tool and because of how it was watched:

- **Requests had no timeout,** so simulated users waited on the frozen server forever.
- **The automatic stop only looked at finished requests,** so a silent server looked fine. The run hung instead of stopping.
- **Nobody checked until the owner asked.** The run was expected to take about 25 minutes, and it was left waiting for a finish signal that never came.

Fixed in the same change: a 60 s timeout on every request; the run stops after 45 s with no answers, or when containers reach 2800 MB; a stuck step is killed; a stopped step skips the heavier ones after it. The memory stop reduces the risk but doesn't remove it: memory once jumped 1000 MB between two samples. Whoever runs a test should also check the server's health on a timer, and be ready to reboot.

The remote sampling loop also survived the end of each run: five were running by the time of the freeze, each adding a `docker stats` every 10 s. That's a small load, not the cause, and it's fixed too. So 5 and 10 users were measured with slightly more sampling than necessary.

All test data was removed and checked afterwards: no sandbox, no test accounts, real counts unchanged, all 868 searchable photos still in the search index.

## Not measured

**15 and 20 users, admins alone, 10 users + 5 admins, and the 30-minute run didn't run.** Users above 10 and the mixed and long runs can't pass until the freeze is fixed, so they're worth running only after that. The admin question stays open, including whether verifying points slows users' photo search. Admin runs against today's server could freeze it too, because verifying a point runs the same model.

## Other findings

- **Map reads are slow even with few users.** `GET /map/anchor-points/[id]` took 3.8 s p50 with 1 user, 6.6 s with 5, 11 s with 10; `/connections` was similar. Opening a route makes about 40 of these calls in parallel, so this is what a user waits for when a trip starts. map-management's endpoints are `async def` calling the blocking Supabase client, which would make them queue one at a time. That's a hypothesis, not yet tested.
- **12 old search entries point at deleted points** (one Icesi building, 4 points). A photo search could return a point that no longer exists. They aren't from this test. The admin "Re-index verified points" removes them.

## Decisions

**A2, in this order. The first three are what the event needs:**

1. **Stop one service from freezing the machine:** a memory limit on `ai-training`, so that it restarts on its own instead. Consider swap as well.
2. **Limit how many photos the model handles at once,** and answer quickly when it's busy rather than queueing.
3. **Stop retries from adding load:** review positioning's 2 s and its retries, since a timeout currently means the same photo is processed again.
4. Test the map read hypothesis and fix it if it holds.
5. Run 10 users again, then 15, then the admin, mixed and long runs. Have someone watching the server.

**A3: plan on a bigger machine.** Fixes can stop the freeze, but they can't create CPU. 10 users need about 1.6 of the 2 CPUs for the model alone, and A2's 15 users need about 2.5. A 4 vCPU machine with more memory is the likely minimum. Whether the AWS Academy account allows one still needs checking. The re-run after the fixes should confirm the size.

## Reproducing

From `loadtest/`, in an agreed window (see its README): `uv run python run.py users --window`. Raw results stay in `loadtest/.data/results/`, which isn't committed.
