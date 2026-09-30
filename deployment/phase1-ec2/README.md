# Phase 1 EC2 deployment

A single, cheap EC2 instance running the existing `docker-compose.yml` unmodified, reachable over the internet, for real usability testing (issue #90). Not production — see the future `deployment/phase2-production/` for that (#94).

## Prerequisites

1. **AWS CLI v2 installed and configured** with your own credentials (`aws configure` — never paste your access key/secret into a chat session; run it yourself in your own terminal).
2. Verify it works: `aws sts get-caller-identity` should print your account details.
3. An AWS account on the free tier / a promotional credit — see "Cost" below before picking an instance type.

## Instance sizing — real evidence, not a guess

Issue #90 explicitly asked for this to be validated, not assumed. Measured locally (this dev machine, 16GB RAM, Docker 29.8) by building and running the full stack and watching `docker stats`:

| Container | Idle | After a real `/search_similar` call (loads the PyTorch model) |
|---|---|---|
| `ai-training` | ~421 MB | ~439 MB |
| `map-management` / `route-management` / `data-collection` / `navigation-management` / `user-management` | ~78-81 MB each | ~78-81 MB each |
| `gateway` | ~2-3 MB | ~2-3 MB |
| **Total (7 containers)** | **~826 MB** | **~776-830 MB** |

That's *application* memory only — add OS + Docker daemon overhead (typically 150-400 MB on a minimal Linux instance) and steady-state usage alone is already at or past **1 GB**, with zero margin. The **build** step is worse: `docker compose up --build` installs `torch`/`torchvision`/`opencv-python-headless` for `backend-ai-training` and builds all 6 images, which is meaningfully more memory-hungry than steady-state running.

**Conclusion**: the true free-tier instance types (`t2.micro`/`t3.micro`, 1 GB RAM) are very likely too small, especially to build on. `provision.sh` defaults to **`t3.medium`** (4 GB) for headroom on both build and run.

**Also found**: the very first `/search_similar` or `/index_anchor` call after a fresh start downloads EfficientNet-B0's pretrained weights (~20.5 MB) from `download.pytorch.org` at runtime — on this connection that took **~2.5 minutes** and exceeded nginx's default 60s proxy timeout (504). This isn't instance-size-related, it's a real first-request latency issue worth knowing about: the very first real request through the gateway after (re)starting the stack may need a retry, or `gateway/nginx.conf`'s `proxy_read_timeout` may need raising. Not fixed here — flagging it since it directly affects how "Phase 1 works" gets demonstrated.

### Cost (approximate — verify current pricing, not independently confirmed against a live AWS pricing query)

Roughly, on-demand Linux, a commonly-cited region: `t3.micro` ≈ $0.0104/hr, `t3.small` ≈ $0.0208/hr, `t3.medium` ≈ $0.0416/hr. At `t3.medium`'s rate, even 100 hours of testing (well beyond a realistic Phase 1 testing window, especially combined with `stop.sh` between sessions) is about $4 — comfortably inside a $50 credit. If you want to stretch the credit further once the images are already built, you can downsize:

```
./stop.sh
aws ec2 modify-instance-attribute --instance-id <id> --instance-type t3.small
./start.sh
```
(Only works while stopped; `t3.small` is 2 GB, enough headroom to *run* the already-built stack per the table above, just not to rebuild it — resize back to `t3.medium` temporarily if you need to `docker compose up --build` again, e.g. after pulling new code.)

## Scripts

All four read config from environment variables (sensible defaults baked in — see the top of each script) so nothing needs editing to run them as-is.

| Script | What it does |
|---|---|
| `./provision.sh` | Creates the security group (SSH from your current IP only, the gateway's port `8000` from anywhere), an SSH key pair (saved to `~/.ssh/`, **not** into this repo), and launches the instance with Docker + the Compose plugin pre-installed via user-data. Prints the SSH command and public IP when done. |
| `./start.sh` | Resumes a **stopped** instance. Prints the new public IP (it changes every start/stop cycle — no Elastic IP is used, to avoid its own small idle cost). |
| `./stop.sh` | Stops a **running** instance to pause compute billing between test sessions. Everything on disk survives. |
| `./delete.sh` | Permanently terminates the instance and deletes the security group. Asks for confirmation first. Standing back up after this means `provision.sh` **and** redoing the manual setup below from scratch. |

None of these ever put real secrets in AWS-visible places (EC2 user-data is stored in plain text in your account's history and readable via the instance metadata service) — see "First-time setup" below for how `.env` files actually get there.

## First-time setup (manual, after `provision.sh`)

Not scripted on purpose — this only needs doing once per instance (surviving `stop`/`start`, redone after `delete` + a fresh `provision.sh`):

1. Wait a minute or two after `provision.sh` finishes for the user-data script to install Docker.
2. Copy just what the stack actually needs to the instance — `docker-compose.yml`, `gateway/`, `packages/`, and the 6 `backend-*/` directories (each with its real, already-populated `.env`). The Flutter `application/` directory doesn't run on the server at all, so it's deliberately left out — no point shipping it or its build artifacts over:
   ```
   rsync -avz -e "ssh -i ~/.ssh/4u-phase1-key.pem" \
     --exclude '.venv' \
     docker-compose.yml gateway/ packages/ backend-*/ \
     ec2-user@<public-ip>:~/4u/
   ```
   (run from the repo root; `--exclude '.venv'` matches at any depth, so each service's own `.venv` is skipped)
3. SSH in and start the stack:
   ```
   ssh -i ~/.ssh/4u-phase1-key.pem ec2-user@<public-ip>
   cd ~/4u
   docker compose up --build -d
   ```
4. Verify it's reachable **from your own machine**, not just from inside the instance:
   ```
   curl http://<public-ip>:8000/map/
   curl http://<public-ip>:8000/route/
   ```
   (each service's `GET /` health check, proxied through the gateway — see `gateway/nginx.conf` for the full path-prefix list)

## Out of scope here (separate issues)

- Pointing the Flutter app's `API_GATEWAY_URL` at this deployment and running the real end-to-end flow through it — #91.
- HTTPS in front of the gateway — #92.
- A budget alarm / automated stop-start schedule — #93 (this folder's `stop.sh` is the manual version of half of that).
