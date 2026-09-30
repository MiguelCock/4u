# Phase 1 EC2 deployment

A single, cheap EC2 instance running the existing `docker-compose.yml` unmodified, reachable over the internet, for real usability testing (issue #90). Not production — see the future `deployment/phase2-production/` for that (#94).

## Prerequisites

1. **AWS CLI v2 installed and configured** with your own credentials (`aws configure` — never paste your access key/secret into a chat session; run it yourself in your own terminal).
2. Verify it works: `aws sts get-caller-identity` should print your account details.
3. An AWS account on the free tier / a promotional credit — see "Cost" below before picking an instance type.
4. **If this is an AWS Academy Learner Lab account** (`assumed-role/voclabs/...` in step 2's output is the tell): these use short-lived session credentials tied to the lab session, not a long-lived IAM user — if any script suddenly starts failing auth partway through, the lab session likely needs restarting and `aws configure` re-run with the new temporary credentials it gives you. No region is set by default either; every script here defaults `AWS_REGION` to `us-east-1` (Academy labs are commonly restricted to this region) — override via the env var if yours differs.

## Instance sizing — real evidence, not a guess

Issue #90 explicitly asked for this to be validated, not assumed.

**Local measurement** (dev machine, 16GB RAM, Docker 29.8) by building and running the full stack and watching `docker stats`:

| Container | Idle | After a real `/search_similar` call (loads the PyTorch model) |
|---|---|---|
| `ai-training` | ~421 MB | ~439 MB |
| `map-management` / `route-management` / `data-collection` / `navigation-management` / `user-management` | ~78-81 MB each | ~78-81 MB each |
| `gateway` | ~2-3 MB | ~2-3 MB |
| **Total (7 containers)** | **~826 MB** | **~776-830 MB** |

**Confirmed live on a real `t3.medium` instance** (the actual target hardware, not an estimate): `free -h` showed 1.2GB used / 3.7GB total / 2.2GB available at rest, and `docker stats` totaled ~803MB across all 7 containers — consistent with the local numbers above, with comfortable headroom to spare.

That's *application* memory only — add OS + Docker daemon overhead (150-400 MB, confirmed in the `t3.medium` numbers above) and steady-state usage alone is already at or past **1 GB**, with zero margin on a 1GB instance. The **build** step is worse: `docker compose up --build` installs `torch`/`torchvision`/`opencv-python-headless` for `backend-ai-training` and builds all 6 images, which is meaningfully more memory- *and disk*-hungry than steady-state running (see "Disk size" below — this is what actually broke the first real attempt, not memory).

**Conclusion**: the true free-tier instance types (`t2.micro`/`t3.micro`, 1 GB RAM) are very likely too small, especially to build on. `provision.sh` defaults to **`t3.medium`** (4 GB) for headroom on both build and run — confirmed working end-to-end against a real AWS Academy Learner Lab account.

### Disk size — the real blocker hit on first deployment

The AL2023 AMI's **default root volume is only 2GB**. Building all 6 images (Python base layers + `uv`-downloaded interpreters + torch/torchvision for `backend-ai-training`) filled it completely and failed mid-build with `No space left on device`, confirmed live. `provision.sh` now explicitly requests a **20GB `gp3`** root volume via `--block-device-mappings` (`ROOT_VOLUME_GB`, overridable) — comfortably within the AWS free tier's 30GB/month EBS allowance, confirmed to build and run the full stack successfully afterward.

### Two more things only found by actually running this

- **`docker compose build` needs `buildx` ≥0.17**, which AL2023's base `docker` package doesn't include (confirmed: `compose build requires buildx 0.17.0 or later`). `provision.sh`'s user-data now installs it the same way it installs the Compose plugin (`rsync` too — also missing from the base image, needed for the file-copy step below).
- The very first `/search_similar`/`/index_anchor` call after a fresh start downloads EfficientNet-B0's pretrained weights (~20.5 MB) from `download.pytorch.org` at runtime — on this connection that took **~2.5 minutes** and exceeded nginx's default 60s proxy timeout (504 the first time, 200 OK on retry). Separately, the **very first request to any service** right after `docker compose up -d` can also 502 once (nginx resolves upstream container names before all backends are fully listening) — both resolve themselves on a retry a few seconds later, confirmed live. Neither is fixed here (out of scope for Phase 1) — worth knowing when demonstrating this deployment so an initial 502/504 isn't mistaken for a real failure.

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
| `./provision.sh` | Creates the security group (SSH from your current IP only, the gateway's port `8000` from anywhere), an SSH key pair (saved to `~/.ssh/`, **not** into this repo), and launches a 20GB-disk instance with Docker + the Compose plugin + `buildx` + `rsync` pre-installed via user-data. Prints the SSH command and public IP when done. |
| `./start.sh` | Resumes a **stopped** instance. Prints the new public IP (it changes every start/stop cycle — no Elastic IP is used, to avoid its own small idle cost). **Confirmed live: the containers don't come back up on their own** (`docker-compose.yml` sets no restart policy, and a `stop`/`start` instance cycle is a real reboot) — but the built images survive on disk, so after `start.sh` all that's needed is `ssh ... "cd ~/4u && sudo docker compose up -d"` (no `--build`, confirmed fast — seconds, not a rebuild). |
| `./stop.sh` | Stops a **running** instance to pause compute billing between test sessions. Everything on disk survives. |
| `./delete.sh` | Permanently terminates the instance and deletes the security group. Asks for confirmation first. Standing back up after this means `provision.sh` **and** redoing the manual setup below from scratch. |

None of these ever put real secrets in AWS-visible places (EC2 user-data is stored in plain text in your account's history and readable via the instance metadata service) — see "First-time setup" below for how `.env` files actually get there.

## First-time setup (manual, after `provision.sh`)

Not scripted on purpose — this only needs doing once per instance (surviving `stop`/`start`, redone after `delete` + a fresh `provision.sh`):

1. Wait a minute or two after `provision.sh` finishes for the user-data script to install Docker + buildx + rsync (confirm with `ssh -i ~/.ssh/4u-phase1-key.pem ec2-user@<public-ip> "docker --version && docker buildx version && rsync --version"`).
2. Copy just what the stack actually needs to the instance — `docker-compose.yml`, `gateway/`, `packages/`, and the 6 `backend-*/` directories (each with its real, already-populated `.env`). The Flutter `application/` directory doesn't run on the server at all, so it's deliberately left out — no point shipping it or its build artifacts over:
   ```
   ssh -i ~/.ssh/4u-phase1-key.pem ec2-user@<public-ip> "mkdir -p ~/4u"
   rsync -avz -e "ssh -i ~/.ssh/4u-phase1-key.pem" \
     --exclude '.venv' \
     docker-compose.yml gateway packages backend-ai-training backend-data-collection backend-map-management backend-navigation-management backend-route-management backend-user-management \
     ec2-user@<public-ip>:~/4u/
   ```
   Run from the repo root. **No trailing slashes on the directory names** — confirmed live that `gateway/` (trailing slash) copies the *contents* of each directory into a shared destination, flattening and overwriting everything into one directory instead of preserving `gateway`, `packages`, etc. as their own subdirectories. `--exclude '.venv'` matches at any depth, so each service's own `.venv` is skipped either way.
3. SSH in and start the stack:
   ```
   ssh -i ~/.ssh/4u-phase1-key.pem ec2-user@<public-ip>
   cd ~/4u
   sudo docker compose up --build -d
   ```
   (`sudo` — the `ec2-user` account was added to the `docker` group by user-data, but that only takes effect in a *new* login session, not the one you're already SSHed into right after provisioning)
4. Verify it's reachable **from your own machine**, not just from inside the instance — and if the very first attempt at any endpoint 502s, just retry once (see "Two more things only found by actually running this" above):
   ```
   curl http://<public-ip>:8000/map/
   curl http://<public-ip>:8000/route/
   curl http://<public-ip>:8000/user/
   curl http://<public-ip>:8000/navigation/
   curl http://<public-ip>:8000/data-collection/
   curl http://<public-ip>:8000/ai-training/
   ```
   (each service's `GET /` health check, proxied through the gateway — see `gateway/nginx.conf` for the full path-prefix list). Confirmed live: all 6 backend services plus the gateway's own `/` respond with `200 OK` once the stack settles.

## Out of scope here (separate issues)

- Pointing the Flutter app's `API_GATEWAY_URL` at this deployment and running the real end-to-end flow through it — #91.
- HTTPS in front of the gateway — #92.
- A budget alarm / automated stop-start schedule — #93 (this folder's `stop.sh` is the manual version of half of that).
