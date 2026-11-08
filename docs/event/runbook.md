# Event runbook

For whoever runs an event or rehearsal, alone. The [checklist](checklist.md) is the order of things; this page explains them, and says what to do when something goes wrong. The live view (`cd loadtest && uv run python watch.py`) names the section below whenever a line turns red.

## What's running

| Part | Where | Notes |
|---|---|---|
| The app's server: gateway and 7 services | The main machine, `4u-phase1-ec2`, a t3.medium | Its address never changes |
| Photo model machines | `4u-model-1` and `4u-model-2`, `c5.large` | Off on ordinary days. **They cost money while running** |
| Accounts, trips, map | Supabase | |
| Photo search | Qdrant Cloud | |

With the model machines, the server handles about 15 people at about 92% of photos matched. Without them, 10 people at about 64–80%, and then admins shouldn't verify (`docs/loadtest/a3-results.md`).

**Everything carries on if a part of the photo search fails:** guidance works from GPS alone, only less precisely. So never stop a trip because photos are slow.

## Before you start: one-time setup on your computer

`deployment/phase1-ec2/README.md`, "Prerequisites": the AWS CLI, the `session-manager-plugin`, and the SSH block that reaches machines by their id. Then check:

```bash
aws sts get-caller-identity          # shows .../voclabs/...
ssh ec2-user@i-08ee7be989aa9721f uptime
cd loadtest && uv sync && uv run python watch.py --once
```

## The lab session is about to expire

AWS Academy sessions last about 4 hours. The live view counts down from when you last saved credentials.

1. Press **Start Lab** in AWS Academy again. This resets the timer.
2. Copy the new credentials into `~/.aws/credentials`.
3. `aws sts get-caller-identity` works again.

The server keeps running while you do this.

**If the timer runs out, the lab stops every machine,** and the app goes offline. This was seen on 2026-11-07. **Pressing Start Lab starts them all again, the model machines included**, and the services come back by themselves within a few minutes.
- **On an ordinary day:** stop the model machines straight after (`deployment/model-machines/stop.sh`), since they cost money while running.
- **During an event:** keep them, and check the live view is all green.

## The server stops answering

The live view shows `Not answering`, or the app shows connection errors for everyone.

1. **Wait about 1 minute.** A single red line, from a restart or a network blip, usually clears by itself.
2. Check the machine: `aws ec2 describe-instance-status --instance-ids i-08ee7be989aa9721f --include-all-instances --region us-east-1`.
   - **`stopped`:** run `deployment/phase1-ec2/start.sh --with-model-machines`.
   - **`running`:** go to step 3.
3. **Reboot:** `aws ec2 reboot-instances --instance-ids i-08ee7be989aa9721f --region us-east-1`. It comes back in about 5 minutes with the same address, and every service restarts by itself. Phones show errors meanwhile, then carry on.
4. **Still not answering?** Run `ssh ec2-user@i-08ee7be989aa9721f "cd ~/4u && sudo docker compose up -d"`.

This is the fix that worked when the server froze in a load test (`docs/loadtest/baseline.md`). Since A2, overload shouldn't freeze it at all.

## A model machine is down

The live view shows `Model machine N: no answer`, or `none running`.

- **Nobody notices at first:** photos go to the other machine, or to the main one. Correction gets a little worse, and admins should stop verifying.
- **Fix:** `deployment/model-machines/start.sh`. It waits until each machine answers.
- **If that doesn't help:** carry on without them. That's how it worked before A3, for up to about 10 people.

## Photos are slow

The live view's `Photos` line turns red. It shows two numbers, and they point to different causes.

- **`server` high (over about 2.5 s), or `busy` high:** the model is short of capacity.
  - Check that both model machines are running (see the section above).
  - With them running, ask admins to stop verifying for now.
- **`network` high (over about 3 s), with `server` normal:** the phones' connection is the problem.
  - Ask people on the campus Wi-Fi to switch to mobile data, or to move near an access point.
  - Guidance carries on regardless.

## Someone can't sign in

1. Check the email and password on their card against `loadtest/.data/event-accounts.csv`. Letters are lowercase, and words are separated by `-`.
2. Give them a spare account from the same list.
3. **"Update required":** their app is older than 0.5.5. They need to install it again from the link in [attendees-es.md](attendees-es.md).

## A phone won't install the app, or it's an iPhone

- **Android that won't install:** they need to allow installing from their browser, and the guide shows how. If it still won't install, pair them with someone else.
- **iPhone:** there's no iOS app (#160). Pair them with someone with an Android phone.

## Guidance seems wrong for someone

In the admin web app, open **Live sessions** from the menu and pick their trip, to watch its trail on the map.

- **A jump or a wrong turn:** it usually corrects itself within a few photos. Let them carry on.
- **Lost for good:** they stop the trip and start it again from where they are.

Note the time and their phone's number. It's in the report later.

## After the event

- **Stop the model machines:** `deployment/model-machines/stop.sh`. Check that it says `Stopped`.
- **Report:** `event_report.py`. It shows how the event went, phone by phone, and how much of each photo's time was the network.
- **Accounts:** delete them only after the report, because their trips go with them.

The main machine stays on, as on any other day.
