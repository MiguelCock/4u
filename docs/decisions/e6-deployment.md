# E6: Deployment (#198)

## Deploy and roll back in one command each

```bash
deployment/deploy.sh map-management user-management   # the services you changed
deployment/deploy.sh gateway                          # nginx.conf or the admin web app
deployment/deploy.sh --rollback map-management        # the image before the last deploy
```

`deploy.sh` brings together the steps that each went wrong once by hand:
- it copies the code, never a `.env`, except the admin web app's public one;
- it keeps each service's running image as `:prev`;
- it rebuilds;
- it **always recreates the gateway** (on 2026-11-08, skipping that sent map requests to the wrong service for 5 minutes);
- it removes old images, so the disk doesn't fill;
- it checks every service through the public address.

It ends with one line: `OK`, or what failed with the last log lines. **Tested on 2026-11-08** on production: navigation-management was deployed and rolled back, about 20 s each, and the rollback was confirmed to run the previous image.

**What stays manual:**
- schema migrations, run in the Supabase SQL editor before the deploy that needs them;
- the model machines (`deployment/model-machines/deploy.sh`);
- AWS Academy's credentials, refreshed every 4 hours.

## Leaving AWS Academy: options

The lab stops every machine when a session ends, and refuses anything above `.large`. The figures below are approximate public list prices for an always-on month. Check them before deciding.

| Option | What runs | About per month |
|---|---|---:|
| AWS, as today: t3.medium + 2 c5.large always on | everything, with model machines | ~$155 |
| AWS: t3.medium, plus model machines only for events | everything | ~$30 + ~$0.17/h per event |
| AWS: one c5.xlarge | everything, model included | ~$125 |
| One VPS elsewhere with 4–8 vCPU and 8–16 GB (e.g. Hetzner) | everything, model included | ~$15–35 |

Supabase stays as it is in every option. Photo search's Qdrant now runs on the main machine (E2), so there's no Qdrant Cloud cost.

**Recommendation:**
- **for the project's remaining months:** stay on the lab, with model machines only for events;
- **for a production that outlives the course:** a single larger VPS, monitored with an uptime check on the health endpoints and a monthly cost cap. It would cost the least and be the simplest, since `docker-compose.yml` and `deploy.sh` move unchanged (only `DEPLOY_HOST` and `DEPLOY_URL` change).

That needs your account and budget (#93, #94).
