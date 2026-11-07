# Model machines

Extra machines that only run the photo model, for when many people navigate at once (A3, #175). The lab refuses anything above `.large`, so more capacity means more machines.

**They're off on ordinary days, and the system works without them:** positioning falls back to the main machine's model, as it did before they existed.

```
phone → main machine: gateway → positioning ─┬→ model machines, taking turns
                                             └→ main's ai-training, when they're busy or off
admins verifying → gateway → main's ai-training
```

## Using them

```bash
./start.sh     # before an event or a test, and wait until each answers
./stop.sh      # afterwards, and wait until each has stopped
```

`../phase1-ec2/start.sh --with-model-machines` starts them along with the main machine, and `../phase1-ec2/stop.sh` always stops them too.

**Remember to stop them.** Check your lab's page for the real prices. As an estimate, a running `c5.large` is about $0.09 per hour, so two left on for a month cost about $130. A stopped one still costs about $2.60 per month for its disk.

## Setting them up

```bash
MODEL_MACHINES=2 ./provision.sh   # safe to re-run, and reuses what exists
# wait a few minutes for Docker to install
./deploy.sh                       # also after changing backend-ai-training or packages
```

`deploy.sh` prints `AI_TRAINING_URLS=...`. Put that line in `backend-positioning/.env` on the main machine, then, on the main machine:

```bash
cd ~/4u && sudo docker compose up -d --force-recreate positioning
```

Private addresses survive stopping and starting. They change only if a machine is deleted and launched again.

To remove them, terminate the machines tagged `4u-model-*`, delete the security group `4u-model-sg`, and clear `AI_TRAINING_URLS`.

## How it stays safe

- **Nothing is public.** `/search_similar` has no authentication, so port 80 only accepts the main machine's security group. Access for you goes through SSM, like the main machine.
- **Only Qdrant's key is on them,** fetched from the main machine by `deploy.sh`. There's no Supabase key: searching doesn't use it, and the admin endpoints can't work there. Verifying always goes to the main machine.
- **A machine that's off costs little.** Positioning waits up to 0.3 s to connect, then skips it for 30 s (`backend-positioning/app/model_machines.py`).

## Capacity

Measured on 2026-11-07: a `c5.large` serves **3.0 photos/s**, against about 2.3 on the main `t3.medium`. It stays at 3.0 at twice that load, answering in under 1.4 s at p95. A phone sends about 0.3 photos/s.
