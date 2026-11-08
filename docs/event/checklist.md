# Event checklist

One page, for running an event or rehearsal alone. Each step says what "good" looks like. If something isn't good, the [runbook](runbook.md) has a section for it. Commands run from the repo root unless they say `cd`.

## A week before

- [ ] **Route:** `cd loadtest && uv run python check_map.py --route "<route name>"` → `READY`. Fix what it lists, then walk the route once with the app.
- [ ] **Search index:** in the admin app, run "Re-index verified points". Then `check_map.py` shows `Search entries pointing at deleted points: 0`.
- [ ] **Attendees:** send them [attendees-es.md](attendees-es.md), so they install the app **on Wi-Fi** beforehand (the APK is 66 MB).
- [ ] **Accounts:** `uv run python event_accounts.py --create <people + 3 spares>`. Print `loadtest/.data/event-accounts.csv`, one card per person. Don't share the file.

## Go / no-go

Fill in on the day. Anything not ready, or not rehearsed, waits for the next event.

| Item | State | Go? |
|---|---|---|
| Server side of A2 and A3: overload safety, model machines | Deployed, works with app 0.5.6 | |
| App 0.6, with the phone pausing photos when busy | Only if released and installed: it saves data, nothing else | |
| The event's route | `check_map.py` says `READY`, and it's been walked | |
| Campus network | The rehearsal's report shows the network's part under about 2 s p95 | |
| Admins verifying during the event | Only with the model machines running | |

## On the day: an hour before

- [ ] **Lab:** in AWS Academy, press **Start Lab**, wait for green, and copy the new credentials into `~/.aws/credentials`. The session lasts about 4 hours: **note when it ends.**
- [ ] **Machines:** `deployment/phase1-ec2/start.sh --with-model-machines`. If the main machine is already running, use `deployment/model-machines/start.sh`. Each one ends `answering`.
- [ ] **Live view:** `cd loadtest && uv run python watch.py`, kept open the whole time. Every line is green, apart from `Photos, last 2 min: none` while nobody's navigating.
- [ ] **One test trip** on your own phone, on the event's route. Guidance starts, and the live view shows photos with a high share matched.

## During

- [ ] Glance at the live view every few minutes. **Red names the runbook section to use.**
- [ ] **About 30 minutes before the lab session ends** (the live view counts down), press **Start Lab** again and copy the new credentials. This resets the timer. The server keeps running. If the timer does run out, every machine stops: see the runbook's "The lab session is about to expire".
- [ ] Admins: editing is fine. Verifying only while the model machines are running.

## After

- [ ] `deployment/model-machines/stop.sh` → `Stopped: ...`. **They cost money while running.**
- [ ] `cd loadtest && uv run python event_report.py --since <start> --until <end> > report.md`. Keep it: it's how the event went.
- [ ] Only after the report: `uv run python event_accounts.py --delete --yes` removes the accounts **and their trips**. Keep them if you want the trips for later analysis.
